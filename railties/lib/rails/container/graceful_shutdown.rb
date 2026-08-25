# frozen_string_literal: true

# require_relative, not an absolute require: this file is also loaded directly
# by its test, outside the bundle that puts railties/lib on the load path.
require_relative "events"

module Rails
  module Container
    # Managed Lifecycle (terminal): runs application cleanup when the process
    # terminates. Hooks run once, in registration order.
    #
    # == Two kinds of hook, because at_exit fires in every process
    #
    # +at_exit+ is the only mechanism that covers every process kind (Puma and
    # Pitchfork masters and workers, Sidekiq, CLI) with one registration -- but
    # it also fires in processes that were never serving anything. A container
    # that runs +rails db:prepare+ and +rails container:init+ before +exec+ing
    # its server passes through at_exit three times, twice while the app is
    # still booting. So the layer separates the two things an application wants
    # to do on the way out:
    #
    # [+on_shutdown+]
    #   Releases resources *this process* holds. Runs in every process, because
    #   closing your own connections as you exit is correct anywhere. Must be
    #   idempotent and free of business side effects.
    #
    # [+on_service_stop+]
    #   The application is being stopped: business work that must not be left
    #   half-done. Runs *only* in a process that was actually serving, so it
    #   cannot fire while the app is still booting. This is where logic that
    #   would otherwise live in the Model layer belongs.
    #
    # Without the split, a hook like <tt>Order.cancel_processing!</tt> would run
    # when +db:prepare+ exited -- cancelling orders that *other, healthy* Pods
    # were in the middle of processing.
    #
    # == How "was this process serving?" is decided
    #
    # By positive evidence only, never by guessing what kind of process this is.
    # Anything unrecognised is treated as not serving, so a console, a runner or
    # a one-off script can never trigger business hooks. Three sources arm it:
    #
    # 1. The +server+ railtie block, which +config.ru+ runs via
    #    <tt>Rails.application.load_server</tt>. Fires at server boot, before
    #    any request, so there is no window.
    # 2. This module's middleware, on the first request it handles. The safety
    #    net for an app whose +config.ru+ predates +load_server+ (Mastodon is
    #    one); the +serving_declaration+ diagnostic reports that gap, because
    #    until the first request arrives such a process looks non-serving.
    # 3. An explicit +serving!+, for a process that serves something other than
    #    HTTP. A Sidekiq worker declares itself from config/container.rb:
    #
    #      Sidekiq.configure_server do
    #        Rails::Container::GracefulShutdown.serving!
    #      end
    #
    # Two alternatives were measured and rejected outright: "the server is PID 1"
    # is false for any image with an ENTRYPOINT (with tini, PID 1 is tini), and
    # the middleware *stack* is built even for rake tasks, so its construction
    # says nothing (only a request passing through it does).
    #
    # A third alternative -- reading +$!+ inside at_exit to see whether a signal
    # ended the process -- turns out to work in more cases than this comment
    # first claimed, and the correction matters, so the measured matrix is:
    #
    #   Puma single mode           $! == SignalException SIGTERM
    #   Puma cluster master        $! == SignalException SIGTERM
    #   Puma cluster worker        $! == nil
    #   Sidekiq                    $! == SystemExit
    #   Pitchfork                  $! == SystemExit
    #   rake task / clean exit     $! == nil
    #
    # Puma raises deliberately: +raise_exception_on_sigterm+ defaults to true
    # (puma configuration.rb) and its TERM trap ends in
    # <tt>raise(SignalException, "SIGTERM")</tt>, so a Puma web process *can*
    # identify the signal. Nor is a trap installed here always lost: in Puma
    # single mode setup_signals runs *before* the app boots, so an app trap
    # replaces Puma's and can chain to it. Both of these are false only for
    # cluster workers, Sidekiq and Pitchfork -- exactly where +$!+ collapses to
    # nil or SystemExit and becomes indistinguishable from a clean exit.
    #
    # So +$!+ is a sharper signal than "did this process serve", but it is not a
    # complete one, and it arrives too late to be the primary mechanism. The
    # faithful route is the platform's own preStop hook, which the layer already
    # generates -- see Rails::Kubernetes::ManifestAnnotator.
    #
    # Ordering caveat: install! runs after the app's own initializers, so these
    # hooks are registered last and therefore run *first* (at_exit is
    # last-in-first-out). An app +at_exit+ that still needs the database must
    # not rely on the connection being open.
    module GracefulShutdown
      # Rack middleware that arms the service hooks on the first request. Only a
      # real server ever calls it, which is the point; a rake task builds the
      # middleware stack but never runs through it.
      class ServingMarker
        def initialize(app)
          @app = app
        end

        def call(env)
          GracefulShutdown.serving!(by: "request")
          @app.call(env)
        end
      end

      class << self
        # Registers cleanup for resources this process holds. Runs in every
        # process, so it must be idempotent and must not carry business side
        # effects -- use +on_service_stop+ for those.
        def on_shutdown(&block)
          raise ArgumentError, "on_shutdown requires a block" unless block

          hooks << block
        end

        # Registers work to run when the application is being stopped. Runs only
        # in a process that was actually serving (see +serving!+), so it is safe
        # to put business logic here.
        def on_service_stop(&block)
          raise ArgumentError, "on_service_stop requires a block" unless block

          service_hooks << block
        end

        # Records that this process is serving, which is what allows the
        # +on_service_stop+ hooks to run. Idempotent; the first caller wins so
        # the event reports how it was discovered.
        def serving!(by: "explicit")
          return true if @serving

          @serving = true
          Events.emit("shutdown.armed", by: by)
          true
        end

        def serving?
          !!@serving
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

        def service_hooks
          @service_hooks ||= []
        end

        # Bracketed by events so a verification script can tell "the layer never
        # heard SIGTERM" from "the layer ran and a hook hung". The pair is
        # emitted even with no hooks registered, since "the framework fired and
        # had nothing to do" is itself the thing under test. +serving+ says
        # whether the service hooks were eligible, so a skipped business hook is
        # never indistinguishable from a missing one.
        def run_hooks
          return if @ran

          @ran = true
          Events.emit("shutdown.begin", serving: serving?,
            hooks: hooks.size, service_hooks: service_hooks.size)

          run_each(hooks, "resource")
          run_each(service_hooks, "service") if serving?

          Events.emit("shutdown.done", serving: serving?, hooks: hooks.size)
        end

        # Test helper. Clears registered hooks and re-arms install!/run_hooks.
        def reset!
          @hooks = []
          @service_hooks = []
          @ran = false
          @installed = false
          @serving = false
        end

        private
          # A failing hook is reported and the run continues: cleanup left
          # undone is better than cleanup abandoned halfway.
          def run_each(list, kind)
            list.each_with_index do |hook, index|
              Events.timed("shutdown.hook", kind: kind, index: index) { hook.call }
            rescue StandardError => e
              warn "[GracefulShutdown] #{e.class}: #{e.message}"
            end
          end
      end
    end
  end
end
