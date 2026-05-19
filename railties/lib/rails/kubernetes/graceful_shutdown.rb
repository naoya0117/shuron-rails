# frozen_string_literal: true

module Rails
  module Kubernetes
    module GracefulShutdown
      class << self
        def on_shutdown(&block)
          hooks << block
        end

        # Replaces the SIGTERM trap to run registered hooks first,
        # then delegates to whatever handler was installed previously
        # (typically Puma's, which performs graceful drain).
        def install!
          previous = Signal.trap("TERM") {}
          Signal.trap("TERM") do
            run_hooks
            previous.call if previous.is_a?(Proc)
          end
        end

        def hooks
          @hooks ||= []
        end

        def run_hooks
          hooks.each do |hook|
            begin
              hook.call
            rescue => e
              warn "[GracefulShutdown] #{e.class}: #{e.message}"
            end
          end
        end

        # Test helper. Clears all registered hooks.
        def reset!
          @hooks = []
        end
      end
    end
  end
end
