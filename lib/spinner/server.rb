module Spinner
  class Transport
    def initialize(socket)
      @socket = socket
    end

    def track_activity(client, timeout)
      @activity_client = client
      @activity_timeout = timeout
      progress!
    end

    def progress!
      unless @activity_client.nil?
        @activity_deadline = Transport.now + @activity_timeout
        @activity_client.stream_deadline = @activity_deadline
      end
    end

    def self.now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def read_chunk(deadline, max_bytes = 4096, phase = "header")
      loop do
        deadline = @activity_deadline unless @activity_client.nil?
        remaining = deadline - Transport.now
        raise RequestError.new(408, "#{phase} read deadline exceeded") if remaining <= 0
        begin
          bytes = @socket.read_nonblock(max_bytes)
          progress!
          return bytes
        rescue IO::WaitReadable
          if IO.select([@socket.to_io], nil, nil, remaining).nil?
            raise RequestError.new(408, "#{phase} read deadline exceeded")
          end
        rescue IO::WaitWritable
          if IO.select(nil, [@socket.to_io], nil, remaining).nil?
            raise RequestError.new(408, "#{phase} read deadline exceeded")
          end
        end
      end
    end

    def write_some(bytes, deadline)
      binary = bytes.to_s.b
      loop do
        deadline = @activity_deadline unless @activity_client.nil?
        remaining = deadline - Transport.now
        raise IOError, "response write deadline exceeded" if remaining <= 0
        begin
          # Explicit binary encoding selects Spinel's length-aware socket API.
          count = @socket.write_nonblock(binary)
          progress!
          return count
        rescue IO::WaitWritable
          raise IOError, "response write deadline exceeded" if IO.select(nil, [@socket.to_io], nil, remaining).nil?
        rescue IO::WaitReadable
          raise IOError, "response write deadline exceeded" if IO.select([@socket.to_io], nil, nil, remaining).nil?
        end
      end
    end

    # A single bounded write for protocols that own their framing and deadline.
    def write_stream_chunk(bytes, deadline)
      loop do
        remaining = deadline - Transport.now
        raise IOError, "stream write deadline exceeded" if remaining <= 0
        begin
          count = @socket.write_stream_nonblock(bytes)
          progress!
          return count
        rescue IO::WaitWritable
          raise IOError, "stream write deadline exceeded" if IO.select(nil, [@socket.to_io], nil, remaining).nil?
        rescue IO::WaitReadable
          raise IOError, "stream write deadline exceeded" if IO.select([@socket.to_io], nil, nil, remaining).nil?
        end
      end
    end
  end

  class Connection
    def initialize(application, header_limit, read_timeout, write_timeout, body_timeout, server_port)
      @application = application
      @header_limit = header_limit
      @read_timeout = read_timeout
      @write_timeout = write_timeout
      @body_timeout = body_timeout
      @server_port = server_port
    end

    def serve_buffered(client, executor, stream_timeout)
      transport = Transport.new(client.socket)
      writer = ResponseWriter.new
      response = nil
      handed_off = false
      app_started = Transport.now
      client.trace[:app_start] = app_started if client.trace
      begin
        response = @application.call(client.environment)
        client.trace[:app_return] = Transport.now if client.trace
        unless response.is_a?(Array) && response.length == 3
          raise ArgumentError, "expected [status, headers, body]"
        end
        body = response[2]
        keep_alive = client.keep_alive?
        if body.is_a?(Upgrade)
          connection_tokens = client.parser.headers.fetch("connection", "").downcase.split(",").map(&:strip)
          unless client.parser.protocol == "HTTP/1.1" && connection_tokens.include?("upgrade") && !client.parser.headers.fetch("upgrade", "").empty?
            raise ArgumentError, "upgrade requires HTTP/1.1 upgrade request"
          end
          head = writer.upgrade_header(response)
          accepted = executor.call(:upgrade, client, body) do
            transport.track_activity(client, stream_timeout)
            begin
              writer.write(transport, [head], Transport.now + @write_timeout)
              body.call(transport, client.remainder)
              false
            ensure
              body.close
            end
          end
          if accepted
            handed_off = true
            return :async
          end
          body.close
          response = [503, {}, ["Service Unavailable"]]
        elsif !body.is_a?(Array)
          stream = writer.prepare_stream(response, keep_alive, client.parser.protocol)
          accepted = executor.call(:stream, client, body) do
            transport.track_activity(client, stream_timeout)
            writer.write_stream(transport, response, client.stream_deadline,
                                stream[0], stream[1], client.parser.method == "HEAD", stream_timeout, client)
            keep_alive && stream[1]
          end
          if accepted
            handed_off = true
            return :async
          end
          body.close if body.respond_to?(:close)
          response = [503, {}, ["Service Unavailable"]]
        end
        chunks = writer.prepare(response, keep_alive, client.parser.protocol, client.parser.method == "HEAD")
      rescue StandardError => error
        warn "SPINNER_METRIC event=application_failure message=#{error.message}"
        response[2].close if response.is_a?(Array) && response.length == 3 && response[2].respond_to?(:close)
        response = [500, {}, ["Internal server error"]]
        chunks = writer.prepare(response, false, client.parser.protocol, client.parser.method == "HEAD")
        keep_alive = false
      end
      writer.write(transport, chunks, Transport.now + @write_timeout)
      client.trace[:response_write_done] = Transport.now if client.trace
      [((Transport.now - app_started) * 1000).round, keep_alive]
    rescue IOError, SystemCallError => error
      warn "SPINNER_METRIC event=transport_failure message=#{error.message}"
      nil
    ensure
      unless handed_off
        begin
          response[2].close if response.is_a?(Array) && response.length == 3 && response[2].respond_to?(:close)
        ensure
          client.cleanup_body
        end
      end
    end
  end

  class Server
    def initialize(application, host: "127.0.0.1", port: 4000, threads: 4,
                   queue_capacity: 64, max_connections: 128, queue_timeout: 5.0,
                   drain_timeout: 10.0, unix_path: nil, listener: nil,
                   keepalive_timeout: 5.0, max_requests_per_connection: 100,
                   worker_processes: 1, tls_cert: nil, tls_key: nil,
                   max_body_bytes: 1048576, body_memory_bytes: 65536,
                   spool_directory: nil, spool_budget_bytes: 134217728, storage_workers: 2,
                   header_timeout: 5.0, body_timeout: 5.0, write_timeout: 5.0,
                   stream_idle_timeout: 30.0, max_streams: 32, max_upgrades: 32,
                   trusted_proxies: [], max_header_bytes: 32768, reactor_heartbeat: nil,
                   request_metrics: nil)
      {"threads" => threads, "queue_capacity" => queue_capacity,
       "max_connections" => max_connections, "max_requests_per_connection" => max_requests_per_connection,
       "worker_processes" => worker_processes}.each do |name, value|
        raise ArgumentError, "#{name} must be a positive integer" unless value.is_a?(Integer) && value > 0
      end
      {"queue_timeout" => queue_timeout, "drain_timeout" => drain_timeout,
       "keepalive_timeout" => keepalive_timeout}.each do |name, value|
        raise ArgumentError, "#{name} must be positive and finite" unless value.is_a?(Numeric) && value > 0 && value.finite?
      end
      raise ArgumentError, "port must be between zero and 65535" unless port.is_a?(Integer) && port >= 0 && port <= 65535
      {"max_body_bytes" => max_body_bytes, "spool_budget_bytes" => spool_budget_bytes,
       "storage_workers" => storage_workers, "max_streams" => max_streams,
       "max_upgrades" => max_upgrades, "max_header_bytes" => max_header_bytes}.each do |name, value|
        raise ArgumentError, "#{name} must be a positive integer" unless value.is_a?(Integer) && value > 0
      end
      unless body_memory_bytes.is_a?(Integer) && body_memory_bytes >= 0 && body_memory_bytes <= max_body_bytes
        raise ArgumentError, "body_memory_bytes must be between zero and max_body_bytes"
      end
      {"header_timeout" => header_timeout, "body_timeout" => body_timeout,
       "write_timeout" => write_timeout, "stream_idle_timeout" => stream_idle_timeout}.each do |name, value|
        raise ArgumentError, "#{name} must be positive and finite" unless value.is_a?(Numeric) && value > 0 && value.finite?
      end
      @options = {max_body_bytes: max_body_bytes, body_memory_bytes: body_memory_bytes,
                  spool_directory: spool_directory || ENV["TMPDIR"] || "/tmp",
                  spool_budget_bytes: spool_budget_bytes, storage_workers: storage_workers,
                  stream_idle_timeout: stream_idle_timeout, max_streams: max_streams,
                  max_upgrades: max_upgrades, proxy_policy: ProxyMetadata.new(trusted_proxies),
                  reactor_heartbeat: reactor_heartbeat.nil? ? ENV.fetch("SPINNER_REACTOR_HEARTBEAT", "0") == "1" : reactor_heartbeat,
                  request_metrics: request_metrics.nil? ? ENV.fetch("SPINNER_REQUEST_METRICS", "0") == "1" : request_metrics}
      @header_limit = max_header_bytes
      @header_timeout = header_timeout
      @body_timeout = body_timeout
      @write_timeout = write_timeout
      @application = application
      @host = host
      @port = port
      @threads = threads
      @queue_capacity = queue_capacity
      @max_connections = max_connections
      @queue_timeout = queue_timeout
      @drain_timeout = drain_timeout
      @unix_path = unix_path
      @listener = listener
      @keepalive_timeout = keepalive_timeout
      @max_requests_per_connection = max_requests_per_connection
      @worker_processes = worker_processes
      @options[:spool_budget_bytes] = spool_budget_bytes / worker_processes
      @tls_cert = tls_cert
      @tls_key = tls_key
      raise ArgumentError, "tls_cert and tls_key must be supplied together" if @tls_cert.nil? != @tls_key.nil?
      raise ArgumentError, "TLS requires a TCP listener" if !@tls_cert.nil? && !@unix_path.nil?
      raise ArgumentError, "unix_path must be nonempty" if !@unix_path.nil? && @unix_path.empty?
      raise ArgumentError, "choose listener or unix_path" if !@listener.nil? && !@unix_path.nil?
      raise ArgumentError, "multi-process mode needs a TCP listener" if @worker_processes > 1 && (!@unix_path.nil? || !@listener.nil?)
    end

    def run
      if @worker_processes > 1 && ENV["SPINNER_CHILD_FD"].nil?
        run_supervisor
      else
        run_worker
      end
    end

    def run_worker
      require_relative "tls" unless @tls_cert.nil?
      inherited = ENV["SPINNER_CHILD_FD"]
      listener = if inherited.nil?
                   @listener || (@unix_path.nil? ? TCPServer.new(@host, @port) : UNIXServer.new(@unix_path))
                 else
                   TCPServer.for_fd(inherited.to_i)
                 end
      begin
        tls_context = @tls_cert.nil? ? nil : TLS::Context.new(@tls_cert, @tls_key)
        port = @unix_path.nil? ? listener.addr[1].to_s : "0"
        reactor = Reactor.new(listener, @application, port, @header_limit, @header_timeout, @body_timeout, @write_timeout,
                              @threads, @queue_capacity, @max_connections,
                              @queue_timeout, @drain_timeout,
                              @keepalive_timeout, @max_requests_per_connection,
                              tls_context, @options)
        previous_term = Signal.trap("TERM") { reactor.shutdown! }
        previous_int = Signal.trap("INT") { reactor.shutdown! }
        previous_usr1 = Signal.trap("USR1") { reactor.shutdown!(true) }
        # Emitted only after bind and pool startup.
        if inherited.nil?
          puts "SPINNER_READY #{Process.pid} #{port}"
          $stdout.flush
        end
        reactor.run
      ensure
        Signal.trap("TERM", previous_term) unless previous_term.nil?
        Signal.trap("INT", previous_int) unless previous_int.nil?
        Signal.trap("USR1", previous_usr1) unless previous_usr1.nil?
        listener.close unless listener.closed?
        tls_context.close unless tls_context.nil?
        File.unlink(@unix_path) if !@unix_path.nil? && File.socket?(@unix_path)
      end
    end

    def run_supervisor
      unless @tls_cert.nil?
        require_relative "tls"
        validation = TLS::Context.new(@tls_cert, @tls_key)
        validation.close
      end
      listener = TCPServer.new(@host, @port)
      listener.close_on_exec = false
      port = listener.addr[1]
      ENV["SPINNER_CHILD_FD"] = listener.fileno.to_s
      ENV["SPINNER_PARENT_PID"] = Process.pid.to_s
      children = []
      stopping = false
      failed = false
      previous_term = nil
      previous_int = nil
      previous_hup = nil
      restart_pending = []
      restarting_pid = nil
      begin
        @worker_processes.times { children << spawn_child }
        previous_term = Signal.trap("TERM") { stopping = true; signal_children(children, "TERM") }
        previous_int = Signal.trap("INT") { stopping = true; signal_children(children, "TERM") }
        previous_hup = Signal.trap("HUP") do
          if !stopping && restarting_pid.nil?
            restart_pending = children.dup
            restarting_pid = restart_pending.shift
            warn "SPINNER_METRIC event=roll_start pid=#{restarting_pid} pending=#{restart_pending.length}"
            signal_children([restarting_pid], "USR1") unless restarting_pid.nil?
          end
        end
        puts "SPINNER_READY #{Process.pid} #{port}"
        $stdout.flush
        restarts = []
        until children.empty?
          begin
            pid, _status = Process.waitpid2(-1)
          rescue Errno::EINTR
            next
          end
          children.delete(pid)
          Dir.glob(File.join(@options[:spool_directory], "spinner-#{pid}-*.body")).each do |path|
            begin
              File.unlink(path)
            rescue SystemCallError => error
              warn "Spinner spool cleanup: #{error.message}"
            end
          end
          restart_pending.delete(pid)
          warn "SPINNER_METRIC event=worker_exit pid=#{pid} remaining=#{children.length}"
          next if stopping
          if pid == restarting_pid
            warn "SPINNER_METRIC event=roll_exit pid=#{pid}"
            children << spawn_child
            restarting_pid = restart_pending.shift
            warn "SPINNER_METRIC event=roll_start pid=#{restarting_pid} pending=#{restart_pending.length}" unless restarting_pid.nil?
            signal_children([restarting_pid], "USR1") unless restarting_pid.nil?
            next
          end
          now = Transport.now
          restarts.reject! { |time| now - time > 10.0 }
          restarts << now
          if restarts.length > 5
            warn "Spinner supervisor: worker restart limit reached"
            failed = true
            stopping = true
            signal_children(children, "TERM")
          else
            warn "SPINNER_METRIC event=worker_replacement exited_pid=#{pid}"
            children << spawn_child
          end
        end
      ensure
        signal_children(children, "TERM")
        children.each do |pid|
          begin
            Process.waitpid(pid)
          rescue Errno::ECHILD
            nil
          end
        end
        Signal.trap("TERM", previous_term) unless previous_term.nil?
        Signal.trap("INT", previous_int) unless previous_int.nil?
        Signal.trap("HUP", previous_hup) unless previous_hup.nil?
        ENV.delete("SPINNER_CHILD_FD")
        ENV.delete("SPINNER_PARENT_PID")
        listener.close unless listener.closed?
      end
      raise "worker restart limit reached" if failed
    end

    def spawn_child
      pid = Process.spawn($PROGRAM_NAME)
      warn "SPINNER_METRIC event=worker_spawn pid=#{pid}"
      pid
    end

    def signal_children(children, signal)
      children.each do |pid|
        begin
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end
end
