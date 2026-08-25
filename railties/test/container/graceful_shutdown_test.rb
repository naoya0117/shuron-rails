# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../../lib/rails/container/graceful_shutdown"

class GracefulShutdownTest < Minitest::Test
  Events = Rails::Container::Events

  def setup
    Rails::Container::GracefulShutdown.reset!
    Events.reset!
    Events.output = StringIO.new
  end

  def teardown
    Events.reset!
  end

  def test_on_shutdown_registers_block
    called = false
    Rails::Container::GracefulShutdown.on_shutdown { called = true }
    Rails::Container::GracefulShutdown.run_hooks
    assert called
  end

  def test_multiple_hooks_run_in_registration_order
    order = []
    Rails::Container::GracefulShutdown.on_shutdown { order << :first }
    Rails::Container::GracefulShutdown.on_shutdown { order << :second }
    Rails::Container::GracefulShutdown.run_hooks
    assert_equal [:first, :second], order
  end

  def test_hook_exception_does_not_stop_subsequent_hooks
    order = []
    Rails::Container::GracefulShutdown.on_shutdown { raise "boom" }
    Rails::Container::GracefulShutdown.on_shutdown { order << :second }

    original_stderr = $stderr
    $stderr = StringIO.new
    begin
      Rails::Container::GracefulShutdown.run_hooks
    ensure
      $stderr = original_stderr
    end

    assert_equal [:second], order
  end

  def test_run_hooks_with_no_hooks_does_not_raise
    Rails::Container::GracefulShutdown.run_hooks
    pass
  end

  # The evidence a verification script greps for after `docker compose stop`.
  def test_run_hooks_brackets_the_run_with_begin_and_done_events
    Rails::Container::GracefulShutdown.on_shutdown { :ok }
    Rails::Container::GracefulShutdown.run_hooks

    assert_equal ["shutdown.begin serving=false hooks=1 service_hooks=0",
                  "shutdown.hook kind=resource index=0 status=ok",
                  "shutdown.done serving=false hooks=1"],
      event_summaries
  end

  # Emitted even with nothing registered: "the layer fired and had nothing to
  # do" is a different outcome from "the layer never heard the signal", and the
  # script has to be able to tell them apart.
  def test_run_hooks_emits_the_bracket_even_with_no_hooks
    Rails::Container::GracefulShutdown.run_hooks

    assert_equal ["shutdown.begin serving=false hooks=0 service_hooks=0",
                  "shutdown.done serving=false hooks=0"],
      event_summaries
  end

  def test_a_failing_hook_is_reported_and_the_run_still_completes
    Rails::Container::GracefulShutdown.on_shutdown { raise "boom" }
    Rails::Container::GracefulShutdown.on_shutdown { :ok }

    original_stderr = $stderr
    $stderr = StringIO.new
    begin
      Rails::Container::GracefulShutdown.run_hooks
    ensure
      $stderr = original_stderr
    end

    assert_equal ["shutdown.begin serving=false hooks=2 service_hooks=0",
                  "shutdown.hook kind=resource index=0 status=error",
                  "shutdown.hook kind=resource index=1 status=ok",
                  "shutdown.done serving=false hooks=2"],
      event_summaries
  end

  # --- on_service_stop: business logic must not fire in a boot process ------

  def test_service_hooks_are_skipped_when_the_process_never_served
    ran = false
    Rails::Container::GracefulShutdown.on_service_stop { ran = true }

    Rails::Container::GracefulShutdown.run_hooks

    refute ran, "business hooks must not run in a process that was never serving"
    assert_equal ["shutdown.begin serving=false hooks=0 service_hooks=1",
                  "shutdown.done serving=false hooks=0"],
      event_summaries
  end

  def test_service_hooks_run_once_the_process_is_marked_serving
    ran = false
    Rails::Container::GracefulShutdown.on_service_stop { ran = true }
    Rails::Container::GracefulShutdown.serving!(by: "server_block")

    Rails::Container::GracefulShutdown.run_hooks

    assert ran
    assert_equal ["shutdown.armed by=server_block",
                  "shutdown.begin serving=true hooks=0 service_hooks=1",
                  "shutdown.hook kind=service index=0 status=ok",
                  "shutdown.done serving=true hooks=0"],
      event_summaries
  end

  # Resource release is unconditional: closing your own connections on the way
  # out is correct in a rake task too.
  def test_resource_hooks_run_even_when_not_serving
    ran = false
    Rails::Container::GracefulShutdown.on_shutdown { ran = true }

    Rails::Container::GracefulShutdown.run_hooks

    assert ran
    assert_includes event_summaries, "shutdown.hook kind=resource index=0 status=ok"
  end

  def test_serving_is_recorded_once_and_the_first_caller_wins
    Rails::Container::GracefulShutdown.serving!(by: "server_block")
    Rails::Container::GracefulShutdown.serving!(by: "request")

    assert_equal ["shutdown.armed by=server_block"], event_summaries
  end

  def test_the_middleware_marks_the_process_on_the_first_request
    inner = ->(_env) { [200, {}, ["ok"]] }
    middleware = Rails::Container::GracefulShutdown::ServingMarker.new(inner)

    refute Rails::Container::GracefulShutdown.serving?
    middleware.call({})

    assert Rails::Container::GracefulShutdown.serving?
    assert_equal ["shutdown.armed by=request"], event_summaries
  end

  def test_on_service_stop_requires_a_block
    assert_raises(ArgumentError) { Rails::Container::GracefulShutdown.on_service_stop }
  end

  private
    # The emitted lines minus the noise that varies per run (prefix, pid,
    # duration), so the assertions read as the sequence of what happened.
    def event_summaries
      Events.recorded.map do |line|
        line.sub(Events::PREFIX, "").sub(" pid=#{Process.pid}", "").sub(/ duration_ms=\d+/, "")
      end
    end
end
