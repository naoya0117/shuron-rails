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
          # Only load the file when the app has not already configured
          # config.x.kubernetes inline (e.g. in config/environments/*.rb), so
          # explicit overrides are not clobbered. +present?+ rather than truthy,
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
    end
  end
end
