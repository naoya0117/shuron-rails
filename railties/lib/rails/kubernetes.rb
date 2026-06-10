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

    # Self Awareness: the pod's own metadata, injected by the Kubernetes
    # Downward API as environment variables. All fields are +nil+ when not
    # injected (e.g. local/Docker), which is how the layer absorbs the
    # difference between platforms.
    SelfInfo = Struct.new(:pod_name, :namespace, :node_name, :pod_ip, :service_account, keyword_init: true)

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
      # +config/kubernetes.rb+ on first access for the current application.
      def definition
        load_definition!
      end

      # Loads +config/kubernetes.rb+ (when present) into +config.x.kubernetes+
      # and records the detected platform. Returns the settings Hash.
      #
      # All mutable state (load guard, checks, shutdown hooks) lives in a
      # per-application registry, so the file is read at most once per app and a
      # second application in the same process keeps its own registrations
      # (including ones made in initializers before this runs).
      def load_definition!
        reg = registry

        unless reg[:loaded]
          # config/kubernetes.rb is the single definition window; environment
          # differences belong inside it (generated using ENV, e.g.
          # Integer(ENV.fetch("KC_READINESS_TIMEOUT_MS", "300"))). Setting
          # config.x.kubernetes inline instead takes full control and suppresses
          # the file (no partial merge). +present?+, not truthiness, because
          # config.x auto-vivifies an empty OrderedOptions.
          unless app_config.x.kubernetes.present?
            file = Rails.root.join("config/kubernetes.rb")
            load file.to_s if file.exist?
          end
          reg[:loaded] = true
        end

        config = (app_config.x.kubernetes ||= {})
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

      # All registered checks (for the current application).
      def checks
        registry[:checks]
      end

      # Empties the check registry (used between boots/tests).
      def clear_checks
        registry[:checks] = []
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
      # process receives SIGTERM. See the :setup_kubernetes_lifecycle initializer.
      def on_shutdown(name, &block)
        shutdown_hooks << ShutdownHook.new(name, block)
        name
      end

      # All registered shutdown hooks (for the current application).
      def shutdown_hooks
        registry[:shutdown_hooks]
      end

      # Empties the shutdown hook registry and re-arms run_shutdown!.
      def clear_shutdown_hooks
        reg = registry
        reg[:shutdown_hooks] = []
        reg[:shutdown_ran] = false
      end

      # Runs every shutdown hook for +app+ once, in registration order. A
      # failing hook is logged and does not prevent the remaining cleanup from
      # running. +app+ is passed explicitly by deferred callers (e.g. at_exit)
      # so the right application's hooks run even if Rails.application changed.
      def run_shutdown!(app = Rails.application)
        reg = registry(app)
        return if reg[:shutdown_ran]
        reg[:shutdown_ran] = true

        reg[:shutdown_hooks].each do |hook|
          hook.block.call
        rescue StandardError => e
          # A failing hook is logged and does not stop the rest; fatal
          # exceptions (SystemExit, signals) are allowed to propagate.
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

      # Self Awareness: the pod's own metadata from the Downward API
      # environment variables (POD_NAME, POD_NAMESPACE, NODE_NAME, POD_IP,
      # POD_SERVICE_ACCOUNT). Values are +nil+ when not injected (local/Docker).
      def self_info
        SelfInfo.new(
          pod_name: ENV["POD_NAME"],
          namespace: ENV["POD_NAMESPACE"],
          node_name: ENV["NODE_NAME"],
          pod_ip: ENV["POD_IP"],
          service_account: ENV["POD_SERVICE_ACCOUNT"]
        )
      end

      # Diagnostic (Self Awareness): on Kubernetes, none of the Downward API
      # identity variables being present usually means the manifest forgot to
      # inject them. Returns a problem message or +nil+.
      def self_awareness_problem
        return unless platform == :kubernetes
        return if ENV["POD_NAME"] || ENV["POD_NAMESPACE"] || ENV["NODE_NAME"]

        "Downward API identity not injected (POD_NAME/POD_NAMESPACE/NODE_NAME); check the manifest"
      end

      private
        def app_config
          Rails.application.config
        end

        # Per-application mutable state, keyed on the application object so a
        # different app/root in the same process is fully isolated.
        def registry(app = Rails.application)
          (@registries ||= {})[app] ||=
            { loaded: false, checks: [], shutdown_hooks: [], shutdown_ran: false }
        end
    end
  end
end
