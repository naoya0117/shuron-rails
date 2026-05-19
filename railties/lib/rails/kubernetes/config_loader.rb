# frozen_string_literal: true

module Rails
  module Kubernetes
    module ConfigLoader
      module_function

      # Loads config/kubernetes.rb once into Rails.application.config.x.kubernetes.
      # Idempotent: subsequent calls are no-ops.
      #
      # Note: We check `== true` explicitly because config.x.<undefined> returns
      # an empty ActiveSupport::OrderedOptions (truthy), not nil.
      def load!
        return if @loaded == true
        @loaded = true

        definition_file = Rails.root.join("config/kubernetes.rb")
        load definition_file.to_s if definition_file.exist?
      end
    end
  end
end
