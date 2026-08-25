# frozen_string_literal: true

require "abstract_unit"
require "stringio"
require "rails/container"

class Rails::ContainerLayerTest < ActiveSupport::TestCase
  PLATFORM_ENV = %w[CONTAINER_PLATFORM KUBERNETES_SERVICE_HOST POD_NAME POD_NAMESPACE NODE_NAME POD_IP POD_SERVICE_ACCOUNT].freeze

  # Stand-in for the id syscalls so a non-root test runner can model "currently
  # root" -- including the partial drop (real uid lowered, effective uid still 0)
  # that some images perform in their own boot code.
  class FakeSyscalls
    def initialize(start_uid:, start_euid: nil)
      @uid = start_uid
      @euid = start_euid.nil? ? start_uid : start_euid
    end

    def uid = @uid
    def euid = @euid
  end

  setup do
    @saved = ENV.slice(*PLATFORM_ENV)
    PLATFORM_ENV.each { |k| ENV.delete(k) }
    Rails::Container.reset_checks
    Rails::Container.reset_init
    Rails::Container::GracefulShutdown.reset!
    Rails::Container::Privilege.reset!
    Rails::Container::Events.reset!
    Rails::Container::Events.output = StringIO.new
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
    Rails::Container::Events.reset!
    Rails.application.config.x.container = @orig_config
  end

  # Platform ---------------------------------------------------------------

  test "platform is :kubernetes when KUBERNETES_SERVICE_HOST is present" do
    ENV["KUBERNETES_SERVICE_HOST"] = "10.0.0.1"
    assert_equal :kubernetes, Rails::Container.platform
  end

  test "platform defaults to :local and honors CONTAINER_PLATFORM" do
    assert_equal :local, Rails::Container.platform
    ENV["CONTAINER_PLATFORM"] = "compose"
    assert_equal :compose, Rails::Container.platform
  end

  # Check registry / diagnostics ------------------------------------------

  test "register_check requires a block" do
    assert_raises(ArgumentError) { Rails::Container.register_check(:x) }
  end

  test "diagnostics reports problems and honors ignore/enabled" do
    Rails::Container.register_check(:a) { "problem a" }
    Rails::Container.register_check(:b) { nil }
    assert_equal [:a], Rails::Container.diagnostics.map { |d| d[:name] }

    Rails.application.config.x.container = { diagnostics: { ignore: [:a] } }
    assert_empty Rails::Container.diagnostics

    Rails.application.config.x.container = { diagnostics: { enabled: false } }
    Rails::Container.register_check(:c) { "still a problem" }
    assert_empty Rails::Container.diagnostics
  end

  test "emit_diagnostics logs each problem at its severity" do
    Rails::Container.register_check(:a, severity: :warn) { "warn problem" }
    Rails::Container.register_check(:b, severity: :info) { "info problem" }
    logger = Struct.new(:warns, :infos) do
      def warn(m) = warns << m
      def info(m) = infos << m
    end.new([], [])

    Rails::Container.emit_diagnostics(logger)

    assert(logger.warns.any? { |m| m.include?("warn problem") })
    assert(logger.infos.any? { |m| m.include?("info problem") })
  end

  # Init Container ---------------------------------------------------------

  test "init_step requires a block and runs steps once, in order, fail-fast" do
    assert_raises(ArgumentError) { Rails::Container.init_step(:x) }

    order = []
    Rails::Container.init_step(:a) { order << :a }
    Rails::Container.init_step(:b) { order << :b }
    Rails::Container.run_init!
    Rails::Container.run_init!
    assert_equal [:a, :b], order
  end

  # The evidence a verification script waits for before sending traffic.
  test "run_init! records each step and the completion as events" do
    Rails::Container.init_step(:db_migrate) { :ok }
    Rails::Container.init_step(:seed) { :ok }

    Rails::Container.run_init!

    assert_equal ["init.step name=db_migrate status=ok", "init.step name=seed status=ok",
                  "init.done steps=2"],
      event_summaries
  end

  test "a failing step is recorded as an error and no completion event follows" do
    Rails::Container.init_step(:boom) { raise "fail" }

    assert_raises(RuntimeError) { Rails::Container.run_init! }

    assert_equal ["init.step name=boom status=error"], event_summaries
  end

  test "run_init! re-raises and does not mark complete on failure" do
    Rails::Container.init_step(:boom) { raise "fail" }
    assert_raises(RuntimeError) { Rails::Container.run_init! }
    Rails::Container.reset_init
    ran = false
    Rails::Container.init_step(:ok) { ran = true }
    Rails::Container.run_init!
    assert ran
  end

  # Boot summary -----------------------------------------------------------

  test "boot_summary records the resolved state of every pattern" do
    ENV["CONTAINER_PLATFORM"] = "kubernetes"
    ENV["POD_NAME"] = "web-abc"
    Rails::Container::Privilege.syscalls = FakeSyscalls.new(start_uid: 991)
    Rails::Container.init_step(:db_migrate) { :ok }
    Rails::Container::GracefulShutdown.on_shutdown { :ok }

    summary = Rails::Container.boot_summary

    assert_equal :kubernetes, summary[:platform]
    assert_equal 991, summary[:uid]
    assert_equal "injected", summary[:identity]
    assert_equal 1, summary[:hooks]
    assert_equal 1, summary[:init_steps]
    assert_equal "/container/health/live", summary[:liveness]
  end

  # Off Kubernetes the identity is reported absent rather than omitted, so a log
  # reader can tell "no Downward API here" from "the line was never emitted".
  test "boot_summary reports the identity as absent off kubernetes" do
    ENV["CONTAINER_PLATFORM"] = "compose"
    ENV["POD_NAME"] = "web-abc"

    assert_equal "absent", Rails::Container.boot_summary[:identity]
  end

  test "emit_boot_summary writes one line carrying the resolved state" do
    ENV["CONTAINER_PLATFORM"] = "local"

    line = Rails::Container.emit_boot_summary

    assert_includes line, "#{Rails::Container::Events::PREFIX}boot "
    assert_includes line, "platform=local"
    assert_includes line, "identity=absent"
  end

  # Self Awareness ---------------------------------------------------------

  test "self_info reads Downward API env on Kubernetes, nil off Kubernetes" do
    ENV["POD_NAME"] = "web-abc"
    ENV["POD_NAMESPACE"] = "prod"

    # Off Kubernetes the values are not surfaced.
    assert_nil Rails::Container.self_info.pod_name

    ENV["CONTAINER_PLATFORM"] = "kubernetes"
    info = Rails::Container.self_info
    assert_equal "web-abc", info.pod_name
    assert_equal "prod", info.namespace
  end

  # Built-in diagnostics ---------------------------------------------------

  test "managed_lifecycle_problem warns without shutdown hooks on any platform" do
    # A missing implementation is missing everywhere: the developer must hear
    # about it while still working locally, not only once on a cluster.
    %w[local compose kubernetes].each do |platform|
      ENV["CONTAINER_PLATFORM"] = platform
      Rails::Container::GracefulShutdown.reset!
      assert Rails::Container.managed_lifecycle_problem, "expected a warning on #{platform}"

      Rails::Container::GracefulShutdown.on_shutdown { }
      assert_nil Rails::Container.managed_lifecycle_problem, "expected silence once registered on #{platform}"
    end
  end

  test "self_awareness_problem warns on kubernetes until all identity vars are injected" do
    ENV["CONTAINER_PLATFORM"] = "kubernetes"
    assert Rails::Container.self_awareness_problem

    ENV["POD_NAME"] = "web-abc"
    assert Rails::Container.self_awareness_problem, "partial injection should still warn"

    ENV["POD_NAMESPACE"] = "prod"
    ENV["NODE_NAME"] = "node-1"
    assert_nil Rails::Container.self_awareness_problem
  end

  test "process_containment_problem warns while running as root on any platform" do
    # Running as root is a property of the image, not of the orchestrator, and
    # Docker development is exactly where it stays invisible otherwise.
    %w[local compose kubernetes].each do |platform|
      ENV["CONTAINER_PLATFORM"] = platform

      Rails::Container::Privilege.syscalls = FakeSyscalls.new(start_uid: 0)
      assert Rails::Container.process_containment_problem, "expected a warning on #{platform}"

      Rails::Container::Privilege.syscalls = FakeSyscalls.new(start_uid: 1000)
      assert_nil Rails::Container.process_containment_problem, "expected silence as non-root on #{platform}"
    end
  end

  test "self_awareness_problem stays silent off kubernetes (platform supplies the value)" do
    # The exception to the rule: Docker has no Downward API to inject, so asking
    # for POD_NAME there would be noise rather than a surfaced requirement.
    ENV["CONTAINER_PLATFORM"] = "local"
    assert_nil Rails::Container.self_awareness_problem
  end

  test "process_containment_problem warns when only the effective uid is root" do
    ENV["CONTAINER_PLATFORM"] = "kubernetes"
    Rails::Container::Privilege.syscalls = FakeSyscalls.new(start_uid: 1000, start_euid: 0)

    assert Rails::Container.process_containment_problem
  end

  private
    # The emitted lines minus what varies per run (prefix, pid, duration).
    def event_summaries
      Rails::Container::Events.recorded.map do |line|
        line.sub(Rails::Container::Events::PREFIX, "")
            .sub(" pid=#{Process.pid}", "")
            .sub(/ duration_ms=\d+/, "")
      end
    end
end
