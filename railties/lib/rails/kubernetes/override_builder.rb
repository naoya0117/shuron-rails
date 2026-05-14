# frozen_string_literal: true

module Rails
  module Kubernetes
    module OverrideBuilder
      module_function

      # config/kubernetes.rb の resources: ハッシュを受け取り、
      # Docker Compose の deploy.resources 構造を返す。
      # CPU limits は Burstable QoS のため生成しない。
      # memory.limit 省略時は request と同値にして Guaranteed QoS を維持する。
      def build_resource_deploy(resources_config)
        return nil if resources_config.nil?

        res      = resources_config.transform_keys(&:to_sym)
        cpu      = res[:cpu]    ? res[:cpu].transform_keys(&:to_sym)    : nil
        memory   = res[:memory] ? res[:memory].transform_keys(&:to_sym) : nil

        return nil if cpu.nil? && memory.nil?

        reservations = {}
        limits       = {}

        if cpu
          reservations["cpus"] = millicores_to_decimal(cpu[:request]) if cpu[:request]
        end

        if memory
          reservations["memory"] = to_docker_memory(memory[:request]) if memory[:request]
          mem_limit = memory[:limit] || memory[:request]
          limits["memory"] = to_docker_memory(mem_limit) if mem_limit
        end

        deploy = {}
        deploy["reservations"] = reservations unless reservations.empty?
        deploy["limits"]       = limits       unless limits.empty?

        deploy.empty? ? nil : { "resources" => deploy }
      end

      def millicores_to_decimal(value)
        return nil if value.nil?
        str = value.to_s
        unless str.match?(/\A\d+(\.\d+)?m?\z/)
          raise ArgumentError, "Invalid CPU value: #{str.inspect}. Expected format: '100m' or '1'"
        end
        raw = str.end_with?("m") ? str.to_f / 1000 : str.to_f
        format("%g", raw)
      end

      def to_docker_memory(value)
        return nil if value.nil?
        str = value.to_s
        unless str.match?(/\A\d+(\.\d+)?(Mi|Gi|M|G)?\z/)
          raise ArgumentError, "Invalid memory value: #{str.inspect}. Expected format: '256Mi', '1Gi', or '256M'"
        end
        str.sub("Mi", "M").sub("Gi", "G")
      end
    end
  end
end
