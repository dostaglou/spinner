require "spinner"

# Unlike socket writes, a disconnected pipe can deliver SIGPIPE in Spinel.
# Turn that into EPIPE so the fixture exercises the normal transport-error path.
Signal.trap("PIPE", "IGNORE")

# Exercise the real parser, worker pool and reactor without binding a listener.
# Duplex pipes isolate handoff scheduling from TCP delayed-ACK behavior. The
# network suite separately exercises real sockets, TLS and transport backpressure.
class HandoffSocket < Spinner::TLS::Socket
  def initialize(reader, writer)
    super(reader, nil)
    @write_end = writer
  end

  def write_nonblock(bytes)
    @write_end.write_nonblock(bytes)
  end

  def write_stream_nonblock(bytes)
    @write_end.write_nonblock(bytes)
  end

  def write(bytes)
    count = write_nonblock(bytes)
    raise "short probe request write" unless count == bytes.bytesize
    count
  end

  def close
    @write_end.close unless @write_end.closed?
    super
  end
end

class HandoffClient < Spinner::PendingClient
  def pipe_writer=(writer)
    @socket = HandoffSocket.new(@socket.to_io, writer)
  end
end

class HandoffApplication
  attr_reader :entered, :release

  def initialize(kind)
    @kind = kind
    @calls = 0
    @entered = Queue.new
    @release = Queue.new
  end

  def call(_env)
    @calls += 1
    if @calls == 1
      return [200, {}, self] if @kind == "stream" || @kind == "broken_stream"
      wait_for_release
      raise "intentional application failure" if @kind == "failure"
    end
    [200, {}, ["OK"]]
  end

  def wait_for_release
    @entered << true
    @release.pop
  end

  def each
    wait_for_release
    raise "intentional stream failure" if @kind == "broken_stream"
    yield "OK"
  end

  def close
  end
end

class HandoffReactor < Spinner::Reactor
  attr_reader :selecting, :polls

  def initialize(application, limit = 100, capacity = 1)
    listener, @listener_writer = IO.pipe
    @selecting = Queue.new
    @polls = 0
    options = {storage_workers: 1, spool_budget_bytes: 1048576,
               max_body_bytes: 1048576, body_memory_bytes: 65536,
               spool_directory: ".", stream_idle_timeout: 5.0,
               max_streams: 2, max_upgrades: 2,
               proxy_policy: Spinner::ProxyMetadata.new([]),
               reactor_heartbeat: false, request_metrics: false}
    super(listener, application, "0", 32768, 5.0, 5.0, 5.0,
          2, 8, capacity, 5.0, 0.1, 5.0, limit, nil, options)
  end

  def attach(reader, writer)
    raise "capacity already full" unless @capacity.acquire
    @next_id += 1
    client = HandoffClient.new(reader, @port, @header_limit,
                               @read_timeout, @body_timeout, @write_timeout,
                               @capacity, @queue_timeout, @next_id,
                               @keepalive_timeout, @max_requests, nil, @options)
    client.pipe_writer = writer
    @clients << client
  end

  def poll_interval
    @polls += 1
    @selecting << true unless @queued.empty? && @pool.active_count == 0 && @pool.stream_count == 0
    # A long test-only interval makes a lost notification obvious without a
    # fragile sub-millisecond assertion. Production remains at 50 ms.
    1.0
  end

  def stop_probe(graceful = false)
    shutdown!(graceful)
    @wakeup.signal
  end

  def capacity_count
    @capacity.count
  end

  def prime_request
    read_client(@clients.first)
    check(!IO.select([@wakeup.reader], nil, nil, 2).nil?, "worker did not publish completion")
  end

  def wakeup_closed?
    @wakeup.reader.closed?
  end

  def close_listener
    @listener.close unless @listener.closed?
    @listener_writer.close unless @listener_writer.closed?
  end
end

def check(condition, message)
  raise message unless condition
end

def read_bytes(socket, count, deadline)
  bytes = "".b
  while bytes.bytesize < count
    begin
      bytes << socket.read_nonblock(count - bytes.bytesize)
    rescue IO::WaitReadable
      remaining = deadline - Spinner::Transport.now
      raise "response timed out" if remaining <= 0 || IO.select([socket.to_io], nil, nil, remaining).nil?
    end
  end
  bytes
end

def read_response(socket)
  deadline = Spinner::Transport.now + 2.0
  header = "".b
  until header.end_with?("\r\n\r\n")
    header << read_bytes(socket, 1, deadline)
    check(header.bytesize < 4096, "oversized header")
  end
  length = 0
  header.split("\r\n").each do |line|
    length = line.split(":", 2)[1].strip.to_i if line.start_with?("content-length:")
  end
  check(length <= 1024, "oversized body")
  body = "".b
  if header.include?("transfer-encoding: chunked")
    until body.end_with?("0\r\n\r\n")
      body << read_bytes(socket, 1, deadline)
      check(body.bytesize < 1024, "oversized stream")
    end
    check(body == "2\r\nOK\r\n0\r\n\r\n", "incorrect stream framing")
  else
    body = read_bytes(socket, length, deadline)
  end
  header + body
end

def request(close = false)
  "GET /health HTTP/1.1\r\nHost: localhost\r\n#{close ? "Connection: close\r\n" : ""}\r\n"
end

def attach_connection(reactor)
  server_input, client_output = IO.pipe
  client_input, server_output = IO.pipe
  reactor.attach(server_input, server_output)
  HandoffSocket.new(client_input, client_output)
end

def expect_eof(client)
  ready = IO.select([client.to_io], nil, nil, 1)
  check(!ready.nil?, "connection did not close")
  begin
    client.read_nonblock(1)
    raise "unexpected bytes after final response"
  rescue EOFError
    nil
  end
end

def exercise_handoff(kind, limit = 100)
  application = HandoffApplication.new(kind)
  reactor = HandoffReactor.new(application, limit)
  client = attach_connection(reactor)
  runner = Thread.new { reactor.run }
  begin
    bytes = request(kind == "close")
    bytes += request if kind == "pipeline"
    client.write(bytes)
    application.entered.pop
    reactor.selecting.pop
    # The worker is blocked on a queue, while the reactor is selecting with its
    # client socket absent. Release completion while select is sleeping.
    sleep 0.02
    before_polls = reactor.polls
    started = Spinner::Transport.now
    client.close if kind == "disconnect"
    application.release << true
    response = ""
    if kind == "broken_stream"
      begin
        read_response(client)
        raise "broken stream unexpectedly completed"
      rescue EOFError
        nil
      end
    elsif kind != "disconnect"
      response = read_response(client)
    end
    if ["close", "failure", "disconnect", "broken_stream"].include?(kind)
      if kind == "close" || kind == "failure"
        expected = kind == "failure" ? "500" : "200"
        check(response.start_with?("HTTP/1.1 #{expected}"), "wrong close response")
        expect_eof(client)
      end
      deadline = started + 0.5
      while reactor.polls == before_polls
        raise "capacity release did not wake reactor" if Spinner::Transport.now >= deadline
        sleep 0.001
      end
      check(reactor.capacity_count == 0, "capacity was not released")
    else
      check(response.start_with?("HTTP/1.1 200"), "wrong first response")
      client.write(request) unless kind == "pipeline"
      response = read_response(client)
      elapsed = Spinner::Transport.now - started
      check(response.end_with?("\r\n\r\nOK"), "wrong second response")
      check(elapsed < 0.5, "#{kind} handoff waited for polling: #{elapsed}s")
      # Cross the normal connection limit, or exercise a higher configured one.
      (limit - 2).times do
        client.write(request)
        response = read_response(client)
        check(response.end_with?("\r\n\r\nOK"), "serial response lost or duplicated")
      end
      check(response.include?("connection: close\r\n"), "request limit not enforced")
      expect_eof(client)
    end
    puts "SPINNER_HANDOFF_OK kind=#{kind} limit=#{limit}"
  ensure
    reactor.stop_probe unless reactor.wakeup_closed?
    runner.join
    client.close unless client.closed?
    reactor.close_listener
  end
  check(reactor.wakeup_closed?, "notifier leaked after shutdown")
  check(reactor.capacity_count == 0, "connection leaked after shutdown")
end

exercise_handoff("buffered")
exercise_handoff("buffered", 125)
exercise_handoff("stream", 5)
exercise_handoff("pipeline", 5)
exercise_handoff("close")
exercise_handoff("failure")
exercise_handoff("broken_stream")
exercise_handoff("disconnect")

def exercise_shutdown(graceful, finish, kind = "buffered")
  application = HandoffApplication.new(kind)
  reactor = HandoffReactor.new(application)
  client = attach_connection(reactor)
  runner = Thread.new { reactor.run }
  begin
    client.write(request)
    application.entered.pop
    reactor.selecting.pop
    reactor.stop_probe(graceful)
    if finish
      application.release << true
      expected = kind == "stream" ? "2\r\nOK\r\n0\r\n\r\n" : "\r\n\r\nOK"
      check(read_response(client).end_with?(expected), "shutdown lost active response")
    end
    check(!runner.join(3).nil?, "shutdown did not stop producers")
    check(reactor.wakeup_closed?, "shutdown leaked notifier")
    check(reactor.capacity_count == 0, "shutdown leaked active connection")
    if !finish && kind == "stream"
      # Streaming headers precede enumeration; forced shutdown truncates that
      # response instead of writing a successful chunk terminator.
      begin
        read_response(client)
        raise "forced shutdown incorrectly completed the stream"
      rescue EOFError
        nil
      end
    end
    expect_eof(client)
  ensure
    reactor.stop_probe unless reactor.wakeup_closed?
    runner.join
    client.close unless client.closed?
    reactor.close_listener
  end
end

exercise_shutdown(true, true)
exercise_shutdown(false, true)
exercise_shutdown(false, false)
exercise_shutdown(true, true, "stream")
exercise_shutdown(false, false, "stream")

# Publication before the reactor enters select must survive draining its token.
application = HandoffApplication.new("buffered")
application.release << true
reactor = HandoffReactor.new(application, 2)
client = attach_connection(reactor)
client.write(request)
reactor.prime_request
runner = Thread.new { reactor.run }
begin
  started = Spinner::Transport.now
  check(read_response(client).end_with?("\r\n\r\nOK"), "primed response missing")
  client.write(request)
  check(read_response(client).end_with?("\r\n\r\nOK"), "primed completion lost")
  check(Spinner::Transport.now - started < 0.5, "pre-select completion waited for polling")
  expect_eof(client)
ensure
  reactor.stop_probe unless reactor.wakeup_closed?
  runner.join
  client.close
  reactor.close_listener
end

# Concurrent completions must not be confused with notification byte counts.
application = HandoffApplication.new("buffered")
application.release << true
reactor = HandoffReactor.new(application, 2, 8)
clients = []
8.times { clients << attach_connection(reactor) }
runner = Thread.new { reactor.run }
begin
  2.times do
    clients.each { |client| client.write(request) }
    clients.each do |client|
      check(read_response(client).end_with?("\r\n\r\nOK"), "concurrent response lost")
    end
  end
  clients.each { |client| expect_eof(client) }
ensure
  reactor.stop_probe unless reactor.wakeup_closed?
  runner.join
  clients.each(&:close)
  reactor.close_listener
end
check(reactor.capacity_count == 0, "concurrent connections leaked")
check(reactor.wakeup_closed?, "concurrent notifier leaked")

# An idle reactor should remain asleep rather than spinning on a stale token.
idle = HandoffReactor.new(HandoffApplication.new("buffered"))
runner = Thread.new { idle.run }
begin
  sleep 0.1
  check(idle.polls <= 2, "idle reactor is spinning")
ensure
  idle.stop_probe
  runner.join
  idle.close_listener
end
check(idle.wakeup_closed?, "idle notifier leaked")
puts "SPINNER_REACTOR_HANDOFF_OK"
