# frozen_string_literal: true

module Rails
  # = \Rails \Kubernetes layer
  #
  # Foundation for the Kubernetes-layer features (health probes, lifecycle,
  # init steps, self-awareness). It provides a single place to detect the
  # runtime platform so individual features can absorb the differences between
  # local/Docker development and a Kubernetes cluster behind one API.
  module Kubernetes
    # Platforms the Kubernetes layer knows how to adapt to.
    PLATFORMS = %i[kubernetes compose local].freeze

    # A diagnostic check registered by a Kubernetes-layer feature. +block+ is
    # expected to return a problem message (String) when something the feature
    # needs is missing/unconfigured, or +nil+ when everything is in order.
    Check = Struct.new(:name, :severity, :block)

    # A graceful-shutdown hook (Managed Lifecycle). +block+ is the cleanup the
    # application runs when the process is asked to terminate (SIGTERM).
    ShutdownHook = Struct.new(:name, :block)

    class << self
      # Detects the runtime platform, used by the layer to absorb
      # platform-specific differences:
      #
      # 1. An explicit <tt>KC_PLATFORM</tt> environment variable
      #    (+kubernetes+, +compose+ or +local+) always wins.
      # 2. Otherwise, the presence of <tt>KUBERNETES_SERVICE_HOST</tt> (injected
      #    into every pod by Kubernetes) means we are running on +:kubernetes+.
      # 3. Otherwise we assume +:local+.
      def platform
        override = ENV["KC_PLATFORM"].to_s
        return override.to_sym if PLATFORMS.include?(override.to_sym)

        if ENV["KUBERNETES_SERVICE_HOST"].to_s.empty?
          :local
        else
          :kubernetes
        end
      end

      # Returns the Kubernetes-layer settings (+config.x.kubernetes+), loading
      # +config/kubernetes.rb+ on first access for the current application if it
      # has not been loaded yet. The load guard (not the value) is checked,
      # because +config.x+ auto-vivifies missing keys to a truthy empty
      # OrderedOptions, which would otherwise mask "not loaded yet".
      def definition
        load_definition! unless @loaded_app.equal?(Rails.application)
        Rails.application.config.x.kubernetes || {}
      end

      # Loads +config/kubernetes.rb+ (when present) into +config.x.kubernetes+
      # and records the detected platform. Returns the settings Hash.
      #
      # The file is read at most once per application instance: a lazy lookup
      # followed by the boot initializer does not execute the definition (and
      # its register_check calls) twice. The guard is keyed on the current
      # +Rails.application+ object, so a different application in the same
      # process (even for the same root) loads its own definition and starts
      # from a clean check registry.
      def load_definition!
        app = Rails.application

        unless @loaded_app.equal?(app)
          clear_checks
          # config/kubernetes.rb is the single definition window; environment
          # differences belong inside it (it is generated using ENV, e.g.
          # Integer(ENV.fetch("KC_READINESS_TIMEOUT_MS", "300"))). Setting
          # config.x.kubernetes inline instead therefore takes full control and
          # suppresses the file (no partial merge). +present?+, not truthiness,
          # because config.x auto-vivifies an empty OrderedOptions.
          unless app.config.x.kubernetes.present?
            file = Rails.root.join("config/kubernetes.rb")
            load file.to_s if file.exist?
          end
          @loaded_app = app
        end

        config = (app.config.x.kubernetes ||= {})
        config[:platform] ||= platform
        config
      end

      # Registers a diagnostic check for a Kubernetes-layer feature. The +block+
      # returns a problem message when the feature is missing/unconfigured, or
      # +nil+ when satisfied. Reported by Rails::Kubernetes.run_checks (see the
      # diagnostics feature, +bin/rails kubernetes:doctor+).
      def register_check(name, severity: :warn, &block)
        checks << Check.new(name, severity, block)
        name
      end

      # All registered checks.
      def checks
        @checks ||= []
      end

      # Empties the check registry (used between boots/tests).
      def clear_checks
        @checks = []
      end

      # Runs every registered check and returns one entry per check that
      # reported a problem: <tt>{ name:, severity:, message: }</tt>.
      def run_checks
        checks.filter_map do |check|
          message = check.block.call
          next if message.nil?

          { name: check.name, severity: check.severity, message: message }
        end
      end

      # Registers a graceful-shutdown hook (Managed Lifecycle). The +block+ is
      # the application's cleanup, run (once, in registration order) when the
      # process receives SIGTERM. See the :install_kubernetes_signal_handlers
      # initializer.
      def on_shutdown(name, &block)
        shutdown_hooks << ShutdownHook.new(name, block)
        name
      end

      # All registered shutdown hooks.
      def shutdown_hooks
        @shutdown_hooks ||= []
      end

      # Empties the shutdown hook registry and re-arms run_shutdown!.
      def clear_shutdown_hooks
        @shutdown_hooks = []
        @shutdown_ran = false
      end

      # Runs every shutdown hook once, in registration order. A failing hook is
      # logged and does not prevent the remaining cleanup from running.
      def run_shutdown!
        return if @shutdown_ran
        @shutdown_ran = true

        shutdown_hooks.each do |hook|
          hook.block.call
        rescue Exception => e
          Rails.logger&.error("[kubernetes] shutdown hook #{hook.name.inspect} failed: #{e.class}: #{e.message}")
        end
      end

      # Diagnostic (Managed Lifecycle): on Kubernetes a container should clean
      # up on SIGTERM, so the absence of any shutdown hook is worth a warning.
      # Returns a problem message or +nil+.
      def managed_lifecycle_problem
        return unless platform == :kubernetes
        return unless shutdown_hooks.empty?

        "no graceful-shutdown hooks registered (use Rails::Kubernetes.on_shutdown)"
      end
    end
  end
end
