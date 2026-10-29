module Spinner
  # A level-triggered hint to inspect shared state, not a queue of completions.
  # The reactor owns these descriptors and closes them after its producers stop.
  class ReactorWakeup
    attr_reader :reader

    def initialize
      @reader, @writer = IO.pipe
      @reader.close_on_exec = true
      @writer.close_on_exec = true
    rescue Exception # rubocop:disable Lint/RescueException -- release descriptors even on interrupted initialization
      close
      raise
    end

    def signal
      @writer.write_nonblock(".".b)
      nil
    rescue IO::WaitWritable
      # A full pipe is already readable; the queued state remains authoritative.
      nil
    rescue Errno::EINTR
      retry
    end

    def drain
      loop { @reader.read_nonblock(4096) }
    rescue IO::WaitReadable
      nil
    rescue Errno::EINTR
      retry
    end

    def close
      begin
        @writer.close unless @writer.nil? || @writer.closed?
      ensure
        @reader.close unless @reader.nil? || @reader.closed?
      end
    end
  end
end
