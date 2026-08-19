# frozen_string_literal: true

require "rails/container/config_loader"
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
      # initialization, and the completion flag is only set after success so a
      # retry re-runs the (idempotent) steps.
      def run_init!
        return if @init_ran

        init_steps.each { |step| step.block.call }
        @init_ran = true
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

      # --- Process Containment -------------------------------------------

      # Drops the process to the declared unprivileged user, handing over the
      # paths it must keep writing to first.
      #
      # NOT called during boot, by design. The supported way to stop running as
      # root is the platform's own control: the +process_containment+ settings
      # already generate a +securityContext+ (+runAsNonRoot+, no privilege
      # escalation, all capabilities dropped) for the manifest, which the kubelet
      # enforces externally *before* the process starts. An in-process drop is
      # strictly weaker -- code runs as root until it happens, it is voluntary,
      # and changing uid mid-boot surprises anything else in the process (build
      # steps writing under Rails.root, test suites, an app that already lowered
      # only its effective ids). The layer therefore *reports* root execution
      # through diagnostics rather than silently dropping.
      #
      # Call this explicitly, early, only for the residual case where the process
      # genuinely must start as root (binding a privileged port, reading a
      # root-owned file) and that work cannot move to an Init Container:
      #
      #   # config/container.rb, at the top
      #   Rails::Container.contain_process!   # honours the settings below
      #
      #   process_containment: {
      #     run_as_user:     2000,               # target (also used by the manifest)
      #     drop_privileges: true,               # opt in to the in-process drop
      #     ensure_writable: ["log", "tmp"]      # chown these to the target first
      #   }
      #
      # +drop_privileges+ may also name the user explicitly (<tt>"app"</tt> or a
      # uid) when it differs from +run_as_user+. A no-op unless the process is
      # root and +drop_privileges+ is declared.
      #
      # Returns the Privilege::DropResult, or +nil+ when no drop was requested.
      def contain_process!
        settings = config[:process_containment] || {}
        target = fetch_setting(settings, :drop_privileges)
        return if target.nil? || target == false
        # Nothing to drop -- and nothing we *could* drop: handing files over and
        # calling initgroups both need privilege, so attempting either while
        # already unprivileged would raise EPERM instead of no-oping. The check
        # mirrors Privilege.drop_to: an effective uid of 0 still carries full
        # privilege, so only a process that is non-root by both measures is done.
        return unless Privilege.syscalls.uid.zero? || Privilege.syscalls.euid.zero?

        target = fetch_setting(settings, :run_as_user) if target == true
        raise ArgumentError, "drop_privileges requires run_as_user or an explicit user" if target.nil?

        pwent = Privilege.passwd_for(target)
        ensure_writable!(Array(fetch_setting(settings, :ensure_writable)), pwent)
        Privilege.drop_to(user: pwent.uid, group: fetch_setting(settings, :run_as_group))
      end

      # --- Built-in diagnostics ------------------------------------------

      # Warns on Kubernetes when no graceful-shutdown hook is registered.
      def managed_lifecycle_problem
        return unless platform == :kubernetes
        return unless GracefulShutdown.hooks.empty?

        "no graceful-shutdown hooks registered (use Rails::Container::GracefulShutdown.on_shutdown)"
      end

      # Process Containment: warns on Kubernetes when the process is running as
      # root -- either the real or the effective uid is 0, since an effective
      # uid of 0 still carries full privilege. The Restricted Pod Security
      # Standard rejects this, and it leaves any app-layer compromise running
      # with host-equivalent privileges. Surfacing it here is what gives this
      # pattern a Container-layer (code) foothold: Docker development silently
      # runs as root, so the requirement stays invisible until the cluster
      # rejects the Pod.
      def process_containment_problem
        return unless platform == :kubernetes
        return unless Privilege.syscalls.uid.zero? || Privilege.syscalls.euid.zero?

        "running as root (uid 0); the Kubernetes Restricted Pod Security Standard rejects this. " \
          "Run as non-root (securityContext.runAsNonRoot / allowPrivilegeEscalation: false) " \
          "or drop privileges at boot (Rails::Container::Privilege.drop_to)"
      end

      # Warns on Kubernetes when the Downward API identity was not injected.
      def self_awareness_problem
        return unless platform == :kubernetes

        missing = %w[POD_NAME POD_NAMESPACE NODE_NAME].select { |var| ENV[var].to_s.empty? }
        return if missing.empty?

        "Downward API identity not fully injected (missing #{missing.join('/')}); check the manifest"
      end

      private
        # Reads a Symbol key from container settings, tolerating the string-keyed
        # Hash that +kubernetes:convert+ writes (mirrors HealthController).
        def fetch_setting(settings, key)
          return unless settings.respond_to?(:key?)

          if settings.key?(key)
            settings[key]
          elsif settings.key?(key.to_s)
            settings[key.to_s]
          end
        end

        # Creates the declared paths (relative to Rails.root) and hands them to
        # the target user, so the app can still write after the drop. Done while
        # still root -- afterwards the process no longer has the privilege. Paths
        # already owned by the target are left alone, keeping restarts cheap.
        def ensure_writable!(paths, pwent)
          return if paths.empty?

          require "fileutils"
          paths.each do |path|
            full = Rails.root.join(path.to_s)
            FileUtils.mkdir_p(full)
            next if File.stat(full).uid == pwent.uid

            FileUtils.chown_R(pwent.uid, pwent.gid, full)
          end
        end

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
