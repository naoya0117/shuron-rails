# frozen_string_literal: true

require "rails/container/config_loader"
require "rails/container/events"
require "rails/container/graceful_shutdown"
require "rails/container/privilege"

module Rails
  # = \Rails \Container layer
  #
  # Aggregates the application-side support needed to move from local/Docker
  # development to a Kubernetes cluster behind one API: platform detection,
  # Managed Lifecycle (Rails::Container::GracefulShutdown), Init Container
  # (init steps), Self Awareness (pod metadata), and diagnostics that surface
  # anything not yet configured for the platform.
  #
  # The layer is generalized as the "container" layer; the parts that are
  # specific to generating Kubernetes manifests live under Rails::Kubernetes.
  module Container
    # Platforms the layer adapts to.
    PLATFORMS = %i[kubernetes compose local].freeze

    # A diagnostic check. +block+ returns a problem message (String) when the
    # feature is missing/unconfigured, or +nil+ when satisfied.
    Check = Struct.new(:name, :severity, :block)

    # An initialization step (Init Container). +block+ runs once before the app
    # serves traffic, via the +container:init+ task.
    InitStep = Struct.new(:name, :block)

    # Self Awareness: the pod's own metadata, injected by the Downward API as
    # environment variables; all fields +nil+ off Kubernetes (local/Docker).
    SelfInfo = Struct.new(:pod_name, :namespace, :node_name, :pod_ip, :service_account, keyword_init: true)

    class << self
      # Detects the runtime platform: an explicit +CONTAINER_PLATFORM+ wins;
      # otherwise the presence of +KUBERNETES_SERVICE_HOST+ means +:kubernetes+;
      # otherwise +:local+.
      def platform
        override = ENV["CONTAINER_PLATFORM"].to_s
        return override.to_sym if PLATFORMS.include?(override.to_sym)

        ENV["KUBERNETES_SERVICE_HOST"].to_s.empty? ? :local : :kubernetes
      end

      # The loaded container-layer settings (a Symbol-keyed Hash).
      def config
        ConfigLoader.load!
        Rails.application.config.x.container || {}
      end

      # --- Diagnostic check registry -------------------------------------

      def register_check(name, severity: :warn, &block)
        raise ArgumentError, "register_check requires a block" unless block

        checks << Check.new(name, severity, block)
        name
      end

      def checks
        @checks ||= []
      end

      def reset_checks
        @checks = []
      end

      # Runs every check and returns the problems, minus any named in
      # <tt>config[:diagnostics][:ignore]</tt>; [] when diagnostics are disabled.
      def diagnostics
        settings = config[:diagnostics] || {}
        return [] if settings[:enabled] == false

        ignored = Array(settings[:ignore]).map(&:to_sym)
        run_checks.reject { |d| ignored.include?(d[:name]) }
      end

      # Logs each pending diagnostic to +logger+ at its severity.
      def emit_diagnostics(logger = Rails.logger)
        return unless logger

        diagnostics.each do |d|
          line = "[container] #{d[:name]}: #{d[:message]}"
          d[:severity] == :info ? logger.info(line) : logger.warn(line)
        end
      end

      # --- Init Container -------------------------------------------------

      def init_step(name, &block)
        raise ArgumentError, "init_step requires a block" unless block

        init_steps << InitStep.new(name, block)
        name
      end

      def init_steps
        @init_steps ||= []
      end

      def reset_init
        @init_steps = []
        @init_ran = false
      end

      # Runs each init step once, in order. Fails fast: a raising step aborts
      # initialization.
      #
      # The +@init_ran+ guard is a process-local re-entrancy guard and nothing
      # more -- it is deliberately *not* a record of "initialization has been
      # done". Nothing is persisted, so a fresh process knows nothing, and N
      # replicas run this N times. Nor does a retry skip the steps that already
      # succeeded: the flag is set only after the whole loop completes, so a
      # failure leaves no record and the next attempt starts from the first step.
      #
      # That is the right shape for the pattern rather than a limitation of it.
      # An Init Container is expected to be re-run -- the kubelet restarts it on
      # failure -- so a layer that remembered "already done" and skipped work
      # would be the dangerous design. The layer guarantees the re-run; whether
      # a step is safe to re-run is the step's own business, which is what
      # "init steps must be idempotent" means.
      #
      # Each step and the completion are recorded as events, so that "the steps
      # ran before traffic" is observable from outside the process rather than
      # inferred from the fact that they were declared.
      def run_init!
        return if @init_ran

        init_steps.each do |step|
          Events.timed("init.step", name: step.name) { step.block.call }
        end
        @init_ran = true
        Events.emit("init.done", steps: init_steps.size)
      end

      # --- Self Awareness -------------------------------------------------

      # Off Kubernetes (local/Docker) every field is nil -- the Downward API
      # only injects these on a cluster -- so the platform difference is
      # absorbed and unrelated local env is not surfaced.
      def self_info
        return SelfInfo.new unless platform == :kubernetes

        SelfInfo.new(
          pod_name: ENV["POD_NAME"],
          namespace: ENV["POD_NAMESPACE"],
          node_name: ENV["NODE_NAME"],
          pod_ip: ENV["POD_IP"],
          service_account: ENV["POD_SERVICE_ACCOUNT"]
        )
      end

      # --- Boot summary ---------------------------------------------------

      # One line, at boot, recording what the layer resolved for this process.
      #
      # Without it, every one of these facts needs `rails container:conformance`
      # run inside the container to observe -- which means the behaviour of a
      # deployed Pod can only be checked by exec'ing into it. With it,
      # `kubectl logs` and `docker compose logs` are enough, which is what makes
      # a manifest or a compose file verifiable from outside.
      #
      # Deliberately one line per process, not one per pattern: the register-type
      # mechanisms already emit their own execution events, and Health Probe's
      # HTTP status is its own evidence. What is left is the *resolved state* --
      # which platform was detected, whether the Downward API arrived, what
      # privilege the process holds, how much was declared -- and that is a
      # single snapshot.
      def boot_summary
        # Lazily required: container.rb is loaded very early in boot and
        # health_controller pulls in action_controller.
        require "rails/health_controller"

        info = self_info
        {
          platform: platform,
          uid: Privilege.syscalls.uid,
          euid: Privilege.syscalls.euid,
          identity: info.pod_name ? "injected" : "absent",
          liveness: HealthController.liveness_path,
          readiness: HealthController.readiness_path,
          hooks: GracefulShutdown.hooks.size,
          init_steps: init_steps.size,
          checks: checks.size
        }
      end

      def emit_boot_summary
        Events.emit("boot", **boot_summary)
      end

      # --- Built-in diagnostics ------------------------------------------

      # Warns when no graceful-shutdown hook is registered -- on every platform.
      #
      # This is a *missing application implementation*, not a missing platform
      # feature, so the requirement does not change with where the app runs and
      # neither does the warning. Gating it on Kubernetes would recreate the very
      # problem this layer exists to solve: the developer works in Docker, hears
      # nothing, and only learns of the gap once the orchestrator starts stopping
      # Pods for rolling updates and scale-in.
      def managed_lifecycle_problem
        return unless GracefulShutdown.hooks.empty?

        "no graceful-shutdown hooks registered; orchestrators stop Pods routinely " \
          "(rolling updates, scale-in), so register cleanup with " \
          "Rails::Container::GracefulShutdown.on_shutdown"
      end

      # Process Containment: warns when the process runs as root.
      #
      # Detection only -- the layer never drops privileges itself. Enforcement is
      # the platform's job (securityContext, applied by the kubelet before the
      # process starts), so all the layer owes the developer is that the
      # requirement stops being invisible.
      #
      # Reported on every platform, because running as root is a property of the
      # image and the app, not of the orchestrator: the Restricted Pod Security
      # Standard will reject it later regardless of where the developer noticed.
      # Docker development silently runs as root, which is exactly why the
      # requirement stays invisible unless the layer says so up front.
      def process_containment_problem
        return unless Privilege.running_as_root?

        "running as root (uid 0); the Kubernetes Restricted Pod Security Standard rejects this. " \
          "Run as non-root: build the image with a USER, or declare it in " \
          "process_containment (run_as_non_root / allow_privilege_escalation: false) " \
          "so the generated securityContext enforces it"
      end

      # Warns when the Downward API identity was not injected.
      #
      # Kubernetes-only on purpose, and the exception to the rule above: what is
      # missing here is a value the *platform* supplies through the manifest, not
      # an implementation the app forgot. Docker has no Downward API at all, so
      # asking for POD_NAME there would be pure noise.
      def self_awareness_problem
        return unless platform == :kubernetes

        missing = %w[POD_NAME POD_NAMESPACE NODE_NAME].select { |var| ENV[var].to_s.empty? }
        return if missing.empty?

        "Downward API identity not fully injected (missing #{missing.join('/')}); check the manifest"
      end

      private
        def run_checks
          checks.filter_map do |check|
            message = check.block.call
            next if message.nil?

            { name: check.name, severity: check.severity, message: message }
          end
        end
    end
  end
end
