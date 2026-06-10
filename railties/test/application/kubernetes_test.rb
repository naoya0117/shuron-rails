# frozen_string_literal: true

require "isolation/abstract_unit"
require "rack/test"

module ApplicationTests
  class KubernetesTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::Isolation
    include Rack::Test::Methods

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

    test "inline config.x.kubernetes is not clobbered by config/kubernetes.rb" do
      app_file "config/kubernetes.rb", <<-RUBY
        Rails.application.configure do
          config.x.kubernetes = { readiness: { check_database: true } }
        end
      RUBY
      app_file "config/initializers/000_inline_kubernetes.rb", <<-RUBY
        Rails.application.config.x.kubernetes = { readiness: { check_database: false } }
      RUBY

      app "development"

      assert_equal false,
        Rails.application.config.x.kubernetes[:readiness][:check_database]
    end

    test "on_shutdown hooks registered in an initializer survive boot" do
      app_file "config/initializers/register_shutdown.rb", <<-RUBY
        Rails::Kubernetes.on_shutdown(:from_initializer) { }
      RUBY

      app "development"

      assert_includes Rails::Kubernetes.shutdown_hooks.map(&:name), :from_initializer
    end

    test "a custom liveness path in config/kubernetes.rb drives the registered route" do
      app_file "config/kubernetes.rb", <<-RUBY
        Rails.application.configure do
          config.x.kubernetes = { liveness: { path: "/health/livez" } }
        end
      RUBY

      app "development"

      get "/health/livez"
      assert_equal 200, last_response.status
    end
  end
end
