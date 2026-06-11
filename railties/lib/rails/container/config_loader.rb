# frozen_string_literal: true

module Rails
  module Container
    module ConfigLoader
      module_function

      # Loads config/container.rb once into Rails.application.config.x.container.
      # Idempotent: subsequent calls are no-ops.
      #
      # Note: We check `== true` explicitly because config.x.<undefined> returns
      # an empty ActiveSupport::OrderedOptions (truthy), not nil.
      def load!
        return if @loaded == true
        @loaded = true

        definition_file = Rails.root.join("config/container.rb")
        load definition_file.to_s if definition_file.exist?
      end
    end
  end
end
