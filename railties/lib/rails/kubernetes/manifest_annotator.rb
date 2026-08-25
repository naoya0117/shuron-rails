# frozen_string_literal: true

require "yaml"

module Rails
  module Kubernetes
    module ManifestAnnotator
      COMMENTS = {
        "terminationGracePeriodSeconds" => "shuron-rails Kubernetes layer (Graceful Shutdown)",
        "resources"                     => "shuron-rails Kubernetes layer (Predictable Demands)",
        "livenessProbe"                 => "shuron-rails Kubernetes layer (Health Probe)",
        "readinessProbe"                => "shuron-rails Kubernetes layer (Health Probe)",
        "lifecycle"                     => "shuron-rails Kubernetes layer (Graceful Shutdown - injected after kompose)",
        "securityContext"               => "shuron-rails Kubernetes layer (Process Containment - injected after kompose)",
        "initContainers"                => "shuron-rails Kubernetes layer (Init Container - injected after kompose)",
        "httpHeaders"                   => "shuron-rails Kubernetes layer (Health Probe - force_ssl / host authorization)"
      }.freeze

      # Name of the generated init container.
      INIT_CONTAINER_NAME = "container-init"

      module_function

      # Reads the manifest at `path` and injects what kompose cannot express:
      # a preStop hook, a securityContext, the probe headers the endpoints need
      # to answer truthfully, and an initContainers entry for the declared init
      # steps. Then inserts comments above the framework-added sections and
      # writes the file back.
      #
      # Each argument is opt-in by absence: +security+ nil leaves securityContext
      # untouched (kompose carries none, so absence means "don't add"),
      # +probe_headers+ empty adds no headers, +init_command+ nil adds no init
      # container.
      def annotate!(path, pre_stop_delay:, security: nil, probe_headers: nil, init_command: nil)
        manifest = YAML.load_file(path)
        inject_pre_stop(manifest, pre_stop_delay)
        inject_security_context(manifest, security) if security
        inject_probe_headers(manifest, probe_headers)
        inject_init_container(manifest, command: init_command) if init_command
        annotated = insert_comments(YAML.dump(manifest))
        File.write(path, annotated)
      end

      def inject_pre_stop(manifest, delay)
        container = manifest.dig("spec", "template", "spec", "containers", 0)
        return unless container

        seconds = delay.to_s.sub(/s\z/, "")
        container["lifecycle"] ||= {}
        container["lifecycle"]["preStop"] = {
          "exec" => { "command" => ["sleep", seconds] }
        }
      end

      # Process Containment: fills the first container's securityContext with
      # the resolved secure defaults (runAsNonRoot / no privilege escalation /
      # drop all capabilities; readOnlyRootFilesystem and runAsUser only when
      # set). Never overwrites a value the user already placed in the manifest,
      # and skips entirely when +enabled: false+. Capabilities, runAsNonRoot and
      # no-privilege-escalation are enforced here -- by the kubelet, before the
      # process starts -- which is strictly stronger than dropping in-process.
      def inject_security_context(manifest, security)
        security = symbolize(security)
        return if security[:enabled] == false

        container = manifest.dig("spec", "template", "spec", "containers", 0)
        return unless container

        sc = (container["securityContext"] ||= {})
        put = lambda do |key, value|
          sc[key] = value unless value.nil? || sc.key?(key)
        end

        put.call("runAsNonRoot", security[:run_as_non_root])
        put.call("allowPrivilegeEscalation", security[:allow_privilege_escalation])
        put.call("readOnlyRootFilesystem", security[:read_only_root_filesystem])
        put.call("runAsUser", security[:run_as_user])

        caps = security[:drop_capabilities]
        sc["capabilities"] = { "drop" => Array(caps) } if caps && !sc.key?("capabilities")

        # The Restricted Pod Security Standard demands a seccompProfile as well,
        # and without it admission refuses the Pod outright -- measured:
        # "seccompProfile (pod or container must set ... to RuntimeDefault or
        # Localhost)". Leaving it out meant the generated manifest could not be
        # applied to a restricted namespace at all, so it belongs with the other
        # secure defaults rather than being left to whoever writes the manifest.
        profile = security[:seccomp_profile]
        sc["seccompProfile"] = { "type" => profile } if profile && !sc.key?("seccompProfile")
      end

      # Health Probe: adds the headers the endpoints need to answer truthfully.
      #
      # Without them the probe is worse than absent, because it passes while
      # proving nothing: an app with force_ssl answers a plain-HTTP probe with a
      # 301, the kubelet counts any 3xx as success, and the readiness check --
      # including its database round-trip -- never runs once. Measured on two of
      # the three applied apps. Host authorization is the same shape: without a
      # permitted Host the endpoint answers 403, which at least fails visibly.
      #
      # The values are derived, not declared: +https+ when the app sets
      # force_ssl, and the first permitted entry of config.hosts. That is the
      # same derivation Rails::Container::Conformance already uses for its
      # in-process request, which is why Layer 1 never saw the false green that
      # the generated manifest did.
      def inject_probe_headers(manifest, headers)
        return if headers.nil? || headers.empty?

        container = manifest.dig("spec", "template", "spec", "containers", 0)
        return unless container

        %w[livenessProbe readinessProbe startupProbe].each do |probe_key|
          http_get = container.dig(probe_key, "httpGet")
          next unless http_get
          next if http_get.key?("httpHeaders")

          http_get["httpHeaders"] = headers.map { |name, value| { "name" => name, "value" => value } }
        end
      end

      # Init Container: runs the declared init steps in their own container,
      # before the app containers start.
      #
      # kompose can emit an initContainers entry from labels, but the entry it
      # produces carries only name/image/command -- no env, envFrom,
      # volumeMounts, resources or securityContext -- so the container cannot
      # even see the configuration it needs. Writing the whole entry here is both
      # simpler and the only way to get a working one.
      #
      # Every field is copied from the app container, and +resources+ especially:
      # an init container without resource limits makes the *Pod's* effective
      # limit for that resource unbounded, which silently voids the memory limit
      # the Predictable Demands declaration asked for.
      def inject_init_container(manifest, command:)
        spec = manifest.dig("spec", "template", "spec")
        container = spec && spec.dig("containers", 0)
        return unless container

        init = spec["initContainers"] ||= []
        return if init.any? { |c| c["name"] == INIT_CONTAINER_NAME }

        entry = {
          "name"            => INIT_CONTAINER_NAME,
          "image"           => container["image"],
          "imagePullPolicy" => container["imagePullPolicy"],
          "command"         => command
        }.compact

        # The Downward API vars live in env, so copying it is what keeps the
        # init container from emitting a self_awareness diagnostic of its own.
        #
        # Deep-copied on purpose: sharing the object with the app container makes
        # Psych emit a YAML alias, which turns a generated manifest into
        # something a human cannot read and Psych itself refuses to load back.
        %w[env envFrom resources securityContext volumeMounts].each do |key|
          value = container[key]
          entry[key] = Marshal.load(Marshal.dump(value)) if value
        end

        init.unshift(entry)
      end

      def symbolize(hash)
        hash.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end

      def insert_comments(yaml_string)
        keys_regex = COMMENTS.keys.join("|")
        out = []
        yaml_string.each_line do |line|
          if (m = line.match(/\A(\s*)(#{keys_regex}):/))
            indent = m[1]
            key    = m[2]
            out << "#{indent}# #{COMMENTS[key]}\n"
          end
          out << line
        end
        out.join
      end
    end
  end
end
