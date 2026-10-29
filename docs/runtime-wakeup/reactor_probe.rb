# Diagnostic derived from spinner/test/fixtures/reactor_handoff.rb.
# Runs the real Spinner reactor over duplex pipes, without TCP or a listener.
# Compile and run instructions/results: README.md in this directory.
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
    # fragile sub-millisecond assertion. The probe overrides this below.
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


class HandoffReactor
  def poll_interval
    0.005
  end
end
class ProbeApplication
  def call(_env)
    [200, {"content-type" => "text/plain; charset=utf-8"}, ["OK\n"]]
  end
end
reactor = HandoffReactor.new(ProbeApplication.new, 20000)
client = attach_connection(reactor)
runner = Thread.new { reactor.run }
slow = 0
maximum = 0.0
begin
  9000.times do |index|
    started = Spinner::Transport.now
    client.write("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
    response = read_response(client)
    check(response.end_with?("OK\n"), "bad response")
    elapsed = (Spinner::Transport.now - started) * 1000.0
    maximum = elapsed if elapsed > maximum
    if elapsed > 20.0
      slow += 1
      puts "SLOW request=#{index + 1} elapsed_ms=#{elapsed}"
    end
  end
ensure
  reactor.stop_probe
  runner.join
  client.close
  reactor.close_listener
end
puts "PROBE requests=9000 slow=#{slow} max_ms=#{maximum}"
