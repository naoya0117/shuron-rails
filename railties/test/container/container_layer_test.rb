# frozen_string_literal: true

require "abstract_unit"
require "etc"
require "rails/container"

class Rails::ContainerLayerTest < ActiveSupport::TestCase
  PLATFORM_ENV = %w[CONTAINER_PLATFORM KUBERNETES_SERVICE_HOST POD_NAME POD_NAMESPACE NODE_NAME POD_IP POD_SERVICE_ACCOUNT].freeze

  # Stand-in for the OS privilege syscalls so a non-root test runner can model
  # "currently root" and observe the drop without actually changing the process.
  class FakeSyscalls
    attr_reader :calls
    attr_accessor :ignore_setuid

    def initialize(start_uid:, start_euid: nil)
      @uid = start_uid
      @euid = start_euid.nil? ? start_uid : start_euid
      @gid = start_uid
      @egid = start_uid
      @calls = []
      @ignore_setuid = false
    end

    def uid = @uid
    def euid = @euid
    def gid = @gid
    def egid = @egid
    def initgroups(user, gid) = @calls << [:initgroups, user, gid]
    def setgid(gid) = (@calls << [:setgid, gid]; @gid = @egid = gid)
    def setuid(uid) = (@calls << [:setuid, uid]; @uid = @euid = uid unless @ignore_setuid)
  end

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

  test "run_init! re-raises and does not mark complete on failure" do
    Rails::Container.init_step(:boom) { raise "fail" }
    assert_raises(RuntimeError) { Rails::Container.run_init! }
    Rails::Container.reset_init
    ran = false
    Rails::Container.init_step(:ok) { ran = true }
    Rails::Container.run_init!
    assert ran
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

  test "managed_lifecycle_problem warns on kubernetes without shutdown hooks" do
    ENV["CONTAINER_PLATFORM"] = "kubernetes"
    assert Rails::Container.managed_lifecycle_problem
    Rails::Container::GracefulShutdown.on_shutdown { }
    assert_nil Rails::Container.managed_lifecycle_problem
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

  test "process_containment_problem warns on kubernetes only while running as root" do
    ENV["CONTAINER_PLATFORM"] = "kubernetes"

    Rails::Container::Privilege.syscalls = FakeSyscalls.new(start_uid: 0)
    assert Rails::Container.process_containment_problem

    Rails::Container::Privilege.syscalls = FakeSyscalls.new(start_uid: 1000)
    assert_nil Rails::Container.process_containment_problem
  end

  test "process_containment_problem stays silent off kubernetes even as root" do
    Rails::Container::Privilege.syscalls = FakeSyscalls.new(start_uid: 0)
    assert_nil Rails::Container.process_containment_problem # platform :local
  end

  # Process Containment: privilege drop ------------------------------------

  test "drop_to lowers gid before uid and reports the drop" do
    name = Etc.getpwuid(Process.uid).name
    fake = FakeSyscalls.new(start_uid: 0)
    Rails::Container::Privilege.syscalls = fake

    result = Rails::Container::Privilege.drop_to(user: name)

    assert_equal :dropped, result.status
    ops = fake.calls.map(&:first)
    assert_equal [:initgroups, :setgid, :setuid], ops,
      "supplementary groups and gid must drop before uid"
  end

  test "drop_to is a noop when the process is already unprivileged" do
    name = Etc.getpwuid(Process.uid).name
    fake = FakeSyscalls.new(start_uid: 1000)
    Rails::Container::Privilege.syscalls = fake

    result = Rails::Container::Privilege.drop_to(user: name)

    assert_equal :noop, result.status
    assert_empty fake.calls, "must not touch syscalls when there is nothing to drop"
  end

  test "drop_to raises for an unknown user (fails fast on misconfiguration)" do
    assert_raises(ArgumentError) do
      Rails::Container::Privilege.drop_to(user: "no_such_user_zzz_#{Process.pid}")
    end
  end

  test "drop_to fails closed when the drop does not take effect" do
    name = Etc.getpwuid(Process.uid).name
    fake = FakeSyscalls.new(start_uid: 0)
    fake.ignore_setuid = true
    Rails::Container::Privilege.syscalls = fake

    assert_raises(Rails::Container::Privilege::DropError) do
      Rails::Container::Privilege.drop_to(user: name)
    end
  end

  test "drop_to still drops when only the effective uid is root" do
    name = Etc.getpwuid(Process.uid).name
    # Real uid non-root but effective uid 0: still effectively root, not a noop.
    fake = FakeSyscalls.new(start_uid: 1000, start_euid: 0)
    Rails::Container::Privilege.syscalls = fake

    result = Rails::Container::Privilege.drop_to(user: name)

    assert_equal :dropped, result.status
    refute_empty fake.calls, "must drop while the effective uid is still root"
  end

  test "drop_to refuses a root target (would verify yet stay privileged)" do
    fake = FakeSyscalls.new(start_uid: 0)
    Rails::Container::Privilege.syscalls = fake

    assert_raises(ArgumentError) do
      Rails::Container::Privilege.drop_to(user: "root")
    end
    assert_empty fake.calls, "must not touch syscalls when refusing a root target"
  end

  test "process_containment_problem warns when only the effective uid is root" do
    ENV["CONTAINER_PLATFORM"] = "kubernetes"
    Rails::Container::Privilege.syscalls = FakeSyscalls.new(start_uid: 1000, start_euid: 0)

    assert Rails::Container.process_containment_problem
  end
end
