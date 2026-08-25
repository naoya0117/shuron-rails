# frozen_string_literal: true

# require_relative, not an absolute require: this file is also loaded directly
# by its test, outside the bundle that puts railties/lib on the load path.
require_relative "events"

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

        # Bracketed by events so a verification script can tell "the layer never
        # heard SIGTERM" from "the layer ran and a hook hung" -- see
        # Rails::Container::Events. The pair is emitted even with no hooks
        # registered, since "the framework fired and had nothing to do" is
        # itself the thing under test.
        def run_hooks
          return if @ran

          @ran = true
          Events.emit("shutdown.begin", hooks: hooks.size)

          hooks.each_with_index do |hook, index|
            Events.timed("shutdown.hook", index: index) { hook.call }
          rescue StandardError => e
            warn "[GracefulShutdown] #{e.class}: #{e.message}"
          end

          Events.emit("shutdown.done", hooks: hooks.size)
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
