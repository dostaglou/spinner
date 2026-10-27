# A minimal application compiled with the packaged Spinner gem. Keep this
# fixture free of Rack, Rails, and CRuby-only libraries.
require "spinner"
require "spinner/websocket"

class SpinnerTestStream
  def each
    yield "one\x00".b
    yield "two".b
  end

  def close
    warn "SPINNER_TEST_STREAM_CLOSED"
  end
end

class SpinnerTestEvents
  def each
    3.times do |index|
      yield "data: #{index}\n\n"
      sleep 0.05
    end
  end

  def close
    warn "SPINNER_TEST_EVENTS_CLOSED"
  end
end

class SpinnerTestBrokenStream
  def each
    yield "first"
    raise "stream failed"
  end

  def close
    warn "SPINNER_TEST_BROKEN_STREAM_CLOSED"
  end
end

class SpinnerTestSlowStream
  def each
    yield "first"
    sleep 6
    yield "second"
  end

  def close
    warn "SPINNER_TEST_SLOW_STREAM_CLOSED"
  end
end

class SpinnerTestLongEvents
  def each
    100.times do |index|
      yield "data: #{index}\n\n"
      sleep 0.05
    end
  end

  def close
    warn "SPINNER_TEST_LONG_EVENTS_CLOSED"
  end
end

class SpinnerTestWebSocket
  def call(session)
    message = session.read_message
    session.write_message(message[0], message[1])
    session.close
  end
end

class SpinnerTestWebSocketFrames
  def call(session)
    session.read_message
    [0, 125, 126, 248, 65_535, 65_536].each do |size|
      session.write_message(1, "x" * size)
    end
    session.write_message(2, "\x00\xff".b)
    session.read_message
  end
end

class SpinnerTestApplication
  def initialize
    @count = 0
  end

  def call(env)
    path = env["PATH_INFO"]
    if path == "/count"
      [200, {"content-type" => "text/plain"}, [@count.to_s]]
    else
      @count += 1
      respond(env, path)
    end
  end

  def respond(env, path)
    if path == "/health"
      [200, {"content-type" => "text/plain"}, ["OK"]]
    elsif path == "/echo"
      [200, {"content-type" => "application/octet-stream"}, [env["rack.input"].read]]
    elsif path == "/consume"
      size = 0
      while (part = env["rack.input"].read(4096))
        size += part.bytesize
      end
      [200, {}, [size.to_s]]
    elsif path == "/input"
      input = env["rack.input"]
      first = input.read(2)
      line = input.gets
      input.rewind
      [200, {"content-type" => "application/octet-stream"}, [first.to_s, "|", line.to_s, "|", input.read]]
    elsif path == "/env"
      keys = ["REQUEST_METHOD", "SCRIPT_NAME", "PATH_INFO", "QUERY_STRING",
              "SERVER_NAME", "SERVER_PORT", "SERVER_PROTOCOL", "rack.url_scheme",
              "REMOTE_ADDR", "HTTP_HOST", "CONTENT_TYPE", "CONTENT_LENGTH",
              "HTTP_X_TEST", "HTTP_FORWARDED", "HTTP_X_FORWARDED_FOR"]
      values = []
      keys.each { |key| values << "#{key}=#{env[key]}" }
      [200, {"content-type" => "text/plain"}, [values.join("\n")]]
    elsif path == "/stream"
      [200, {"content-type" => "application/octet-stream"}, SpinnerTestStream.new]
    elsif path == "/events"
      [200, {"content-type" => "text/event-stream", "cache-control" => "no-cache"}, SpinnerTestEvents.new]
    elsif path == "/broken-stream"
      [200, {}, SpinnerTestBrokenStream.new]
    elsif path == "/slow-stream"
      [200, {"content-type" => "text/plain"}, SpinnerTestSlowStream.new]
    elsif path == "/long-events"
      [200, {"content-type" => "text/event-stream"}, SpinnerTestLongEvents.new]
    elsif path == "/cookies"
      [200, {"content-type" => "text/plain", "set-cookie" => ["a=1; Path=/", "b=2; Path=/"]}, ["cookies"]]
    elsif path == "/empty204"
      [204, {}, []]
    elsif path == "/empty304"
      [304, {}, []]
    elsif path == "/sleep"
      sleep 0.5
      [200, {"content-type" => "text/plain"}, ["awake"]]
    elsif path == "/raise"
      raise "fixture error"
    elsif path == "/invalid"
      [200, {"bad\r\nheader" => "x"}, ["bad"]]
    elsif path == "/ws"
      [101, {"upgrade" => "websocket"}, SpinnerTestWebSocket.new]
    elsif path == "/ws-frames"
      [101, {"upgrade" => "websocket"}, SpinnerTestWebSocketFrames.new]
    else
      [404, {"content-type" => "text/plain"}, ["Not Found"]]
    end
  end
end

Spinner::Server.new(
  Spinner::WebSocket::Adapter.new(SpinnerTestApplication.new),
  host: ENV["HOST"] || "127.0.0.1",
  port: (ENV["PORT"] || "0").to_i,
  threads: (ENV["THREADS"] || "4").to_i,
  queue_capacity: (ENV["QUEUE_CAPACITY"] || "64").to_i,
  max_connections: (ENV["MAX_CONNECTIONS"] || "128").to_i,
  max_body_bytes: (ENV["MAX_BODY_BYTES"] || "1048576").to_i,
  body_memory_bytes: (ENV["BODY_MEMORY_BYTES"] || "65536").to_i,
  trusted_proxies: ENV["TRUST_PROXY"] == "1" ? ["127.0.0.1/32"] : [],
  stream_idle_timeout: (ENV["STREAM_IDLE_TIMEOUT"] || "30").to_f,
  drain_timeout: (ENV["DRAIN_TIMEOUT"] || "10").to_f,
  max_streams: (ENV["MAX_STREAMS"] || "32").to_i,
  max_upgrades: (ENV["MAX_UPGRADES"] || "32").to_i,
  spool_directory: ENV["SPOOL_DIRECTORY"],
  spool_budget_bytes: (ENV["SPOOL_BUDGET_BYTES"] || "134217728").to_i,
  header_timeout: (ENV["HEADER_TIMEOUT"] || "5").to_f,
  body_timeout: (ENV["BODY_TIMEOUT"] || "5").to_f,
  write_timeout: (ENV["WRITE_TIMEOUT"] || "5").to_f,
  unix_path: ENV["UNIX_PATH"],
  worker_processes: (ENV["WORKER_PROCESSES"] || "1").to_i,
  tls_cert: ENV["TLS_CERT"],
  tls_key: ENV["TLS_KEY"]
).run
