# frozen_string_literal: true

module Rails
  module Container
    # Managed Lifecycle (terminal): runs application cleanup when the process
    # terminates. Hooks run once, in registration order.
    module GracefulShutdown
      class << self
        def on_shutdown(&block)
          raise ArgumentError, "on_shutdown requires a block" unless block

          hooks << block
        end

        # Runs the registered hooks on normal process exit. This covers SIGTERM
        # (whose default disposition runs at_exit) and the app server draining
        # and exiting. Running from at_exit -- rather than a signal trap --
        # avoids "can't be called from trap context" errors and never clobbers
        # the server's own TERM handling (which is installed after boot).
        def install!
          return if @installed

          @installed = true
          at_exit { run_hooks }
        end

        def hooks
          @hooks ||= []
        end

        def run_hooks
          return if @ran

          @ran = true
          hooks.each do |hook|
            hook.call
          rescue StandardError => e
            warn "[GracefulShutdown] #{e.class}: #{e.message}"
          end
        end

        # Test helper. Clears registered hooks and re-arms install!/run_hooks.
        def reset!
          @hooks = []
          @ran = false
          @installed = false
        end
      end
    end
  end
end
