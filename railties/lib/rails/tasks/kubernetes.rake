# frozen_string_literal: true

require "rails/kubernetes/override_builder"
require "rails/container/config_loader"
require "rails/kubernetes/manifest_annotator"

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
    output_dir    = "k8s"

    FileUtils.rm_f(override_file) if File.exist?(override_file)
    generate_kubernetes_override(override_file)

    FileUtils.mkdir_p(output_dir)
    sh "kompose convert -f docker-compose.yml -f #{override_file} -o #{output_dir}"

    annotate_manifests(output_dir)
  end

  def generate_kubernetes_override(path)
    Rails::Container::ConfigLoader.load!
    settings = Rails.application.config.x.container || {}

    liveness  = settings[:liveness]  || settings["liveness"]  || {}
    readiness = settings[:readiness] || settings["readiness"] || {}
    resources = settings[:resources] || settings["resources"]
    graceful  = settings[:graceful_shutdown] || settings["graceful_shutdown"] || {}

    liveness_path  = liveness[:path]  || liveness["path"]  || "/container/health/live"
    readiness_path = readiness[:path] || readiness["path"] || "/container/health/ready"
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
    puts "Generated #{path} from config/container.rb"
  end

  def annotate_manifests(output_dir)
    Rails::Container::ConfigLoader.load!
    settings = Rails.application.config.x.container || {}
    graceful = settings[:graceful_shutdown] || settings["graceful_shutdown"] || {}
    pre_stop_delay = graceful[:pre_stop_delay] || graceful["pre_stop_delay"] || "15s"
    security = resolve_process_containment(settings)
    probe_headers = resolve_probe_headers
    init_command = Rails::Container.init_steps.any? ? resolve_init_command : nil

    Dir.glob(File.join(output_dir, "*-deployment.yaml")).each do |path|
      Rails::Kubernetes::ManifestAnnotator.annotate!(
        path,
        pre_stop_delay: pre_stop_delay,
        security: security,
        probe_headers: probe_headers,
        init_command: init_command
      )
      puts "Annotated #{path}"
    end
  end

  # Headers the generated probes need in order to reach the health action.
  #
  # Derived from the app rather than declared, and deliberately the same
  # derivation Rails::Container::Conformance uses for its in-process request --
  # otherwise Layer 1 and the manifest disagree about what a healthy probe looks
  # like, which is exactly what happened: conformance was fixed in 2026-07 while
  # the manifests kept producing probes that passed on a 301.
  def resolve_probe_headers
    headers = {}
    headers["X-Forwarded-Proto"] = "https" if Rails.application.config.force_ssl
    host = permitted_host
    headers["Host"] = host if host
    headers
  end

  # The first entry of config.hosts that is a concrete hostname. A leading dot
  # is a domain suffix matcher, not a usable Host value.
  def permitted_host
    hosts = begin
      Rails.application.config.hosts
    rescue StandardError
      nil
    end
    Array(hosts).find { |h| h.is_a?(String) && !h.empty? && !h.start_with?(".") }
  end

  # Command for the generated init container. `bin/rails` is the Rails
  # convention and is what the applied apps use; override with
  # `init_container: { command: [...] }` for an image whose layout differs.
  def resolve_init_command
    settings = Rails.application.config.x.container || {}
    ic = settings[:init_container] || settings["init_container"] || {}
    ic = ic.transform_keys(&:to_sym) if ic.respond_to?(:transform_keys)
    Array(ic[:command]).presence || ["bin/rails", "container:init"]
  end

  # Resolves the Process Containment securityContext to inject. Secure by
  # default (never root, no privilege escalation, drop all capabilities);
  # readOnlyRootFilesystem and runAsUser stay unset unless configured, and the
  # whole block can be turned off with `process_containment: { enabled: false }`.
  def resolve_process_containment(settings)
    pc = settings[:process_containment] || settings["process_containment"] || {}
    pc = pc.transform_keys(&:to_sym)
    return { enabled: false } if pc[:enabled] == false

    {
      run_as_non_root:            pc.fetch(:run_as_non_root, true),
      allow_privilege_escalation: pc.fetch(:allow_privilege_escalation, false),
      drop_capabilities:          pc.fetch(:drop_capabilities, ["ALL"]),
      read_only_root_filesystem:  pc[:read_only_root_filesystem],
      run_as_user:                pc[:run_as_user],
      # Restricted PSS refuses a Pod without this, so it is a secure default
      # rather than an option; `seccomp_profile: nil` opts out.
      seccomp_profile:            pc.fetch(:seccomp_profile, "RuntimeDefault")
    }
  end
end
