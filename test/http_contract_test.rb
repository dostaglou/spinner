# frozen_string_literal: true

require_relative "test_helper"

class HttpContractTest < Minitest::Test
  include SpinnerTest::Wire

  def test_methods_path_query_and_environment
    with_server do |server|
      %w[GET HEAD POST PUT PATCH DELETE].each do |method|
        response = request(server.port, method: method, path: "/env?q=a%2Fb",
                           headers: { "X-Test" => "hello", "Content-Type" => "text/plain" })
        assert_equal(200, response.status)
        next if method == "HEAD"

        assert_includes(response.body, "REQUEST_METHOD=#{method}")
        assert_includes(response.body, "PATH_INFO=/env")
        assert_includes(response.body, "QUERY_STRING=q=a%2Fb")
        assert_includes(response.body, "SERVER_PROTOCOL=HTTP/1.1")
        assert_includes(response.body, "HTTP_X_TEST=hello")
        assert_includes(response.body, "CONTENT_TYPE=text/plain")
        assert_match(/REMOTE_ADDR=127\.0\.0\.1/, response.body)
      end
    end
  end

  def test_binary_bodies_and_io_compatible_reads
    with_server do |server|
      bytes = "a\x00\xff\xe3\x81\x82".b
      assert_response(request(server.port, method: "POST", path: "/echo", body: bytes), 200, bytes)
      assert_response(request(server.port, method: "PUT", path: "/input", body: "abline\nrest"),
                      200, "ab|line\n|abline\nrest")
    end
  end

  def test_large_upload_spools_with_configurable_limit
    directory = Dir.mktmpdir("spinner-upload-")
    with_server("MAX_BODY_BYTES" => "2097152", "BODY_MEMORY_BYTES" => "32768", "TMPDIR" => directory) do |server|
      body = "x" * 1_300_000
      assert_response(request(server.port, method: "POST", path: "/echo", body: body), 200, body)
      assert_equal(413, raw_request(server.port,
                                    "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2097153\r\n\r\n").status)
      assert_response(request(server.port), 200, "OK")
      assert_empty(Dir.children(directory), "upload spool was not removed")
    end
  ensure
    FileUtils.remove_entry(directory) if directory
  end

  def test_response_headers_statuses_head_and_errors
    with_server do |server|
      assert_response(request(server.port), 200, "OK")
      cookies = request(server.port, path: "/cookies")
      assert_equal(["a=1; Path=/", "b=2; Path=/"], cookies.header("set-cookie"))
      %w[empty204 empty304].each do |path|
        response = request(server.port, path: "/#{path}")
        assert_equal(path[-3, 3].to_i, response.status)
        assert_empty(response.body)
        assert_empty(response.header("content-length"))
      end
      assert_equal(200, request(server.port, method: "HEAD").status)
      head_stream = request(server.port, method: "HEAD", path: "/stream")
      assert_equal(200, head_stream.status)
      assert_empty(head_stream.body)
      assert_equal(500, request(server.port, path: "/raise").status)
      assert_equal(500, request(server.port, path: "/invalid").status)
      assert_response(request(server.port), 200, "OK")
    end
  end

  def test_keep_alive_pipelining_and_close
    with_server do |server|
      tcp(server.port) do |socket|
        socket.write("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n" \
                     "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        assert_response(read_response(socket), 200, "OK")
        assert_response(read_response(socket), 200, "OK")
        assert_equal("close", read_response_close(socket))
      end
    end
  end

  def test_http10_close_and_opt_in_keep_alive
    with_server do |server|
      first = raw_request(server.port, "GET /health HTTP/1.0\r\n\r\n")
      assert_equal("HTTP/1.0", first.version)
      assert_equal(["close"], first.header("connection"))
      tcp(server.port) do |socket|
        socket.write("GET /health HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
        assert_response(read_response(socket), 200, "OK")
        socket.write("GET /health HTTP/1.0\r\nConnection: close\r\n\r\n")
        assert_response(read_response(socket), 200, "OK")
      end
    end
  end

  def test_streaming_sse_and_cleanup
    with_server do |server|
      stream = request(server.port, path: "/stream")
      assert_equal(200, stream.status)
      assert_equal(["chunked"], stream.header("transfer-encoding"))
      assert_equal("one\x00two".b, decoded_body(stream))
      events = request(server.port, path: "/events")
      assert_equal(["text/event-stream"], events.header("content-type"))
      assert_equal("data: 0\n\ndata: 1\n\ndata: 2\n\n", decoded_body(events))
      logs = File.binread(server.log)
      assert_includes(logs, "SPINNER_TEST_STREAM_CLOSED")
      assert_includes(logs, "SPINNER_TEST_EVENTS_CLOSED")
    end
  end

  def test_configured_stream_idle_timeout_allows_long_lived_output
    with_server("STREAM_IDLE_TIMEOUT" => "10") do |server|
      tcp(server.port) do |socket|
        socket.write("GET /slow-stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        response = read_response(socket, timeout: 9)
        assert_equal(200, response.status)
        assert_includes(response.body, "first")
        assert_includes(response.body, "second")
      end
      assert_includes(File.binread(server.log), "SPINNER_TEST_SLOW_STREAM_CLOSED")
    end
  end

  def test_sse_disconnect_closes_body_and_releases_worker
    with_server do |server|
      socket = Socket.tcp("127.0.0.1", server.port, connect_timeout: 2)
      socket.write("GET /long-events HTTP/1.1\r\nHost: localhost\r\n\r\n")
      assert(IO.select([socket], nil, nil, 2))
      socket.readpartial(1024)
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
      socket.close
      Timeout.timeout(3) do
        sleep 0.025 until File.binread(server.log).include?("SPINNER_TEST_LONG_EVENTS_CLOSED")
      end
      assert_response(request(server.port), 200, "OK")
    ensure
      socket&.close
    end
  end

  def test_host_validation_and_proxy_trust
    with_server do |server|
      raw = "GET /env HTTP/1.1\r\nHost: Example.COM:9000\r\n" \
            "Forwarded: for=198.51.100.7;proto=https\r\n\r\n"
      response = raw_request(server.port, raw)
      assert_includes(response.body, "SERVER_NAME=Example.COM")
      assert_includes(response.body, "rack.url_scheme=http")
      assert_includes(response.body, "REMOTE_ADDR=127.0.0.1")
      ipv6 = raw_request(server.port, "GET /env HTTP/1.1\r\nHost: [::1]:9000\r\n\r\n")
      assert_includes(ipv6.body, "SERVER_NAME=[::1]")
    end
    with_server("TRUST_PROXY" => "1") do |server|
      raw = "GET /env HTTP/1.1\r\nHost: Example.COM\r\n" \
            "Forwarded: for=198.51.100.7;proto=https\r\n\r\n"
      response = raw_request(server.port, raw)
      assert_includes(response.body, "rack.url_scheme=https")
      assert_includes(response.body, "REMOTE_ADDR=198.51.100.7")
    end
  end

  def test_unix_socket_serves_and_unlinks
    directory = Dir.mktmpdir("spinner-unix-")
    path = File.join(directory, "server.sock")
    socket = nil
    with_server("UNIX_PATH" => path) do
      socket = UNIXSocket.new(path)
      socket.write("GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      assert_response(read_response(socket), 200, "OK")
      socket.close
    end
    refute(File.exist?(path), "Unix socket remained after shutdown")
  ensure
    socket&.close
    FileUtils.remove_entry(directory) if directory
  end

  private

  def read_response_close(socket)
    IO.select([socket], nil, nil, 2) && socket.read_nonblock(1, exception: false).nil? ? "close" : "open"
  end
end
