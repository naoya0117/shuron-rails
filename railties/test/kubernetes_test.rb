# frozen_string_literal: true

require "abstract_unit"
require "rails/kubernetes"

class Rails::KubernetesPlatformTest < ActiveSupport::TestCase
  setup do
    @original_kc_platform = ENV["KC_PLATFORM"]
    @original_service_host = ENV["KUBERNETES_SERVICE_HOST"]
    ENV.delete("KC_PLATFORM")
    ENV.delete("KUBERNETES_SERVICE_HOST")
  end

  teardown do
    ENV["KC_PLATFORM"] = @original_kc_platform
    ENV["KUBERNETES_SERVICE_HOST"] = @original_service_host
  end

  test "platform is :kubernetes when KUBERNETES_SERVICE_HOST is present" do
    ENV["KUBERNETES_SERVICE_HOST"] = "10.0.0.1"
    assert_equal :kubernetes, Rails::Kubernetes.platform
  end

  test "platform is :local by default" do
    assert_equal :local, Rails::Kubernetes.platform
  end

  test "platform honors an explicit KC_PLATFORM override" do
    ENV["KC_PLATFORM"] = "compose"
    assert_equal :compose, Rails::Kubernetes.platform
  end

  test "KC_PLATFORM override takes precedence over KUBERNETES_SERVICE_HOST" do
    ENV["KUBERNETES_SERVICE_HOST"] = "10.0.0.1"
    ENV["KC_PLATFORM"] = "local"
    assert_equal :local, Rails::Kubernetes.platform
  end

  test "an invalid KC_PLATFORM value is ignored" do
    ENV["KC_PLATFORM"] = "bogus"
    ENV["KUBERNETES_SERVICE_HOST"] = "10.0.0.1"
    assert_equal :kubernetes, Rails::Kubernetes.platform
  end
end

class Rails::KubernetesCheckRegistryTest < ActiveSupport::TestCase
  setup { Rails::Kubernetes.clear_checks }
  teardown { Rails::Kubernetes.clear_checks }

  test "register_check stores a named check" do
    Rails::Kubernetes.register_check(:health) { nil }
    assert_equal [:health], Rails::Kubernetes.checks.map(&:name)
  end

  test "a check defaults to :warn severity" do
    Rails::Kubernetes.register_check(:health) { nil }
    assert_equal :warn, Rails::Kubernetes.checks.first.severity
  end

  test "run_checks reports only checks whose block returns a problem message" do
    Rails::Kubernetes.register_check(:ok_check) { nil }
    Rails::Kubernetes.register_check(:bad_check, severity: :warn) { "graceful shutdown not configured" }
    Rails::Kubernetes.register_check(:info_check, severity: :info) { "pod identity not logged" }

    results = Rails::Kubernetes.run_checks

    assert_equal 2, results.size
    bad = results.find { |r| r[:name] == :bad_check }
    assert_equal :warn, bad[:severity]
    assert_equal "graceful shutdown not configured", bad[:message]
    assert_includes results.map { |r| r[:name] }, :info_check
    assert_not_includes results.map { |r| r[:name] }, :ok_check
  end

  test "clear_checks empties the registry" do
    Rails::Kubernetes.register_check(:health) { nil }
    Rails::Kubernetes.clear_checks
    assert_empty Rails::Kubernetes.checks
  end
end

class Rails::KubernetesLifecycleTest < ActiveSupport::TestCase
  setup { Rails::Kubernetes.clear_shutdown_hooks }
  teardown { Rails::Kubernetes.clear_shutdown_hooks }

  test "on_shutdown registers a named hook" do
    Rails::Kubernetes.on_shutdown(:cleanup) { }
    assert_equal [:cleanup], Rails::Kubernetes.shutdown_hooks.map(&:name)
  end

  test "run_shutdown! runs hooks in registration order" do
    order = []
    Rails::Kubernetes.on_shutdown(:a) { order << :a }
    Rails::Kubernetes.on_shutdown(:b) { order << :b }

    Rails::Kubernetes.run_shutdown!

    assert_equal [:a, :b], order
  end

  test "run_shutdown! runs hooks at most once" do
    count = 0
    Rails::Kubernetes.on_shutdown(:c) { count += 1 }

    Rails::Kubernetes.run_shutdown!
    Rails::Kubernetes.run_shutdown!

    assert_equal 1, count
  end

  test "a later shutdown hook still runs when an earlier one raises" do
    ran = []
    Rails::Kubernetes.on_shutdown(:boom) { ran << :boom; raise "fail" }
    Rails::Kubernetes.on_shutdown(:after) { ran << :after }

    Rails::Kubernetes.run_shutdown!

    assert_equal [:boom, :after], ran
  end

  test "managed_lifecycle_problem warns on kubernetes without shutdown hooks" do
    original = ENV["KC_PLATFORM"]
    ENV["KC_PLATFORM"] = "kubernetes"
    assert Rails::Kubernetes.managed_lifecycle_problem

    Rails::Kubernetes.on_shutdown(:cleanup) { }
    assert_nil Rails::Kubernetes.managed_lifecycle_problem
  ensure
    ENV["KC_PLATFORM"] = original
  end

  test "managed_lifecycle_problem is silent off kubernetes" do
    original = ENV["KC_PLATFORM"]
    ENV["KC_PLATFORM"] = "local"
    assert_nil Rails::Kubernetes.managed_lifecycle_problem
  ensure
    ENV["KC_PLATFORM"] = original
  end
end

class Rails::KubernetesInitTest < ActiveSupport::TestCase
  setup { Rails::Kubernetes.clear_init_steps }
  teardown { Rails::Kubernetes.clear_init_steps }

  test "init_step registers a named step" do
    Rails::Kubernetes.init_step(:migrate) { }
    assert_equal [:migrate], Rails::Kubernetes.init_steps.map(&:name)
  end

  test "run_init! runs steps in registration order" do
    order = []
    Rails::Kubernetes.init_step(:a) { order << :a }
    Rails::Kubernetes.init_step(:b) { order << :b }

    Rails::Kubernetes.run_init!

    assert_equal [:a, :b], order
  end

  test "run_init! runs steps at most once" do
    count = 0
    Rails::Kubernetes.init_step(:c) { count += 1 }

    Rails::Kubernetes.run_init!
    Rails::Kubernetes.run_init!

    assert_equal 1, count
  end

  test "run_init! re-raises a failing step (initialization must not continue)" do
    ran = []
    Rails::Kubernetes.init_step(:boom) { ran << :boom; raise "fail" }
    Rails::Kubernetes.init_step(:after) { ran << :after }

    assert_raises(RuntimeError) { Rails::Kubernetes.run_init! }
    assert_equal [:boom], ran
  end
end

class Rails::KubernetesSelfAwarenessTest < ActiveSupport::TestCase
  SELF_ENV = %w[POD_NAME POD_NAMESPACE NODE_NAME POD_IP POD_SERVICE_ACCOUNT KC_PLATFORM].freeze

  setup { @saved = ENV.slice(*SELF_ENV); SELF_ENV.each { |k| ENV.delete(k) } }
  teardown { SELF_ENV.each { |k| ENV.delete(k) }; @saved.each { |k, v| ENV[k] = v } }

  test "self_info exposes injected Downward API values" do
    ENV["POD_NAME"] = "web-abc"
    ENV["POD_NAMESPACE"] = "prod"
    ENV["NODE_NAME"] = "node-1"

    info = Rails::Kubernetes.self_info

    assert_equal "web-abc", info.pod_name
    assert_equal "prod", info.namespace
    assert_equal "node-1", info.node_name
  end

  test "self_info is nil-valued when nothing is injected (Docker/local)" do
    info = Rails::Kubernetes.self_info

    assert_nil info.pod_name
    assert_nil info.namespace
  end

  test "self_awareness_problem warns on kubernetes when Downward API is absent" do
    ENV["KC_PLATFORM"] = "kubernetes"
    assert Rails::Kubernetes.self_awareness_problem

    ENV["POD_NAME"] = "web-abc"
    assert_nil Rails::Kubernetes.self_awareness_problem
  end

  test "self_awareness_problem is silent off kubernetes" do
    ENV["KC_PLATFORM"] = "local"
    assert_nil Rails::Kubernetes.self_awareness_problem
  end
end

class Rails::KubernetesDefinitionTest < ActiveSupport::TestCase
  test "definition returns an already-populated config without reloading" do
    original = Rails.application.config.x.kubernetes
    Rails.application.config.x.kubernetes = { readiness: { path: "/already" } }

    assert_equal "/already", Rails::Kubernetes.definition.dig(:readiness, :path)
  ensure
    Rails.application.config.x.kubernetes = original
  end
end
