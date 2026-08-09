# frozen_string_literal: true

require "abstract_unit"
require "minitest/mock"
require "rails/container"

class Rails::ContainerPrivilegeTest < ActiveSupport::TestCase
  # Fake syscalls that start privileged and record the drop, so the verification
  # inside drop_to sees the ids it asked for.
  class FakeSyscalls
    attr_reader :initgroups_args

    def initialize(uid: 0, gid: 0)
      @uid = uid
      @gid = gid
    end

    def uid = @uid
    def euid = @uid
    def gid = @gid
    def egid = @gid
    def initgroups(user, gid) = @initgroups_args = [user, gid]
    def setgid(gid) = @gid = gid
    def setuid(uid) = @uid = uid
  end

  # Syscalls that accept the calls but never actually change ids, so drop_to's
  # verification must fail closed.
  class IneffectiveSyscalls < FakeSyscalls
    def setgid(_gid) = nil
    def setuid(_uid) = nil
  end

  Pwent = Struct.new(:name, :uid, :gid)

  setup do
    @orig_config = Rails.application.config.x.container
    Rails::Container::Privilege.syscalls = FakeSyscalls.new
  end

  teardown do
    Rails.application.config.x.container = @orig_config
    Rails::Container::Privilege.reset!
  end

  # --- drop_to ------------------------------------------------------------

  test "drop_to resolves a user name and drops both real and effective ids" do
    pwent = Pwent.new("app", 2000, 2000)
    Etc.stub(:getpwnam, pwent) do
      result = Rails::Container::Privilege.drop_to(user: "app")

      assert_equal :dropped, result.status
      assert_equal 2000, result.uid
      assert_equal 2000, result.gid
      # Supplementary groups are set before the uid, while still privileged.
      assert_equal ["app", 2000], Rails::Container::Privilege.syscalls.initgroups_args
    end
  end

  test "drop_to accepts a numeric uid, resolving the name initgroups needs" do
    pwent = Pwent.new("app", 1000, 65533)
    Etc.stub(:getpwuid, pwent) do
      result = Rails::Container::Privilege.drop_to(user: 1000)

      assert_equal :dropped, result.status
      assert_equal 1000, result.uid
      assert_equal 65533, result.gid
      assert_equal ["app", 65533], Rails::Container::Privilege.syscalls.initgroups_args
    end
  end

  test "drop_to is a noop when the process is already unprivileged" do
    Rails::Container::Privilege.syscalls = FakeSyscalls.new(uid: 2000, gid: 2000)
    Etc.stub(:getpwnam, Pwent.new("app", 2000, 2000)) do
      assert_equal :noop, Rails::Container::Privilege.drop_to(user: "app").status
    end
  end

  test "drop_to refuses a privileged target" do
    Etc.stub(:getpwnam, Pwent.new("root", 0, 0)) do
      assert_raises(ArgumentError) { Rails::Container::Privilege.drop_to(user: "root") }
    end
  end

  test "drop_to fails closed when the ids did not actually change" do
    Rails::Container::Privilege.syscalls = IneffectiveSyscalls.new
    Etc.stub(:getpwnam, Pwent.new("app", 2000, 2000)) do
      assert_raises(Rails::Container::Privilege::DropError) do
        Rails::Container::Privilege.drop_to(user: "app")
      end
    end
  end

  # --- contain_process! (declarative) -------------------------------------

  test "contain_process! does nothing when drop_privileges is not declared" do
    Rails.application.config.x.container = { process_containment: { run_as_user: 2000 } }
    assert_nil Rails::Container.contain_process!
  end

  test "contain_process! does nothing when the process is not root" do
    Rails.application.config.x.container = {
      process_containment: { run_as_user: 2000, drop_privileges: true }
    }
    # Already unprivileged by both measures: attempting the handover or
    # initgroups here would raise EPERM, so the layer must stay out.
    Rails::Container::Privilege.syscalls = FakeSyscalls.new(uid: 2000, gid: 2000)
    assert_nil Rails::Container.contain_process!
  end

  test "contain_process! still drops when only the effective uid is root" do
    Rails.application.config.x.container = {
      process_containment: { run_as_user: 2000, drop_privileges: true }
    }
    Etc.stub(:getpwuid, Pwent.new("app", 2000, 2000)) do
      assert_equal :dropped, Rails::Container.contain_process!.status
    end
  end

  test "contain_process! drops to run_as_user when drop_privileges is true" do
    Rails.application.config.x.container = {
      process_containment: { run_as_user: 2000, drop_privileges: true }
    }
    pwent = Pwent.new("app", 2000, 2000)
    Etc.stub(:getpwuid, pwent) do
      result = Rails::Container.contain_process!

      assert_equal :dropped, result.status
      assert_equal 2000, result.uid
    end
  end

  test "contain_process! accepts an explicit user in drop_privileges" do
    Rails.application.config.x.container = {
      process_containment: { drop_privileges: "app" }
    }
    pwent = Pwent.new("app", 2000, 2000)
    Etc.stub(:getpwnam, pwent) do
      Etc.stub(:getpwuid, pwent) do
        assert_equal :dropped, Rails::Container.contain_process!.status
      end
    end
  end

  test "contain_process! requires a target when drop_privileges is true" do
    Rails.application.config.x.container = { process_containment: { drop_privileges: true } }
    assert_raises(ArgumentError) { Rails::Container.contain_process! }
  end

  test "contain_process! hands declared paths to the target before dropping" do
    Rails.application.config.x.container = {
      process_containment: { run_as_user: 2000, drop_privileges: true, ensure_writable: ["log"] }
    }
    pwent = Pwent.new("app", 2000, 2000)
    chowned = []
    Etc.stub(:getpwuid, pwent) do
      FileUtils.stub(:mkdir_p, nil) do
        # Root-owned path: the layer must hand it over before privileges go.
        File.stub(:stat, Struct.new(:uid).new(0)) do
          FileUtils.stub(:chown_R, ->(uid, gid, path) { chowned << [uid, gid, path.to_s] }) do
            assert_equal :dropped, Rails::Container.contain_process!.status
          end
        end
      end
    end

    assert_equal 1, chowned.size
    uid, gid, path = chowned.first
    assert_equal [2000, 2000], [uid, gid]
    assert_includes path, "log"
  end

  test "contain_process! leaves paths already owned by the target alone" do
    Rails.application.config.x.container = {
      process_containment: { run_as_user: 2000, drop_privileges: true, ensure_writable: ["log"] }
    }
    pwent = Pwent.new("app", 2000, 2000)
    Etc.stub(:getpwuid, pwent) do
      FileUtils.stub(:mkdir_p, nil) do
        File.stub(:stat, Struct.new(:uid).new(2000)) do
          FileUtils.stub(:chown_R, ->(*) { flunk "should not chown an already-owned path" }) do
            assert_equal :dropped, Rails::Container.contain_process!.status
          end
        end
      end
    end
  end

  test "contain_process! tolerates string keys (as kubernetes:convert writes)" do
    Rails.application.config.x.container = {
      process_containment: { "run_as_user" => 2000, "drop_privileges" => true }
    }
    pwent = Pwent.new("app", 2000, 2000)
    Etc.stub(:getpwuid, pwent) do
      assert_equal :dropped, Rails::Container.contain_process!.status
    end
  end
end
