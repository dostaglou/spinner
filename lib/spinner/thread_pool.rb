module Spinner
  class Capacity
    def initialize(maximum)
      @maximum = maximum
      @count = 0
      @lock = Mutex.new
    end

    def acquire
      @lock.synchronize do
        return false if @count >= @maximum
        @count += 1
        true
      end
    end

    def release
      @lock.synchronize { @count -= 1 }
    end

    def count
      @lock.synchronize { @count }
    end

    def full?
      count >= @maximum
    end
  end

  class ThreadPool
    def initialize(application, size, capacity, header_limit, read_timeout, write_timeout, body_timeout, port, connections, options, wakeup)
      @options = options
      @wakeup = wakeup
      @streams = TaskPool.new(options[:max_streams])
      @upgrades = TaskPool.new(options[:max_upgrades])
      @async_clients = []
      @capacity = capacity
      @connections = connections
      @queue = []
      @completed = []
      @active = {}
      @lock = Mutex.new
      @ready = ConditionVariable.new
      @stopping = false
      @stop_deadline = nil
      @workers = []
      begin
        size.times do
          @workers << spawn_worker(application, header_limit, read_timeout,
                                   write_timeout, body_timeout, port)
        end
      rescue Exception # rubocop:disable Lint/RescueException -- do not leave producers alive after interrupted startup
        stop
        raise
      end
    end

    def spawn_worker(application, header_limit, read_timeout, write_timeout, body_timeout, port)
      Thread.new do
        connection = Connection.new(application, header_limit, read_timeout,
                                    write_timeout, body_timeout, port)
        loop do
          client = take
          break if client.nil?
          if @options[:request_metrics]
            warn "SPINNER_METRIC event=start id=#{client.id} queue_wait_ms=#{client.queue_wait_ms} active=#{active_count} queued=#{queued_count} connections=#{@connections.count}"
          end
          app_ms = nil
          reuse = false
          result = nil
          begin
            reuse = client.keep_alive?
            result = connection.serve_buffered(client, method(:execute_async), @options[:stream_idle_timeout])
            unless result.nil? || result == :async
              app_ms = result[0]
              reuse = result[1]
            end
            warn "SPINNER_METRIC event=finish id=#{client.id} app_ms=#{app_ms}" if @options[:request_metrics]
          ensure
            @lock.synchronize { @active.delete(Thread.current) }
            complete(client, !app_ms.nil? && reuse) unless result == :async
          end
        end
      end
    end

    def execute_async(kind, client, body, &work)
      pool = kind == :upgrade ? @upgrades : @streams
      @lock.synchronize do
        client.stream_deadline = Transport.now + @options[:stream_idle_timeout]
        @async_clients << client
      end
      cancelled = proc do
        begin
          body.close if body.respond_to?(:close)
        ensure
          begin
            client.cleanup_body
          ensure
            @lock.synchronize { @async_clients.delete(client) }
            complete(client, false)
          end
        end
      end
      accepted = pool.submit(cancelled) do
        reuse = false
        begin
          warn "SPINNER_METRIC event=#{kind}_start id=#{client.id}" if @options[:request_metrics]
          reuse = work.call
        rescue IOError, SystemCallError => error
          warn "SPINNER_METRIC event=transport_failure message=#{error.message}"
        rescue StandardError => error
          warn "SPINNER_METRIC event=stream_failure message=#{error.message}"
        ensure
          cleaned = false
          begin
            client.cleanup_body
            cleaned = true
          ensure
            @lock.synchronize do
              @async_clients.delete(client)
              client.stream_deadline = nil
            end
            complete(client, reuse && cleaned)
          end
          warn "SPINNER_METRIC event=#{kind}_finish id=#{client.id}" if @options[:request_metrics]
        end
      end
      unless accepted
        @lock.synchronize { @async_clients.delete(client) }
        warn "SPINNER_METRIC event=rejected kind=#{kind} id=#{client.id}"
      end
      accepted
    end

    def complete(client, reuse)
      retained = @lock.synchronize do
        if reuse && !client.closed? && !@stopping
          @completed << client
          true
        else
          false
        end
      end
      client.close unless retained
    ensure
      # Publish before signaling, outside the pool lock. Closures also wake the
      # reactor: it may have excluded the listener while capacity was full.
      @wakeup.signal
    end

    def enqueue(client)
      @lock.synchronize do
        return false if @stopping || @queue.length >= @capacity
        client.queued!
        @queue << client
        @ready.signal
        true
      end
    end

    def take
      @lock.synchronize do
        @ready.wait(@lock) while @queue.empty? && !@stopping
        return nil if @queue.empty?
        return nil if !@stop_deadline.nil? && Transport.now >= @stop_deadline
        client = @queue.shift
        client.claim!
        @active[Thread.current] = client
        client
      end
    end

    def queued?(client)
      @lock.synchronize { @queue.include?(client) }
    end

    def cancel(client)
      @lock.synchronize { !@queue.delete(client).nil? }
    end

    def stream_count
      @streams.count
    end

    def upgrade_count
      @upgrades.count
    end

    def active_count
      @lock.synchronize { @active.length }
    end

    def queued_count
      @lock.synchronize { @queue.length }
    end

    def completed
      @lock.synchronize do
        result = @completed
        @completed = []
        result
      end
    end

    def request_stop(deadline = nil)
      @lock.synchronize do
        @stopping = true
        @stop_deadline = deadline unless deadline.nil?
        @ready.broadcast
      end
    end

    def expire_async
      @lock.synchronize { @async_clients.each { |client| client.expire_stream(Transport.now) } }
    end

    def maintain(application, header_limit, read_timeout, write_timeout, body_timeout, port)
      return if @stopping
      @workers.each_with_index do |worker, index|
        next if worker.alive?
        begin
          worker.join
        rescue Exception => error
          warn "Spinner worker: #{error.message}"
        end
        @workers[index] = spawn_worker(application, header_limit, read_timeout,
                                        write_timeout, body_timeout, port)
      end
    end

    def stop
      request_stop
      begin
        @lock.synchronize { @async_clients.each(&:close) }
      ensure
        begin
          @streams.stop
        ensure
          begin
            @upgrades.stop
          ensure
            stop_workers
          end
        end
      end
    end

    def stop_workers
      @workers.each(&:kill)
      @workers.each do |worker|
        begin
          worker.join
        rescue Exception => error
          warn "Spinner worker: #{error.message}"
        end
      end
    end
  end
end
