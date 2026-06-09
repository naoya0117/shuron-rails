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
    end
  end
end
