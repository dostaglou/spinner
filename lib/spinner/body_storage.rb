module Spinner
  # One budget per worker process. Reservations include every byte in a spool.
  class StorageBudget
    def initialize(limit)
      @limit = limit
      @used = 0
      @lock = Mutex.new
    end

    def reserve(bytes)
      @lock.synchronize do
        if @used + bytes > @limit
          warn "SPINNER_METRIC event=spool_exhausted bytes=#{@used} limit=#{@limit}"
          raise RequestError.new(503, "spool budget exhausted")
        end
        @used += bytes
      end
    end

    def release(bytes)
      @lock.synchronize { @used -= bytes }
    end
  end

  class BodyStorage
    attr_reader :size

    def initialize(maximum, threshold, directory, budget)
      @maximum = maximum
      @threshold = threshold
      @directory = directory
      @budget = budget
      @bytes = "".b
      @file = nil
      @path = nil
      @reserved = 0
      @size = 0
      @closed = false
    end

    def append(bytes)
      raise IOError, "closed body" if @closed
      raise RequestError.new(413, "request body too large") if @size + bytes.bytesize > @maximum
      if @file.nil? && @size + bytes.bytesize > @threshold
        # Exclusive creation and mode 0600 prevent following an existing path.
        20.times do
          @path = File.join(@directory, "spinner-#{Process.pid}-#{rand(1_000_000_000)}.body")
          begin
            @file = File.open(@path, File::RDWR | File::CREAT | File::EXCL, 0600)
            @file.binmode
            break
          rescue Errno::EEXIST
            @path = nil
          end
        end
        raise IOError, "cannot create spool" if @file.nil?
        reserve(@bytes.bytesize)
        @file.write(@bytes)
        @bytes = "".b
        warn "SPINNER_METRIC event=body_spill pid=#{Process.pid}"
      end
      if @file.nil?
        @bytes << bytes
      else
        reserve(bytes.bytesize)
        @file.write(bytes)
      end
      @size += bytes.bytesize
    rescue SystemCallError, IOError => error
      close
      raise RequestError.new(503, "body storage unavailable: #{error.message}")
    end

    def reserve(bytes)
      @budget.reserve(bytes)
      @reserved += bytes
    end

    def input
      if @file.nil?
        Input.new(@bytes)
      else
        @file.flush
        @file.rewind
        Input.new("".b, @file)
      end
    end

    def close
      return if @closed
      @closed = true
      warn "SPINNER_METRIC event=body_cleanup bytes=#{@size} disk_bytes=#{@reserved}" if @reserved > 0
      begin
        @file.close unless @file.nil? || @file.closed?
      ensure
        File.unlink(@path) if !@path.nil? && File.exist?(@path)
      end
    ensure
      if @reserved > 0
        @budget.release(@reserved)
        @reserved = 0
      end
      @bytes = "".b
    end
  end
end
