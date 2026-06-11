# frozen_string_literal: true

require "abstract_unit"
require "minitest/mock"

class HealthControllerTest < ActionController::TestCase
  tests Rails::HealthController

  def setup
    Rails.application.routes.draw do
      get "/up" => "rails/health#show", as: :rails_health_check
      get "/kubernetes/health/live" => "rails/health#live", as: :rails_liveness_check
      get "/kubernetes/health/ready" => "rails/health#ready", as: :rails_readiness_check
    end
    @routes = Rails.application.routes
  end

  test "health controller renders green success page in HTML" do
    get :show, format: :html
    assert_response :success
    assert_match(/background-color: green/, @response.body)
  end

  test "health controller renders red internal server error page in HTML" do
    @controller.instance_eval do
      def render_up
        raise Exception, "some exception"
      end
    end
    get :show, format: :html
    assert_response :internal_server_error
    assert_match(/background-color: red/, @response.body)
  end

  test "health controller returns JSON success response" do
    get :show, format: :json
    assert_response :success
    assert_includes @response.content_type, "application/json"

    json_response = JSON.parse(@response.body)
    assert_equal "up", json_response["status"]
    assert_includes json_response, "timestamp"
    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, json_response["timestamp"])
  end

  test "health controller returns JSON error response" do
    @controller.instance_eval do
      def render_up
        raise Exception, "some exception"
      end
    end
    get :show, format: :json
    assert_response :internal_server_error
    assert_includes @response.content_type, "application/json"

    json_response = JSON.parse(@response.body)
    assert_equal "down", json_response["status"]
    assert_includes json_response, "timestamp"
    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, json_response["timestamp"])
  end

  test "health controller liveness endpoint returns success with empty body" do
    get :live
    assert_response :success
    assert_equal "", @response.body
  end

  test "health controller returns JSON readiness success response" do
    pool = Object.new
    connection = Object.new
    connection.define_singleton_method(:verify!) { true }
    pool.define_singleton_method(:with_connection) { |&block| block.call(connection) }

    ActiveRecord::Base.stub(:connection_pool, pool) do
      get :ready, format: :json
    end

    assert_response :success
    assert_includes @response.content_type, "application/json"

    json_response = JSON.parse(@response.body)
    assert_equal "ready", json_response["status"]
    assert_equal "ok", json_response.dig("checks", "database")
    assert_includes json_response, "timestamp"
    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, json_response["timestamp"])
  end

  test "health controller returns JSON readiness error response when database is unavailable" do
    pool = Object.new
    connection = Object.new
    connection.define_singleton_method(:verify!) { raise ActiveRecord::ConnectionNotEstablished, "db inactive" }
    pool.define_singleton_method(:with_connection) { |&block| block.call(connection) }

    ActiveRecord::Base.stub(:connection_pool, pool) do
      get :ready, format: :json
    end

    assert_response :service_unavailable
    assert_includes @response.content_type, "application/json"

    json_response = JSON.parse(@response.body)
    assert_equal "not_ready", json_response["status"]
    assert_equal "error", json_response.dig("checks", "database")
    assert_includes json_response, "timestamp"
    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, json_response["timestamp"])
  end

  test "health controller returns JSON readiness error response when database check raises" do
    pool = Object.new
    pool.define_singleton_method(:with_connection) { raise ActiveRecord::ConnectionNotEstablished, "db down" }

    ActiveRecord::Base.stub(:connection_pool, pool) do
      get :ready, format: :json
    end

    assert_response :service_unavailable
    assert_includes @response.content_type, "application/json"

    json_response = JSON.parse(@response.body)
    assert_equal "not_ready", json_response["status"]
    assert_equal "error", json_response.dig("checks", "database")
    assert_includes json_response, "timestamp"
    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, json_response["timestamp"])
  end

  test "health controller returns JSON readiness success response when database check is disabled" do
    original_config = Rails.application.config.x.kubernetes
    Rails.application.config.x.kubernetes = { readiness: { check_database: false } }

    get :ready, format: :json

    assert_response :success
    assert_includes @response.content_type, "application/json"

    json_response = JSON.parse(@response.body)
    assert_equal "ready", json_response["status"]
    assert_equal "skipped", json_response.dig("checks", "database")
    assert_includes json_response, "timestamp"
    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, json_response["timestamp"])
  ensure
    Rails.application.config.x.kubernetes = original_config
  end

  test "health controller readiness honors ENV-style string false for check_database" do
    original_config = Rails.application.config.x.kubernetes

    %w[false FALSE 0 off].each do |falsey|
      Rails.application.config.x.kubernetes = { readiness: { check_database: falsey } }

      get :ready, format: :json

      assert_response :success, "expected #{falsey.inspect} to disable the DB check"
      assert_equal "skipped", JSON.parse(@response.body).dig("checks", "database")
    end
  ensure
    Rails.application.config.x.kubernetes = original_config
  end

  test "health controller readiness path can be configured via container definition" do
    original_config = Rails.application.config.x.kubernetes
    Rails.application.config.x.kubernetes = { readiness: { path: "/health/readyz" } }

    assert_equal "/health/readyz", Rails::HealthController.readiness_path
  ensure
    Rails.application.config.x.kubernetes = original_config
  end

  test "health controller liveness path can be configured via container definition" do
    original_config = Rails.application.config.x.kubernetes
    Rails.application.config.x.kubernetes = { liveness: { path: "/health/livez" } }

    assert_equal "/health/livez", Rails::HealthController.liveness_path
  ensure
    Rails.application.config.x.kubernetes = original_config
  end

end
