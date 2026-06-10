# frozen_string_literal: true

require "abstract_unit"
require "rails/kubernetes"

class Rails::KubernetesLayerTest < ActiveSupport::TestCase
  PLATFORM_ENV = %w[KC_PLATFORM KUBERNETES_SERVICE_HOST POD_NAME POD_NAMESPACE NODE_NAME POD_IP POD_SERVICE_ACCOUNT].freeze

  setup do
    @saved = ENV.slice(*PLATFORM_ENV)
    PLATFORM_ENV.each { |k| ENV.delete(k) }
    Rails::Kubernetes.reset_checks
    Rails::Kubernetes.reset_init
    Rails::Kubernetes::GracefulShutdown.reset!
    @orig_config = Rails.application.config.x.kubernetes
    Rails.application.config.x.kubernetes = { diagnostics: {} }
  end

  teardown do
    PLATFORM_ENV.each { |k| ENV.delete(k) }
    @saved.each { |k, v| ENV[k] = v }
    Rails::Kubernetes.reset_checks
    Rails::Kubernetes.reset_init
    Rails::Kubernetes::GracefulShutdown.reset!
    Rails.application.config.x.kubernetes = @orig_config
  end

  # Platform ---------------------------------------------------------------

  test "platform is :kubernetes when KUBERNETES_SERVICE_HOST is present" do
    ENV["KUBERNETES_SERVICE_HOST"] = "10.0.0.1"
    assert_equal :kubernetes, Rails::Kubernetes.platform
  end

  test "platform defaults to :local and honors KC_PLATFORM" do
    assert_equal :local, Rails::Kubernetes.platform
    ENV["KC_PLATFORM"] = "compose"
    assert_equal :compose, Rails::Kubernetes.platform
  end

  # Check registry / diagnostics ------------------------------------------

  test "register_check requires a block" do
    assert_raises(ArgumentError) { Rails::Kubernetes.register_check(:x) }
  end

  test "diagnostics reports problems and honors ignore/enabled" do
    Rails::Kubernetes.register_check(:a) { "problem a" }
    Rails::Kubernetes.register_check(:b) { nil }
    assert_equal [:a], Rails::Kubernetes.diagnostics.map { |d| d[:name] }

    Rails.application.config.x.kubernetes = { diagnostics: { ignore: [:a] } }
    assert_empty Rails::Kubernetes.diagnostics

    Rails.application.config.x.kubernetes = { diagnostics: { enabled: false } }
    Rails::Kubernetes.register_check(:c) { "still a problem" }
    assert_empty Rails::Kubernetes.diagnostics
  end

  test "emit_diagnostics logs each problem at its severity" do
    Rails::Kubernetes.register_check(:a, severity: :warn) { "warn problem" }
    Rails::Kubernetes.register_check(:b, severity: :info) { "info problem" }
    logger = Struct.new(:warns, :infos) do
      def warn(m) = warns << m
      def info(m) = infos << m
    end.new([], [])

    Rails::Kubernetes.emit_diagnostics(logger)

    assert(logger.warns.any? { |m| m.include?("warn problem") })
    assert(logger.infos.any? { |m| m.include?("info problem") })
  end

  # Init Container ---------------------------------------------------------

  test "init_step requires a block and runs steps once, in order, fail-fast" do
    assert_raises(ArgumentError) { Rails::Kubernetes.init_step(:x) }

    order = []
    Rails::Kubernetes.init_step(:a) { order << :a }
    Rails::Kubernetes.init_step(:b) { order << :b }
    Rails::Kubernetes.run_init!
    Rails::Kubernetes.run_init!
    assert_equal [:a, :b], order
  end

  test "run_init! re-raises and does not mark complete on failure" do
    Rails::Kubernetes.init_step(:boom) { raise "fail" }
    assert_raises(RuntimeError) { Rails::Kubernetes.run_init! }
    Rails::Kubernetes.reset_init
    ran = false
    Rails::Kubernetes.init_step(:ok) { ran = true }
    Rails::Kubernetes.run_init!
    assert ran
  end

  # Self Awareness ---------------------------------------------------------

  test "self_info reads Downward API env, nil off Kubernetes" do
    assert_nil Rails::Kubernetes.self_info.pod_name

    ENV["POD_NAME"] = "web-abc"
    ENV["POD_NAMESPACE"] = "prod"
    info = Rails::Kubernetes.self_info
    assert_equal "web-abc", info.pod_name
    assert_equal "prod", info.namespace
  end

  # Built-in diagnostics ---------------------------------------------------

  test "managed_lifecycle_problem warns on kubernetes without shutdown hooks" do
    ENV["KC_PLATFORM"] = "kubernetes"
    assert Rails::Kubernetes.managed_lifecycle_problem
    Rails::Kubernetes::GracefulShutdown.on_shutdown { }
    assert_nil Rails::Kubernetes.managed_lifecycle_problem
  end

  test "self_awareness_problem warns on kubernetes without Downward API" do
    ENV["KC_PLATFORM"] = "kubernetes"
    assert Rails::Kubernetes.self_awareness_problem
    ENV["POD_NAME"] = "web-abc"
    assert_nil Rails::Kubernetes.self_awareness_problem
  end
end
