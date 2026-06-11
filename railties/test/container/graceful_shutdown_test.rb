# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../../lib/rails/container/graceful_shutdown"

class GracefulShutdownTest < Minitest::Test
  def setup
    Rails::Container::GracefulShutdown.reset!
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
end
