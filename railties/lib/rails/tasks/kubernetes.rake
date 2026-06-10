# frozen_string_literal: true

namespace :kubernetes do
  desc "Run registered Kubernetes-layer initialization steps (Init Container)"
  task init: :environment do
    Rails::Kubernetes.run_init!
  end

  desc "Report Kubernetes-layer diagnostics (use KC_PLATFORM=kubernetes to preflight)"
  task doctor: :environment do
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
  end

  private

  def generate_kubernetes_override(path)
    k8s = Rails.application.config.x.kubernetes || {}

    liveness  = k8s[:liveness]  || k8s["liveness"]  || {}
    readiness = k8s[:readiness] || k8s["readiness"] || {}

    liveness_path  = liveness[:path]  || liveness["path"]  || "/kubernetes/health/live"
    readiness_path = readiness[:path] || readiness["path"] || "/kubernetes/health/ready"
    port           = ENV.fetch("PORT", 3000).to_s

    require "yaml"

    override = {
      "services" => {
        "web" => {
          "labels" => {
            "kompose.controller.type"                          => "deployment",
            "kompose.service.type"                             => "ClusterIP",
            "kompose.pod.liveness-probe.http-get.path"         => liveness_path,
            "kompose.pod.liveness-probe.http-get.port"         => port,
            "kompose.pod.liveness-probe.initial-delay-seconds" => "10",
            "kompose.pod.liveness-probe.period-seconds"        => "10",
            "kompose.pod.readiness-probe.http-get.path"        => readiness_path,
            "kompose.pod.readiness-probe.http-get.port"        => port,
            "kompose.pod.readiness-probe.initial-delay-seconds" => "5",
            "kompose.pod.readiness-probe.period-seconds"       => "5"
          }
        }
      }
    }

    File.write(path, YAML.dump(override))
    puts "Generated #{path} from config/kubernetes.rb"
  end
end
