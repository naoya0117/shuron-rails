# frozen_string_literal: true

namespace :kubernetes do
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
    generate_kubernetes_override(override_file)

    begin
      sh "kompose convert -f docker-compose.yml -f #{override_file}"
    ensure
      FileUtils.rm_f(override_file)
    end
  end

  private

  def generate_kubernetes_override(path)
    k8s = Rails.application.config.x.kubernetes || {}

    liveness  = k8s[:liveness] || k8s["liveness"] || {}
    readiness = k8s[:readiness] || k8s["readiness"] || {}
    endpoints = k8s[:endpoints] || k8s["endpoints"] || {}

    liveness_path  = liveness[:path]  || liveness["path"]  || endpoints[:liveness_path]  || endpoints["liveness_path"]  || "/kubernetes/health/live"
    readiness_path = readiness[:path] || readiness["path"] || endpoints[:readiness_path] || endpoints["readiness_path"] || "/kubernetes/health/ready"

    require "yaml"

    override = {
      "services" => {
        "web" => {
          "labels" => {
            "kompose.controller.type"                         => "Deployment",
            "kompose.service.type"                            => "ClusterIP",
            "kompose.pod.liveness-probe.http-get.path"        => liveness_path,
            "kompose.pod.liveness-probe.http-get.port"        => "3000",
            "kompose.pod.liveness-probe.initial-delay-seconds" => "10",
            "kompose.pod.liveness-probe.period-seconds"       => "10",
            "kompose.pod.readiness-probe.http-get.path"       => readiness_path,
            "kompose.pod.readiness-probe.http-get.port"       => "3000",
            "kompose.pod.readiness-probe.initial-delay-seconds" => "5",
            "kompose.pod.readiness-probe.period-seconds"      => "5"
          }
        }
      }
    }

    File.write(path, YAML.dump(override))
    puts "Generated #{path} from config/kubernetes.rb"
  end
end
