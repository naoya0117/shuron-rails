# frozen_string_literal: true

# require_relative, not an absolute require: this file is also loaded directly
# by its test, outside the bundle that puts railties/lib on the load path.
require_relative "events"

module Rails
  module Container
    # Managed Lifecycle (terminal): the application's SIGTERM handler.
    #
    # The book's obligation for this pattern is that the application shut down
    # cleanly when the orchestrator asks it to -- "closing connections, deleting
    # temporary files" -- and that a container otherwise behave like a properly
    # designed POSIX process. That is what this does, and +at_exit+ is the right
    # place for it in Ruby: SIGTERM's default disposition raises SignalException,
    # the exception unwinds the process, and +at_exit+ runs during that unwind.
    # Measured ordering in a real container: the server drains its in-flight
    # requests first, and only then do these hooks run -- so cleanup never tears
    # work out from under a request that was still being served.
    #
    # Registering from +at_exit+ rather than from a signal trap is deliberate. A
    # trap cannot take a Mutex ("can't be called from trap context"), which rules
    # out Rails.logger and the ActiveRecord connection pool -- i.e. most of what a
    # cleanup hook wants to touch. It also never competes with the app server's
    # own TERM handling, and it is the one mechanism that covers every process
    # kind (Puma and Pitchfork masters and workers, Sidekiq, CLI) from a single
    # registration.
    #
    # == The contract: act only on what this process owns
    #
    # A hook must confine itself to resources and work *this process* holds, and
    # must be idempotent.
    #
    # This is what makes the hook safe rather than a special case, because
    # +at_exit+ also runs in processes that were never serving: a container that
    # runs +rails db:prepare+ and +rails container:init+ before +exec+ing its
    # server passes through at_exit three times. A hook scoped to this process
    # has nothing to do in those two and is simply a no-op. An unscoped hook --
    # <tt>Order.cancel_processing!</tt> over every row -- would instead cancel
    # orders that other, healthy Pods were in the middle of processing.
    #
    # So the scope is the safety mechanism. Gating execution on "was this process
    # really serving" was tried and removed: it guards an unscoped hook, which
    # should not be written in the first place, and it cannot help under SIGKILL,
    # which runs nothing at all.
    #
    #   Rails::Container::GracefulShutdown.on_shutdown do
    #     Order.processing_by(pod_name).cancel!                    # this Pod's work
    #     ActiveRecord::Base.connection_handler.clear_all_connections!
    #   end
    #
    # Ordering caveat: install! runs after the app's own initializers, so these
    # hooks are registered last and therefore run *first* (at_exit is
    # last-in-first-out). An app +at_exit+ that still needs the database must not
    # rely on the connection being open.
    module GracefulShutdown
      class << self
        # Registers cleanup to run as the process terminates, which is how
        # SIGTERM arrives. See the contract above: this process's own resources
        # and work, idempotent.
        def on_shutdown(&block)
          raise ArgumentError, "on_shutdown requires a block" unless block

          hooks << block
        end

        # Arms the handler. Runs once; a second call is a no-op.
        def install!
          return if @installed

          @installed = true
          at_exit { run_hooks }
        end

        def hooks
          @hooks ||= []
        end

        # Bracketed by events so a verification script can tell "the layer never
        # heard SIGTERM" from "the layer ran and a hook hung". The pair is
        # emitted even with no hooks registered, since "the framework fired and
        # had nothing to do" is itself the thing under test.
        def run_hooks
          return if @ran

          @ran = true
          Events.emit("shutdown.begin", hooks: hooks.size)

          # A failing hook is reported and the run continues: cleanup left
          # undone is better than cleanup abandoned halfway.
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
