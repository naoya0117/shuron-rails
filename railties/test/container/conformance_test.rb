# frozen_string_literal: true

require "abstract_unit"
require "rails/container"
require "rails/container/conformance"

class Rails::ContainerConformanceTest < ActiveSupport::TestCase
  PLATFORM_ENV = %w[CONTAINER_PLATFORM KUBERNETES_SERVICE_HOST POD_NAME POD_NAMESPACE NODE_NAME POD_IP POD_SERVICE_ACCOUNT].freeze

  setup do
    @saved = ENV.slice(*PLATFORM_ENV)
    PLATFORM_ENV.each { |k| ENV.delete(k) }
    Rails::Container.reset_checks
    Rails::Container.reset_init
    Rails::Container::GracefulShutdown.reset!
    Rails::Container::Privilege.reset!
    @orig_config = Rails.application.config.x.container
    Rails.application.config.x.container = { diagnostics: {} }
  end

  teardown do
    PLATFORM_ENV.each { |k| ENV.delete(k) }
    @saved.each { |k, v| ENV[k] = v }
    Rails::Container.reset_checks
    Rails::Container.reset_init
    Rails::Container::GracefulShutdown.reset!
    Rails::Container::Privilege.reset!
    Rails.application.config.x.container = @orig_config
  end

  # A minimal rack app that mimics the health endpoints so conformance can be
  # exercised without a full server: 200 for liveness, +ready_status+ for readiness.
  def health_app(ready_status: 200)
    live = Rails::HealthController.liveness_path
    ready = Rails::HealthController.readiness_path
    lambda do |env|
      case env["PATH_INFO"]
      when live then [200, {}, ["ok"]]
      when ready then [ready_status, {}, ["ready"]]
      else [404, {}, ["not found"]]
      end
    end
  end

  def result_for(results, pattern)
    results.find { |r| r.pattern == pattern }
  end

  test "health_probe passes when liveness 200 and readiness answers (200 or 503)" do
    pass = Rails::Container::Conformance.run(app: health_app(ready_status: 200))
    assert_equal :pass, result_for(pass, "Health Probe").status

    not_ready = Rails::Container::Conformance.run(app: health_app(ready_status: 503))
    assert_equal :pass, result_for(not_ready, "Health Probe").status
  end

  test "health_probe fails when routes are not mounted" do
    app = ->(_env) { [404, {}, ["not found"]] }
    results = Rails::Container::Conformance.run(app: app)
    assert_equal :fail, result_for(results, "Health Probe").status
  end

  test "managed_lifecycle is na without hooks, pass with a hook" do
    na = Rails::Container::Conformance.run(app: health_app)
    assert_equal :na, result_for(na, "Managed Lifecycle").status

    Rails::Container::GracefulShutdown.on_shutdown { }
    pass = Rails::Container::Conformance.run(app: health_app)
    assert_equal :pass, result_for(pass, "Managed Lifecycle").status
  end

  # Init Container is opt-in: an app with no init steps is :na (not a failure);
  # any declared step (name is arbitrary) makes it :pass. The step name below is
  # a neutral example -- the framework requires no particular step.
  test "init_container is na without steps, pass listing declared steps" do
    na = Rails::Container::Conformance.run(app: health_app)
    assert_equal :na, result_for(na, "Init Container").status

    Rails::Container.init_step(:example_step) { }
    pass = Rails::Container::Conformance.run(app: health_app)
    result = result_for(pass, "Init Container")
    assert_equal :pass, result.status
    assert_includes result.detail, "example_step"
  end

  test "self_awareness passes off kubernetes (nil) and on kubernetes with injection" do
    off = Rails::Container::Conformance.run(app: health_app)
    assert_equal :pass, result_for(off, "Self Awareness").status

    ENV["POD_NAME"] = "web-abc"
    ENV["POD_NAMESPACE"] = "prod"
    ENV["NODE_NAME"] = "node-1"
    on = Rails::Container::Conformance.run(app: health_app, platform: :kubernetes)
    on_result = result_for(on, "Self Awareness")
    assert_equal :pass, on_result.status
    assert_includes on_result.detail, "web-abc"
  end

  test "self_awareness fails on kubernetes when identity is not injected" do
    results = Rails::Container::Conformance.run(app: health_app, platform: :kubernetes)
    assert_equal :fail, result_for(results, "Self Awareness").status
  end

  # Stand-in for the id syscalls, so a non-root test runner can model root.
  FakeIds = Struct.new(:uid, :euid)

  test "process_containment fails as root, passes as non-root" do
    Rails::Container::Privilege.syscalls = FakeIds.new(0, 0)
    results = Rails::Container::Conformance.run(app: health_app)
    assert_equal :fail, result_for(results, "Process Containment").status

    Rails::Container::Privilege.syscalls = FakeIds.new(1000, 1000)
    results = Rails::Container::Conformance.run(app: health_app)
    assert_equal :pass, result_for(results, "Process Containment").status
  end

  test "process_containment fails when only the effective uid is root" do
    # Layer 1 must judge a partial drop the same way the diagnostic does: an
    # effective uid of 0 still carries every privilege the Restricted PSS bars.
    Rails::Container::Privilege.syscalls = FakeIds.new(1000, 0)

    results = Rails::Container::Conformance.run(app: health_app)

    assert_equal :fail, result_for(results, "Process Containment").status
  end

  test "diagnostics reports pending checks" do
    Rails::Container.register_check(:secret_key_base) { "missing" }
    results = Rails::Container::Conformance.run(app: health_app)
    result = result_for(results, "Diagnostics")
    assert_equal :pass, result.status
    assert_includes result.detail, "secret_key_base"
  end

  test "run returns a result for every pattern" do
    results = Rails::Container::Conformance.run(app: health_app)
    patterns = results.map(&:pattern)
    assert_equal ["Health Probe", "Managed Lifecycle", "Init Container",
                  "Self Awareness", "Process Containment", "Diagnostics"], patterns
  end
end
