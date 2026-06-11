# frozen_string_literal: true

require "rails/container/config_loader"
require "rails/container/graceful_shutdown"

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

      # --- Built-in diagnostics ------------------------------------------

      # Warns on Kubernetes when no graceful-shutdown hook is registered.
      def managed_lifecycle_problem
        return unless platform == :kubernetes
        return unless GracefulShutdown.hooks.empty?

        "no graceful-shutdown hooks registered (use Rails::Container::GracefulShutdown.on_shutdown)"
      end

      # Warns on Kubernetes when the Downward API identity was not injected.
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
