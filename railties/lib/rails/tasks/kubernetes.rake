# frozen_string_literal: true

require "rails/kubernetes/override_builder"
require "rails/kubernetes/config_loader"
require "rails/kubernetes/manifest_annotator"

namespace :kubernetes do
  desc "Run registered Kubernetes-layer initialization steps (Init Container)"
  task init: :environment do
    require "rails/kubernetes"
    Rails::Kubernetes.run_init!
  end

  desc "Report Kubernetes-layer diagnostics (use KC_PLATFORM=kubernetes to preflight)"
  task doctor: :environment do
    require "rails/kubernetes"
    diagnostics = Rails::Kubernetes.diagnostics

    if diagnostics.empty?
      puts "[kubernetes] no diagnostics."
    else
      diagnostics.each do |d|
        puts "[#{d[:severity]}] #{d[:name]}: #{d[:message]}"
      end
    end
  end

  desc "Convert docker-compose.yml to Kubernetes manifests using Kompose"
  task convert: :environment do
    unless system("which kompose > /dev/null 2>&1")
      abort <<~MSG
        Kompose is required to convert Docker Compose files to Kubernetes manifests.

        Install Kompose:
          macOS:  brew install kompose
          Linux:  curl -L https://github.com/kubernetes/kompose/releases/latest/download/kompose-linux-amd64 -o /usr/local/bin/kompose && chmod +x /usr/local/bin/kompose
          Windows: choco install kubernetes-kompose

        See https://kompose.io/installation/ for details.
      MSG
    end

    override_file = "docker-compose.kubernetes-override.yml"
    output_dir    = "k8s"

    FileUtils.rm_f(override_file) if File.exist?(override_file)
    generate_kubernetes_override(override_file)

    FileUtils.mkdir_p(output_dir)
    sh "kompose convert -f docker-compose.yml -f #{override_file} -o #{output_dir}"

    annotate_manifests(output_dir)
  end

  def generate_kubernetes_override(path)
    Rails::Kubernetes::ConfigLoader.load!
    k8s = Rails.application.config.x.kubernetes || {}

    liveness  = k8s[:liveness]  || k8s["liveness"]  || {}
    readiness = k8s[:readiness] || k8s["readiness"] || {}
    resources = k8s[:resources] || k8s["resources"]
    graceful  = k8s[:graceful_shutdown] || k8s["graceful_shutdown"] || {}

    liveness_path  = liveness[:path]  || liveness["path"]  || "/kubernetes/health/live"
    readiness_path = readiness[:path] || readiness["path"] || "/kubernetes/health/ready"
    grace_period   = graceful[:grace_period] || graceful["grace_period"]
    port           = ENV.fetch("PORT", 3000).to_i

    require "yaml"

    # The healthcheck block (without `test`) is required so Kompose's
    # parseHealthCheck() is invoked; only then do liveness labels apply.
    # Liveness timing parameters come from this block; readiness timing
    # comes from its own labels below.
    web_service = {
      "labels" => {
        "kompose.controller.type"                                => "deployment",
        "kompose.service.type"                                   => "ClusterIP",
        "kompose.service.healthcheck.liveness.http_get_path"     => liveness_path,
        "kompose.service.healthcheck.liveness.http_get_port"     => port,
        "kompose.service.healthcheck.readiness.http_get_path"    => readiness_path,
        "kompose.service.healthcheck.readiness.http_get_port"    => port,
        "kompose.service.healthcheck.readiness.interval"         => "5s",
        "kompose.service.healthcheck.readiness.timeout"          => "3s",
        "kompose.service.healthcheck.readiness.retries"          => 3,
        "kompose.service.healthcheck.readiness.start_period"     => "5s"
      },
      "healthcheck" => {
        "interval"     => "10s",
        "timeout"      => "5s",
        "retries"      => 3,
        "start_period" => "10s"
      }
    }

    web_service["stop_grace_period"] = grace_period if grace_period

    resource_deploy = Rails::Kubernetes::OverrideBuilder.build_resource_deploy(resources)
    web_service["deploy"] = resource_deploy if resource_deploy

    override = { "services" => { "web" => web_service } }

    File.write(path, YAML.dump(override))
    puts "Generated #{path} from config/kubernetes.rb"
  end

  def annotate_manifests(output_dir)
    Rails::Kubernetes::ConfigLoader.load!
    k8s = Rails.application.config.x.kubernetes || {}
    graceful = k8s[:graceful_shutdown] || k8s["graceful_shutdown"] || {}
    pre_stop_delay = graceful[:pre_stop_delay] || graceful["pre_stop_delay"] || "15s"

    Dir.glob(File.join(output_dir, "*-deployment.yaml")).each do |path|
      Rails::Kubernetes::ManifestAnnotator.annotate!(path, pre_stop_delay: pre_stop_delay)
      puts "Annotated #{path}"
    end
  end
end
