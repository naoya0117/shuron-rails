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
        "lifecycle"                     => "shuron-rails Kubernetes layer (Graceful Shutdown - injected after kompose)"
      }.freeze

      module_function

      # Reads the manifest at `path`, injects a preStop hook into the first
      # container, inserts comments above framework-added sections, and writes
      # the file back.
      def annotate!(path, pre_stop_delay:)
        manifest = YAML.load_file(path)
        inject_pre_stop(manifest, pre_stop_delay)
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
