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
