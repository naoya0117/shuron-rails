# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../../lib/rails/container/events"

class ContainerEventsTest < Minitest::Test
  Events = Rails::Container::Events

  def setup
    Events.reset!
    @out = StringIO.new
    Events.output = @out
  end

  def teardown
    Events.reset!
  end

  def test_emit_writes_one_prefixed_line_with_the_pid_and_fields_in_order
    Events.emit("init.step", name: :db_migrate, status: "ok")

    assert_equal "#{Events::PREFIX}init.step pid=#{Process.pid} name=db_migrate status=ok\n", @out.string
  end

  # The single-source property the verification scripts depend on: what a test
  # asserts and what a script greps are the same string, so a field rename can
  # never leave the tests green while the greps silently stop matching.
  def test_recorded_holds_exactly_the_lines_that_were_written
    Events.emit("shutdown.begin", hooks: 2)
    Events.emit("shutdown.done", hooks: 2)

    assert_equal @out.string, Events.recorded.map { |line| "#{line}\n" }.join
  end

  def test_timed_returns_the_block_value_and_reports_success_with_a_duration
    result = Events.timed("init.step", name: :seed) { :done }

    assert_equal :done, result
    assert_match(/\Aevent=init\.step .* name=seed status=ok duration_ms=\d+\z/,
      Events.recorded.last.sub(Events::PREFIX, "event="))
  end

  def test_timed_reports_a_failure_and_lets_the_exception_through
    assert_raises(RuntimeError) do
      Events.timed("init.step", name: :seed) { raise "boom" }
    end

    assert_includes Events.recorded.last, "name=seed status=error"
  end

  # An event must never break the thing it observes: stdout can be closed by
  # the time at_exit hooks run.
  def test_emit_survives_an_unusable_output
    Events.output = Object.new

    line = Events.emit("shutdown.done", hooks: 0)

    assert_includes line, "shutdown.done"
    assert_includes Events.recorded, line
  end
end
