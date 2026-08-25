# frozen_string_literal: true

module Rails
  module Container
    # Execution evidence for the register-type mechanisms.
    #
    # Init Container and Managed Lifecycle are declared up front and run much
    # later -- one before traffic, one as the process dies -- so inspecting the
    # registry only proves the app *declared* them. These events are the record
    # that they actually ran, which is what makes the behaviour scriptable from
    # outside the process:
    #
    #   docker compose up   -> wait for  event=init.done
    #   docker compose stop -> expect    event=shutdown.done  within the grace period
    #
    # A missing +shutdown.done+ has two very different causes, and the pair of
    # events tells them apart: no +shutdown.begin+ means the signal never
    # reached Ruby (entrypoint swallowing SIGTERM, or the grace period expiring
    # into SIGKILL), while +shutdown.begin+ without +shutdown.done+ means a hook
    # or the layer itself hung. Without that split a red run sends you debugging
    # the wrong layer.
    #
    # Lines go straight to $stdout rather than through Rails.logger: shutdown
    # hooks run from at_exit, by which point the logger may be closed or
    # reconfigured, and a line that disappears exactly when the process is
    # terminating would defeat the purpose. Writing here also keeps log_tags out
    # of the text that the verification scripts grep for.
    module Events
      # The grep contract shared with the verification scripts. Anything
      # matching on these lines from outside should key off this string.
      PREFIX = "[container] event="

      class << self
        # Where lines are written. Redirected in tests.
        attr_accessor :output

        # The lines emitted so far, as emitted. Tests read these instead of
        # parsing stdout, but they are the *same strings* that were written --
        # the formatting happens once, so an assertion cannot pass while the
        # text a script greps for has changed underneath it.
        def recorded
          @recorded ||= []
        end

        def emit(name, **fields)
          line = +"#{PREFIX}#{name} pid=#{Process.pid}"
          fields.each { |key, value| line << " #{key}=#{value}" }

          recorded << line
          write(line)
          line
        end

        # Runs the block and emits +name+ once it finishes, carrying how long it
        # took and whether it raised. The exception, if any, propagates
        # untouched -- callers decide whether a failure is fatal.
        def timed(name, **fields)
          started = now_ms
          ok = false

          begin
            result = yield
            ok = true
            result
          ensure
            emit(name, **fields, status: ok ? "ok" : "error", duration_ms: now_ms - started)
          end
        end

        # Test helper.
        def reset!
          @recorded = []
          @output = nil
        end

        private
          def now_ms
            Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
          end

          # An event must never break the thing it is observing: a closed or
          # full stdout during shutdown is not a reason to abort the shutdown.
          def write(line)
            io = output || $stdout
            io.puts(line)
            io.flush
          rescue StandardError
            nil
          end
      end
    end
  end
end
