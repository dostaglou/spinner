# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/spinner"

class ReactorWakeupTest < Minitest::Test
  def setup
    @wakeup = Spinner::ReactorWakeup.new
  end

  def teardown
    @wakeup.close
  end

  def test_notification_before_select_and_drain_to_idle
    @wakeup.signal
    assert(IO.select([@wakeup.reader], nil, nil, 0))
    @wakeup.drain
    assert_nil(IO.select([@wakeup.reader], nil, nil, 0))
    @wakeup.drain
    @wakeup.signal
    assert(IO.select([@wakeup.reader], nil, nil, 0))
  end

  def test_notification_wakes_a_waiting_selector
    entered = Queue.new
    thread = Thread.new do
      entered << true
      IO.select([@wakeup.reader], nil, nil, 5)
    end
    entered.pop
    @wakeup.signal
    assert(thread.join(1), "notification did not wake select")
    assert(thread.value)
  ensure
    thread&.kill
    thread&.join
  end

  def test_full_pipe_coalesces_without_blocking_producers
    writer = @wakeup.instance_variable_get(:@writer)
    Timeout.timeout(2) do
      begin
        loop { writer.write_nonblock("x" * 4096) }
      rescue IO::WaitWritable
        # Fill any remaining space too, so even a one-byte signal cannot fit.
        begin
          loop { writer.write_nonblock("x") }
        rescue IO::WaitWritable
          nil
        end
      end
      100.times { @wakeup.signal }
    end
    assert(IO.select([@wakeup.reader], nil, nil, 0))
    @wakeup.drain
    assert_nil(IO.select([@wakeup.reader], nil, nil, 0))
    @wakeup.signal
    assert(IO.select([@wakeup.reader], nil, nil, 0))
  end

  def test_concurrent_producers_can_signal_while_consumer_drains
    threads = 8.times.map { Thread.new { 500.times { @wakeup.signal } } }
    Timeout.timeout(3) do
      @wakeup.drain while threads.any?(&:alive?)
      threads.each(&:value)
    end
    @wakeup.drain
    assert_nil(IO.select([@wakeup.reader], nil, nil, 0))
  ensure
    threads&.each(&:kill)
    threads&.each(&:join)
  end

  def test_descriptors_are_close_on_exec_and_close_is_idempotent
    writer = @wakeup.instance_variable_get(:@writer)
    assert(@wakeup.reader.close_on_exec?)
    assert(writer.close_on_exec?)
    @wakeup.close
    @wakeup.close
    assert(@wakeup.reader.closed?)
    assert(writer.closed?)
  end

  def test_unexpected_eof_is_not_silently_treated_as_a_notification
    @wakeup.instance_variable_get(:@writer).close
    assert_raises(EOFError) { @wakeup.drain }
  end

  def test_interrupted_signal_and_drain_are_retried
    writer = @wakeup.instance_variable_get(:@writer)
    original_write = writer.method(:write_nonblock)
    interrupted_write = false
    writer.define_singleton_method(:write_nonblock) do |bytes|
      unless interrupted_write
        interrupted_write = true
        raise Errno::EINTR
      end
      original_write.call(bytes)
    end
    @wakeup.signal
    assert(IO.select([@wakeup.reader], nil, nil, 0))

    reader = @wakeup.reader
    original_read = reader.method(:read_nonblock)
    interrupted_read = false
    reader.define_singleton_method(:read_nonblock) do |count|
      unless interrupted_read
        interrupted_read = true
        raise Errno::EINTR
      end
      original_read.call(count)
    end
    @wakeup.drain
    assert_nil(IO.select([reader], nil, nil, 0))
  end

  def test_partial_pool_startup_stops_producers_before_returning_failure
    started = []
    pool_class = Class.new(Spinner::ThreadPool) do
      define_method(:spawn_worker) do |*arguments|
        raise ThreadError, "injected startup failure" unless started.empty?
        super(*arguments).tap { |thread| started << thread }
      end
    end
    assert_raises(ThreadError) do
      pool_class.new(Object.new, 2, 8, 32768, 5, 5, 5, "0",
                     Spinner::Capacity.new(8), {max_streams: 1, max_upgrades: 1}, @wakeup)
    end
    assert_equal(1, started.length)
    refute(started.first.alive?)
    refute(@wakeup.reader.closed?, "pool must not close reactor-owned notifier")
  ensure
    started&.each(&:kill)
    started&.each(&:join)
  end
end
