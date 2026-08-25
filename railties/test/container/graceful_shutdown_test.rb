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

    assert_equal ["shutdown.begin hooks=1", "shutdown.hook index=0 status=ok",
                  "shutdown.done hooks=1"],
      event_summaries
  end

  # Emitted even with nothing registered: "the layer fired and had nothing to
  # do" is a different outcome from "the layer never heard the signal", and the
  # script has to be able to tell them apart.
  def test_run_hooks_emits_the_bracket_even_with_no_hooks
    Rails::Container::GracefulShutdown.run_hooks

    assert_equal ["shutdown.begin hooks=0", "shutdown.done hooks=0"], event_summaries
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

    assert_equal ["shutdown.begin hooks=2", "shutdown.hook index=0 status=error",
                  "shutdown.hook index=1 status=ok", "shutdown.done hooks=2"],
      event_summaries
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
