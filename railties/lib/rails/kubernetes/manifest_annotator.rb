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
        "securityContext"               => "shuron-rails Kubernetes layer (Process Containment - injected after kompose)"
      }.freeze

      module_function

      # Reads the manifest at `path`, injects a preStop hook and (when +security+
      # is given) a securityContext into the first container, inserts comments
      # above framework-added sections, and writes the file back. +security+ is
      # the resolved Process Containment settings; +nil+ leaves securityContext
      # untouched (kompose carries none, so absence means "don't add").
      def annotate!(path, pre_stop_delay:, security: nil)
        manifest = YAML.load_file(path)
        inject_pre_stop(manifest, pre_stop_delay)
        inject_security_context(manifest, security) if security
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
