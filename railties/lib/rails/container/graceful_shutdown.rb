# frozen_string_literal: true

# require_relative, not an absolute require: this file is also loaded directly
# by its test, outside the bundle that puts railties/lib on the load path.
require_relative "events"

module Rails
  module Container
    # Managed Lifecycle (terminal): runs application cleanup when the process
    # terminates. Hooks run once, in registration order.
    #
    # == The contract: release resources, do not run business logic
    #
    # A hook must only release what *this process* holds, must be idempotent,
    # and must have no business side effects. That is not a style preference --
    # it is forced by where the hooks run.
    #
    # +at_exit+ fires in *every* Ruby process, not just the server: a container
    # that runs +rails db:prepare+ and +rails container:init+ before +exec+ing
    # its server executes the hooks three times, twice of them while the app is
    # still starting up. A hook that marked the node offline or flushed a
    # pending queue would therefore fire during boot, repeatedly, and could
    # undo what initialization had just done.
    #
    # The layer cannot narrow this by detecting "am I the server", and that was
    # established by measurement, not assumption:
    #
    # * +config.ru+'s Rails.application.load_server (which drives
    #   Railtie.server) is missing from apps generated before it was added --
    #   Mastodon is one, so its Puma would be classified as "not a server".
    # * "the server is PID 1" is false whenever the image has an ENTRYPOINT:
    #   with tini, PID 1 is tini and the server is some other pid.
    # * a TERM trap set here is replaced by the server's own, installed after
    #   boot, so it never sees the signal -- and a server that handles TERM and
    #   exits cleanly leaves $! as SystemExit, indistinguishable from a rake
    #   task finishing.
    #
    # Since the process cannot be identified reliably, the contract has to be
    # one that is safe in any process. Work that must happen exactly once when
    # the *Pod* stops belongs in a +preStop+ hook -- generated from the
    # +graceful_shutdown+ settings -- where the platform controls the timing.
    # Business logic that belongs to the container layer goes in an init step
    # (Rails::Container.init_step), which is specified to run once, before
    # traffic, and idempotently.
    #
    # Ordering caveat: install! runs after the app's own initializers, so these
    # hooks are registered last and therefore run *first* (at_exit is
    # last-in-first-out). An app +at_exit+ that still needs the database must
    # not rely on the connection being open.
    module GracefulShutdown
      class << self
        # Registers cleanup to run as the process terminates. See the contract
        # above: release resources only, idempotent, no business side effects.
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
