module Spinner
  # A socket belongs to this state machine until a complete request is handed
  # to a worker. It also writes protocol errors and queue rejection responses.
  class PendingClient
    attr_reader :socket, :parser, :state, :id, :remainder

    def initialize(socket, port, header_limit, read_timeout, body_timeout, write_timeout,
                   capacity, queue_timeout, id, keepalive_timeout, max_requests,
                   tls_context = nil, options = {})
      @options = options
      @storage_pool = options[:storage_pool]
      @storage_pending = false
      @storage_finished = false
      @storage_error = nil
      @storage_status = 503
      @storage = nil
      @close_lock = Mutex.new
      peer = socket.respond_to?(:peeraddr) ? socket.peeraddr : nil
      @peer = peer.nil? ? "" : peer[3]
      @peer = "" if @peer.nil?
      if !peer.nil? && (peer[0] == "AF_INET" || peer[0] == "AF_INET6")
        # Separate small header and body writes can stall behind delayed ACKs.
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      end
      @socket = TLS::Socket.new(socket, tls_context)
      @port = port
      @scheme = tls_context.nil? ? "http" : "https"
      @header_limit = header_limit
      @parser = RequestParser.new(header_limit, port, @scheme, @options[:max_body_bytes])
      @state = tls_context.nil? ? :headers : :handshake
      @read_timeout = read_timeout
      @body_timeout = body_timeout
      @write_timeout = write_timeout
      @capacity = capacity
      @queue_timeout = queue_timeout
      @id = id
      @deadline = Transport.now + read_timeout
      @body_size = 0
      @body_complete = false
      @remainder = "".b
      @chunk_decoder = nil
      @requests_served = 0
      @keepalive_timeout = keepalive_timeout
      @max_requests = max_requests
      @idle = false
      @chunks = []
      @chunk_index = 0
      @chunk_offset = 0
      @wait_direction = :read
    end

    def storage_pending?
      @storage_pending
    end

    def reading?
      !@storage_pending && (@state == :handshake || @state == :headers || @state == :body)
    end

    def writing?
      @state == :writing || @state == :interim
    end

    def wait_readable?
      (reading? || writing?) && @wait_direction == :read
    end

    def wait_writable?
      (reading? || writing?) && @wait_direction == :write
    end

    def buffered_tls_data?
      @state != :handshake && reading? && @socket.respond_to?(:pending) && @socket.pending > 0
    end

    def io_step
      if @state == :handshake
        handshake_step
      elsif reading?
        read_step
      elsif writing?
        write_step
      end
    end

    def handshake_step
      @socket.accept_nonblock
      @state = :headers
      @wait_direction = :read
      @deadline = Transport.now + @read_timeout
    rescue IO::WaitReadable
      @wait_direction = :read
    rescue IO::WaitWritable
      @wait_direction = :write
    rescue EOFError, IOError, SystemCallError => error
      warn "SPINNER_METRIC event=tls_failure message=#{error.message}"
      close
    end

    def ready?
      @state == :ready
    end

    def closed?
      @state == :closed
    end

    def idle?
      @idle
    end

    def deadline
      @deadline
    end

    def queued!
      @state = :queued
      @queued_at = Transport.now
      @trace[:queued] = @queued_at if @trace
      @deadline = @queued_at + @queue_timeout
    end

    def claim!
      @state = :worker
      @trace[:worker_start] = Transport.now if @trace
      @queue_wait_ms = ((Transport.now - @queued_at) * 1000).round
    end

    def queue_wait_ms
      @queue_wait_ms
    end

    def queued?
      @state == :queued
    end

    def body
      @storage.input
    end

    def environment
      @options[:proxy_policy].apply(@parser.environment(body), @peer)
    end

    def cleanup_body
      @storage.close unless @storage.nil? || (@storage_pending && !@storage_finished)
    end

    def storage_step
      return unless @storage_pending && @storage_finished
      @storage_pending = false
      if closed?
        cleanup_body
      elsif !@storage_error.nil?
        reject(@storage_status)
      else
        if @body_complete
          @state = :ready
          @trace[:ready] = Transport.now if @trace
        end
        finish_continue
      end
    end

    def store_chunk(chunk)
      if @body_size + chunk.bytesize <= @options[:body_memory_bytes] && @chunk_decoder.nil?
        append_body(chunk)
        if @body_complete
          @state = :ready
          @trace[:ready] = Transport.now if @trace
        end
        finish_continue
        return
      end
      @storage_pending = true
      @storage_finished = false
      @storage_error = nil
      @storage_status = 503
      accepted = @storage_pool.submit(proc { @storage.close }) do
        begin
          append_body(chunk)
        rescue RequestError => error
          @storage_status = error.status
          @storage_error = error
        rescue StandardError => error
          @storage_error = error
        ensure
          @storage_finished = true
          @storage.close if closed?
        end
      end
      unless accepted
        @storage_pending = false
        reject(503)
      end
    end

    def finish_continue
      if @parser.expect_continue? && @state == :body && !@continued
        @continued = true
        @chunks = ["HTTP/1.1 100 Continue\r\n\r\n"]
        @chunk_index = 0
        @chunk_offset = 0
        @state = :interim
        @wait_direction = :write
        @deadline = Transport.now + @write_timeout
      end
    end

    attr_accessor :stream_deadline

    def expire_stream(now)
      close if !@stream_deadline.nil? && now >= @stream_deadline
    end

    def keep_alive?
      @parser.keep_alive? && @requests_served + 1 < @max_requests
    end

    def next_request!
      @requests_served += 1
      @trace = nil
      @trace_id = nil
      bytes = @remainder
      @remainder = "".b
      cleanup_body
      @storage = nil
      @continued = false
      @parser = RequestParser.new(@header_limit, @port, @scheme, @options[:max_body_bytes])
      @body_size = 0
      @body_complete = false
      @chunk_decoder = nil
      @state = :headers
      @wait_direction = :read
      @idle = true
      @deadline = Transport.now + @keepalive_timeout
      consume(bytes) unless bytes.empty?
    end

    def read_step
      chunk = @socket.read_nonblock(65536)
      @wait_direction = :read
      consume(chunk)
    rescue IO::WaitReadable
      @wait_direction = :read
    rescue IO::WaitWritable
      @wait_direction = :write
    rescue EOFError
      if @state == :headers
        close
      else
        reject(400)
      end
    end

    def consume(chunk)
      if @idle && !chunk.empty?
        @idle = false
        @deadline = Transport.now + @read_timeout
      end
      if @state == :headers
        if @parser.feed(chunk)
          trace_id = @parser.headers["x-spinner-trace"]
          unless trace_id.nil? || trace_id.empty? || trace_id.bytesize > 200 || trace_id.match?(/[^a-zA-Z0-9_.-]/)
            @trace_id = trace_id
            @request_sequence = @requests_served + 1
            @trace = {}
          end
          @state = :body
          @body_deadline = Transport.now + @body_timeout
          @deadline = @body_deadline
          @storage = BodyStorage.new(@options[:max_body_bytes], @options[:body_memory_bytes],
                                     @options[:spool_directory], @options[:storage_budget])
          @chunk_decoder = ChunkDecoder.new(@storage, @options[:max_body_bytes]) if @parser.chunked?
          store_chunk(@parser.remainder)
        end
      else
        store_chunk(chunk)
      end
    end

    def append_body(chunk)
      unless @chunk_decoder.nil?
        if @chunk_decoder.feed(chunk)
          @remainder = @chunk_decoder.remainder
          @body_complete = true
        end
        return
      end
      remaining = @parser.content_length - @body_size
      count = [remaining, chunk.bytesize].min
      if count > 0
        @storage.append(chunk.byteslice(0, count).b)
        @body_size += count
      end
      if @body_size == @parser.content_length
        @remainder = chunk.byteslice(count, chunk.bytesize - count).to_s.b
        @body_complete = true
      end
    end

    def reject(status)
      cleanup_body
      warn "SPINNER_METRIC event=rejected status=#{status} id=#{@id}"
      writer = ResponseWriter.new
      respond(writer.prepare([status, {"content-type" => "text/plain"}, [ResponseWriter.reason(status)]]))
    end

    def respond(chunks)
      @chunks = chunks
      @chunk_index = 0
      @chunk_offset = 0
      @state = :writing
      @wait_direction = :write
      @deadline = Transport.now + @write_timeout
    end

    def write_step
      while @chunk_index < @chunks.length
        chunk = @chunks[@chunk_index]
        if @chunk_offset == chunk.bytesize
          @chunk_index += 1
          @chunk_offset = 0
          next
        end
        # The binary local selects Spinel's length-aware socket write path.
        binary = chunk.byteslice(@chunk_offset, chunk.bytesize - @chunk_offset).to_s.b
        count = @socket.write_nonblock(binary)
        @wait_direction = :write
        raise IOError, "invalid write progress" if count <= 0 || count > binary.bytesize
        @chunk_offset += count
        return
      end
      if @state == :interim
        @chunks = []
        @state = :body
        @wait_direction = :read
        @deadline = @body_deadline
      else
        @trace[:response_write_done] = Transport.now if @trace
        close
      end
    rescue IO::WaitWritable
      @wait_direction = :write
    rescue IO::WaitReadable
      @wait_direction = :read
    rescue EOFError, IOError, SystemCallError => error
      warn "Spinner transport: #{error.message}"
      close
    end

    def expire(now)
      return unless reading? || writing? || @storage_pending
      return if now < @deadline
      if @storage_pending
        close
      elsif reading?
        @state == :handshake || @idle ? close : reject(408)
      else
        close
      end
    end

    def close
      @close_lock.synchronize do
        return if @state == :closed
        @state = :closed
        begin
          @socket.close unless @socket.closed?
        ensure
          cleanup_body
          @capacity.release
        end
      end
    end

    attr_reader :trace, :trace_id, :request_sequence

  end

  class Reactor
    def initialize(listener, application, port, header_limit, read_timeout, body_timeout, write_timeout,
                   threads, queue_capacity, max_connections, queue_timeout, drain_timeout,
                   keepalive_timeout, max_requests, tls_context = nil, options = {})
      @options = options
      @options[:storage_pool] = TaskPool.new(options[:storage_workers], max_connections)
      @options[:storage_budget] = StorageBudget.new(options[:spool_budget_bytes])
      @listener = listener
      @application = application
      @port = port
      @header_limit = header_limit
      @read_timeout = read_timeout
      @body_timeout = body_timeout
      @write_timeout = write_timeout
      @clients = []
      @queued = []
      @capacity = Capacity.new(max_connections)
      @queue_timeout = queue_timeout
      @drain_timeout = drain_timeout
      @keepalive_timeout = keepalive_timeout
      @max_requests = max_requests
      @tls_context = tls_context
      @reactor_heartbeat = options[:reactor_heartbeat]
      @shutdown_requested = false
      @graceful_shutdown = false
      @force_shutdown_requested = false
      @draining = false
      @next_id = 0
      @accept_backoff_until = 0.0
      @reserve_fd = File.open("/dev/null", "r")
      @reserve_fd.close # Initialize Spinel’s shared closed-file sentinel before descriptors can exhaust.
      @reserve_fd = File.open("/dev/null", "r")
      @reserve_reopen_count = nil
      @last_heartbeat = Transport.now
      @wakeup = ReactorWakeup.new
      @pool = ThreadPool.new(application, threads, queue_capacity, header_limit,
                             read_timeout, write_timeout, body_timeout, port, @capacity, @options, @wakeup)
    rescue Exception # rubocop:disable Lint/RescueException -- clean up after interrupted or failed pool startup
      # ThreadPool stops any partially started workers before its constructor
      # raises. Storage workers are lazy and cannot have started here yet.
      @wakeup.close unless @wakeup.nil?
      @reserve_fd.close unless @reserve_fd.nil? || @reserve_fd.closed?
      raise
    end

    def shutdown!(graceful = false)
      @graceful_shutdown = true if graceful
      @force_shutdown_requested = true unless graceful
      @shutdown_requested = true
    end

    def run
      loop do
        # Drain BEFORE inspecting completions/capacity. A later publication
        # leaves a readable token for select, including when the pipe was full.
        # Draining after the final state check could lose that wakeup.
        @wakeup.drain
        now = Transport.now
        if @reactor_heartbeat && now - @last_heartbeat >= 1.0
          warn "SPINNER_METRIC event=reactor pid=#{Process.pid} connections=#{@capacity.count} clients=#{@clients.length} queued=#{@queued.length} app_active=#{@pool.active_count}"
          @last_heartbeat = now
        end
        if @reserve_fd.nil? && !@reserve_reopen_count.nil? && @capacity.count < @reserve_reopen_count
          begin
            @reserve_fd = File.open("/dev/null", "r")
            @reserve_reopen_count = nil
          rescue SystemCallError, IOError
            nil
          end
        end
        parent_pid = ENV["SPINNER_PARENT_PID"]
        @shutdown_requested = true if !parent_pid.nil? && Process.ppid != parent_pid.to_i
        if @shutdown_requested && !@draining
          @draining = true
          @drain_deadline = now + @drain_timeout
          @listener.close unless @listener.closed?
          if @graceful_shutdown
            @clients.each { |client| client.close if client.idle? }
            @clients.reject!(&:closed?)
          else
            @clients.each(&:close)
            @clients.clear
            @pool.request_stop(@drain_deadline)
          end
          warn "SPINNER_METRIC event=shutdown connections=#{@capacity.count} queued=#{@pool.queued_count} active=#{@pool.active_count} streams=#{@pool.stream_count} upgrades=#{@pool.upgrade_count} pid=#{Process.pid}"
        end
        if @draining && @graceful_shutdown && @force_shutdown_requested
          @graceful_shutdown = false
          @clients.each(&:close)
          @clients.clear
          @pool.request_stop(@drain_deadline)
        end
        break if @draining && (@capacity.count == 0 || now >= @drain_deadline)
        @clients.each do |client|
          client.storage_step
          client.expire(now)
          queue_client(client) if client.ready? && !client.storage_pending?
        end
        @clients.reject!(&:closed?)
        @queued.reject! do |client|
          if @pool.queued?(client)
            if !@draining && now >= client.deadline && @pool.cancel(client)
              client.reject(503)
              @clients << client
              true
            else
              false
            end
          else
            true
          end
        end
        @pool.expire_async
        @pool.maintain(@application, @header_limit, @read_timeout,
                       @write_timeout, @body_timeout, @port) unless @draining
        @pool.completed.each do |client|
          if client.trace
            client.trace[:reactor_collection] = Transport.now
            trace = client.trace
            total_ms = (trace[:reactor_collection] - trace[:ready]) * 1000.0
            if total_ms > 5.0
              ms = ->(from, to) { (trace[to] && trace[from] ? (trace[to] - trace[from]) * 1000.0 : nil) }
              line = "SPINNER_TRACE trace_id=#{client.trace_id} connection_id=#{client.id} request_sequence=#{client.request_sequence} pid=#{Process.pid} total_ms=#{format('%.3f', total_ms)} ready_to_queue_ms=#{format('%.3f', ms.call(:ready, :queued) || 0)} queue_ms=#{format('%.3f', ms.call(:queued, :worker_start) || 0)} worker_to_app_ms=#{format('%.3f', ms.call(:worker_start, :app_start) || 0)} app_ms=#{format('%.3f', ms.call(:app_start, :app_return) || 0)} write_ms=#{format('%.3f', ms.call(:app_return, :response_write_done) || 0)} completion_to_reactor_ms=#{format('%.3f', ms.call(:completion_publication, :reactor_collection) || 0)}"
              if ENV["SPINNER_TRACE_OUTPUT"] == "discard"
                nil
              elsif ENV["SPINNER_TRACE_LOG"]
                File.open(ENV["SPINNER_TRACE_LOG"], "a") { |file| file.puts(line) }
              else
                warn line
              end
            end
          end
          if @draining || client.closed?
            client.close
          else
            begin
              client.next_request!
              @clients << client
              queue_client(client) if client.ready?
            rescue RequestError => error
              client.reject(error.status)
              @clients << client
            end
          end
        end
        @clients.each do |client|
          read_client(client) if !client.closed? && client.buffered_tls_data?
        end
        reads = [@wakeup.reader]
        reads << @listener unless @draining || @capacity.full? || now < @accept_backoff_until
        writes = []
        deadline = nil
        @clients.each do |client|
          reads << client.socket.to_io if client.wait_readable?
          writes << client.socket.to_io if client.wait_writable?
          if client.reading? || client.writing?
            deadline = client.deadline if deadline.nil? || client.deadline < deadline
          end
        end
        @queued.each do |client|
          next if @draining
          deadline = client.deadline if deadline.nil? || client.deadline < deadline
        end
        timeout = deadline.nil? ? poll_interval : [[deadline - Transport.now, 0.0].max, poll_interval].min
        timeout = [timeout, 0.001].min if @clients.any?(&:storage_pending?)
        selected = IO.select(reads, writes, nil, timeout)
        next if selected.nil?
        selected[0].each do |socket|
          if socket == @wakeup.reader
            # The next iteration drains notifications and checks shared state.
            next
          elsif socket == @listener
            accept_ready
          else
            client = @clients.find { |candidate| candidate.socket.to_io == socket }
            read_client(client) unless client.nil?
          end
        end
        selected[1].each do |socket|
          client = @clients.find { |candidate| candidate.socket.to_io == socket }
          read_client(client) unless client.nil? || client.closed?
        end
      end
    ensure
      begin
        warn "SPINNER_METRIC event=shutdown_complete pid=#{Process.pid} remaining=#{@capacity.count} outcome=#{@capacity.count == 0 ? 'drained' : 'forced'}"
        @clients.each(&:close)
        @queued.each do |client|
          client.close if @pool.cancel(client)
        end
      ensure
        begin
          @pool.stop
        ensure
          begin
            @options[:storage_pool].stop
          ensure
            begin
              @reserve_fd.close unless @reserve_fd.nil? || @reserve_fd.closed?
              @pool.completed.each(&:close)
            ensure
              @wakeup.close
            end
          end
        end
      end
    end

    def poll_interval
      0.005
    end

    def accept_ready
      return if @capacity.full?
      socket = @listener.accept_nonblock
      @capacity.acquire
      @next_id += 1
      begin
        @clients << PendingClient.new(socket, @port, @header_limit, @read_timeout,
                                      @body_timeout, @write_timeout,
                                      @capacity, @queue_timeout, @next_id,
                                      @keepalive_timeout, @max_requests,
                                      @tls_context, @options)
      rescue StandardError
        socket.close unless socket.closed?
        @capacity.release
        raise
      end
      warn "SPINNER_METRIC event=accept id=#{@next_id} connections=#{@capacity.count} pid=#{Process.pid}"
    rescue IO::WaitReadable
      nil
    rescue Errno::EMFILE, Errno::ENFILE, Errno::ECONNABORTED => error
      warn "Spinner accept: #{error.message}"
      unless @reserve_fd.nil?
        @reserve_fd.close
        @reserve_fd = nil
        @reserve_reopen_count = @capacity.count
      end
      @accept_backoff_until = Transport.now + 0.1
    end

    def read_client(client)
      return if client.closed?
      client.io_step
      return unless client.ready? && !client.storage_pending?
      queue_client(client)
    rescue RequestError => error
      client.reject(error.status)
    rescue IOError, SystemCallError => error
      warn "Spinner transport: #{error.message}"
      client.close
    end

    def queue_client(client)
      if @pool.enqueue(client)
        @clients.delete(client)
        @queued << client
        if @options[:request_metrics]
          warn "SPINNER_METRIC event=queued id=#{client.id} queued=#{@pool.queued_count} connections=#{@capacity.count}"
        end
      else
        client.reject(503)
      end
    end
  end
end
