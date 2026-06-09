# frozen_string_literal: true

require "isolation/abstract_unit"

module ApplicationTests
  class KubernetesTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::Isolation

    def setup
      build_app
    end

    def teardown
      teardown_app
    end

    test "config/kubernetes.rb is loaded at boot into config.x.kubernetes" do
      app_file "config/kubernetes.rb", <<-RUBY
        Rails.application.configure do
          config.x.kubernetes = { readiness: { path: "/health/readyz" } }
        end
      RUBY

      app "development"

      assert_equal "/health/readyz",
        Rails.application.config.x.kubernetes[:readiness][:path]
    end

    test "config.x.kubernetes[:platform] is detected at boot" do
      app "development"

      assert_includes Rails::Kubernetes::PLATFORMS,
        Rails.application.config.x.kubernetes[:platform]
    end
  end
end
