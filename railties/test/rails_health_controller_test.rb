# frozen_string_literal: true

require "abstract_unit"
require "minitest/mock"
require "rails/container"

class HealthControllerTest < ActionController::TestCase
  tests Rails::HealthController

  def setup
    Rails.application.routes.draw do
      get "/up" => "rails/health#show", as: :rails_health_check
      get "/container/health/live" => "rails/health#live", as: :rails_liveness_check
      get "/container/health/ready" => "rails/health#ready", as: :rails_readiness_check
    end
    @routes = Rails.application.routes
    @orig_container = Rails.application.config.x.container
    Rails::Container.reset_readiness_checks
  end

  def teardown
    Rails::Container.reset_readiness_checks
    Rails.application.config.x.container = @orig_container
  end

  # DB 検査が通る pool を stub する。登録した readiness_check だけを見たい
  # テストで、DB 側の都合が結果に混ざらないようにする。
  def with_healthy_database
    pool = Object.new
    connection = Object.new
    connection.define_singleton_method(:verify!) { true }
    pool.define_singleton_method(:with_connection) { |&block| block.call(connection) }
    ActiveRecord::Base.stub(:connection_pool, pool) { yield }
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
    original_config = Rails.application.config.x.container
    Rails.application.config.x.container = { readiness: { check_database: false } }

    get :ready, format: :json

    assert_response :success
    assert_includes @response.content_type, "application/json"

    json_response = JSON.parse(@response.body)
    assert_equal "ready", json_response["status"]
    assert_equal "skipped", json_response.dig("checks", "database")
    assert_includes json_response, "timestamp"
    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, json_response["timestamp"])
  ensure
    Rails.application.config.x.container = original_config
  end

  test "health controller readiness honors ENV-style string false for check_database" do
    original_config = Rails.application.config.x.container

    %w[false FALSE 0 off].each do |falsey|
      Rails.application.config.x.container = { readiness: { check_database: falsey } }

      get :ready, format: :json

      assert_response :success, "expected #{falsey.inspect} to disable the DB check"
      assert_equal "skipped", JSON.parse(@response.body).dig("checks", "database")
    end
  ensure
    Rails.application.config.x.container = original_config
  end

  test "health controller readiness path can be configured via container definition" do
    original_config = Rails.application.config.x.container
    Rails.application.config.x.container = { readiness: { path: "/health/readyz" } }

    assert_equal "/health/readyz", Rails::HealthController.readiness_path
  ensure
    Rails.application.config.x.container = original_config
  end

  test "health controller liveness path can be configured via container definition" do
    original_config = Rails.application.config.x.container
    Rails.application.config.x.container = { liveness: { path: "/health/livez" } }

    assert_equal "/health/livez", Rails::HealthController.liveness_path
  ensure
    Rails.application.config.x.container = original_config
  end


  # --- readiness_check(アプリが登録する依存)------------------------------

  test "readiness_check requires a block" do
    assert_raises(ArgumentError) { Rails::Container.readiness_check(:redis) }
  end

  test "registered readiness checks are reported alongside the database" do
    Rails::Container.readiness_check(:redis) { true }
    Rails::Container.readiness_check(:search) { "PONG" }

    with_healthy_database { get :ready, format: :json }

    assert_response :success
    json = JSON.parse(@response.body)
    assert_equal "ready", json["status"]
    assert_equal "ok", json.dig("checks", "database")
    assert_equal "ok", json.dig("checks", "redis")
    assert_equal "ok", json.dig("checks", "search")
  end

  test "a raising readiness check makes the probe not_ready without breaking the others" do
    Rails::Container.readiness_check(:redis) { raise "connection refused" }
    Rails::Container.readiness_check(:search) { true }

    with_healthy_database { get :ready, format: :json }

    assert_response :service_unavailable
    json = JSON.parse(@response.body)
    assert_equal "not_ready", json["status"]
    assert_equal "ok",    json.dig("checks", "database")
    assert_equal "error", json.dig("checks", "redis")
    assert_equal "ok",    json.dig("checks", "search")
  end

  test "a readiness check returning false or nil counts as a failure" do
    Rails::Container.readiness_check(:falsey) { false }
    Rails::Container.readiness_check(:nily)   { nil }

    with_healthy_database { get :ready, format: :json }

    assert_response :service_unavailable
    json = JSON.parse(@response.body)
    assert_equal "error", json.dig("checks", "falsey")
    assert_equal "error", json.dig("checks", "nily")
  end

  # 予算はプローブ全体に 1 つである。ここが per-check だと、依存を足すたびに
  # kubelet の timeoutSeconds との整合を開発者が計算する必要が出る。
  test "the timeout budget covers the whole probe and names the check that hung" do
    Rails.application.config.x.container = { readiness: { timeout_ms: 50 } }
    Rails::Container.readiness_check(:slow) { sleep 5 }
    Rails::Container.readiness_check(:never_reached) { true }

    with_healthy_database { get :ready, format: :json }

    assert_response :service_unavailable
    json = JSON.parse(@response.body)
    assert_equal "ok",      json.dig("checks", "database")
    assert_equal "timeout", json.dig("checks", "slow")
    # 予算切れの後ろは走っていないので、通ったことにはしない。
    assert_nil json.dig("checks", "never_reached")
  end

  # 既知の限界を仕様として固定する。Timeout は Timeout::ExitException
  # (Exception の子孫で StandardError ではない)でブロックを巻き戻すので、
  # ブロック自身が rescue Exception していると予算は発火しない。外から防ぐ手段は
  # 無い。層は予算を持ち、それを妨害しないのがブロック側の責務である
  # (init_step の冪等性と同じ形)。
  #
  # 層側の wrapper が rescue Exception だったときは、この形でない普通の検査でも
  # 予算が発火しなかった(実測: sleep する検査が timeout ではなく error として
  # 完走まで走った)。そちらは rescue StandardError に直してある。
  test "a check that rescues Exception itself defeats the budget (documented limit)" do
    Rails.application.config.x.container = { readiness: { timeout_ms: 50 } }
    Rails::Container.readiness_check(:greedy) do
      begin
        sleep 0.2
      rescue Exception
        true
      end
    end

    with_healthy_database { get :ready, format: :json }

    # 予算を越えて走り切り、成功として報告される。これが防げないことを明示する。
    assert_response :success
    json = JSON.parse(@response.body)
    assert_equal "ok", json.dig("checks", "greedy")
  end

  test "readiness with no registered checks behaves as before" do
    with_healthy_database { get :ready, format: :json }

    assert_response :success
    json = JSON.parse(@response.body)
    assert_equal({ "database" => "ok" }, json["checks"])
  end
end
