# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rails/kubernetes/override_builder"

class OverrideBuilderTest < Minitest::Test
  def test_full_config_generates_deploy_resources
    config = {
      cpu:    { request: "100m" },
      memory: { request: "256Mi", limit: "256Mi" }
    }
    result = Rails::Kubernetes::OverrideBuilder.build_resource_deploy(config)

    assert_equal "0.1",  result["resources"]["reservations"]["cpus"]
    assert_equal "256M", result["resources"]["reservations"]["memory"]
    assert_equal "256M", result["resources"]["limits"]["memory"]
  end

  def test_cpu_limit_is_never_generated
    config = {
      cpu:    { request: "100m", limit: "200m" },
      memory: { request: "256Mi", limit: "256Mi" }
    }
    result = Rails::Kubernetes::OverrideBuilder.build_resource_deploy(config)

    refute result["resources"]["limits"].key?("cpus"), "CPU limit should never appear"
  end

  def test_memory_limit_defaults_to_request_when_omitted
    config = {
      cpu:    { request: "100m" },
      memory: { request: "256Mi" }
    }
    result = Rails::Kubernetes::OverrideBuilder.build_resource_deploy(config)

    assert_equal "256M", result["resources"]["limits"]["memory"]
  end

  def test_nil_config_returns_nil
    assert_nil Rails::Kubernetes::OverrideBuilder.build_resource_deploy(nil)
  end

  def test_millicores_to_decimal
    assert_equal "0.1", Rails::Kubernetes::OverrideBuilder.millicores_to_decimal("100m")
    assert_equal "0.5", Rails::Kubernetes::OverrideBuilder.millicores_to_decimal("500m")
    assert_equal "1",   Rails::Kubernetes::OverrideBuilder.millicores_to_decimal("1000m")
    assert_equal "1",   Rails::Kubernetes::OverrideBuilder.millicores_to_decimal("1")
  end

  def test_to_docker_memory
    assert_equal "256M", Rails::Kubernetes::OverrideBuilder.to_docker_memory("256Mi")
    assert_equal "512M", Rails::Kubernetes::OverrideBuilder.to_docker_memory("512Mi")
    assert_equal "1G",   Rails::Kubernetes::OverrideBuilder.to_docker_memory("1Gi")
  end

  def test_invalid_cpu_value_raises_argument_error
    assert_raises(ArgumentError) do
      Rails::Kubernetes::OverrideBuilder.millicores_to_decimal("abc")
    end
  end

  def test_invalid_memory_value_raises_argument_error
    assert_raises(ArgumentError) do
      Rails::Kubernetes::OverrideBuilder.to_docker_memory("abc")
    end
  end
end
