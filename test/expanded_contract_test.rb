require_relative "test_helper"

class ExpandedContractTest < Minitest::Test
  include SpinnerTest::Wire

  def test_absolute_targets_options_and_repeated_fields
    with_server do |server|
      response = raw_request(server.port, "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      assert_equal(404, response.status) # OPTIONS dispatches; routing belongs to the application.
      response = raw_request(server.port, "GET http://localhost/env?q=1 HTTP/1.1\r\nHost: localhost:80\r\nX-Test: a\r\nX-Test: b\r\nConnection: close\r\n\r\n")
      assert_equal(200, response.status)
      assert_includes(response.body, "HTTP_X_TEST=a, b")
      assert_includes(response.body, "PATH_INFO=/env")
      assert_includes(response.body, "QUERY_STRING=q=1")
      assert_equal(400, raw_request(server.port, "GET http://evil.test/health HTTP/1.1\r\nHost: localhost\r\n\r\n").status)
    end
  end

  def test_spool_threshold_boundaries_for_both_framing_modes
    Dir.mktmpdir("spinner-boundaries-") do |directory|
      with_server("BODY_MEMORY_BYTES" => "64", "SPOOL_DIRECTORY" => directory) do |server|
        [63, 64, 65, 100_000].each do |size|
          bytes = "z" * size
          assert_response(request(server.port, method: "POST", path: "/consume", body: bytes), 200, size.to_s)
          chunked = "POST /consume HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n#{size.to_s(16)}\r\n#{bytes}\r\n0\r\n\r\n"
          assert_response(raw_request(server.port, chunked), 200, size.to_s)
          Timeout.timeout(2) { sleep 0.01 until Dir.empty?(directory) }
        end
        assert_includes(File.binread(server.log), "event=body_spill")
      end
    end
  end

  def test_budget_exhaustion_and_unavailable_directory_release_resources
    Dir.mktmpdir("spinner-budget-") do |directory|
      with_server("BODY_MEMORY_BYTES" => "64", "SPOOL_DIRECTORY" => directory,
                  "SPOOL_BUDGET_BYTES" => "100") do |server|
        assert_equal(503, request(server.port, method: "POST", path: "/consume", body: "x" * 101).status)
        assert_response(request(server.port, method: "POST", path: "/consume", body: "x" * 100), 200, "100")
        assert_response(request(server.port), 200, "OK")
        Timeout.timeout(2) { sleep 0.01 until Dir.empty?(directory) }
      end
      with_server("BODY_MEMORY_BYTES" => "64", "SPOOL_DIRECTORY" => File.join(directory, "absent")) do |server|
        assert_equal(503, request(server.port, method: "POST", path: "/consume", body: "x" * 100).status)
        assert_response(request(server.port), 200, "OK")
      end
    end
  end

  def test_partial_spool_is_private_and_removed_on_disconnect_and_timeout
    Dir.mktmpdir("spinner-partial-") do |directory|
      with_server("BODY_MEMORY_BYTES" => "64", "SPOOL_DIRECTORY" => directory,
                  "BODY_TIMEOUT" => "0.5") do |server|
        2.times do |index|
          tcp(server.port) do |socket|
            socket.write("POST /consume HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10000\r\n\r\n" + "x" * 1000)
            Timeout.timeout(2) { sleep 0.01 while Dir.empty?(directory) }
            assert_equal(0600, File.stat(File.join(directory, Dir.children(directory).first)).mode & 0777)
            if index.zero?
              socket.shutdown(Socket::SHUT_WR)
              assert_equal(400, read_response(socket).status)
            else
              assert_equal(408, read_response(socket).status)
            end
          end
          Timeout.timeout(2) { sleep 0.01 until Dir.empty?(directory) }
          assert_response(request(server.port), 200, "OK")
        end
      end
    end
  end

  def test_stream_pool_rejection_and_incremental_delivery_release_application_worker
    with_server("THREADS" => "1", "MAX_STREAMS" => "1") do |server|
      tcp(server.port) do |socket|
        socket.write("GET /long-events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        early = "".b
        Timeout.timeout(2) { early << socket.readpartial(1024) until early.include?("data: 0\n\n") }
        refute_includes(early, "data: 99\n\n")
        refute_includes(File.binread(server.log), "SPINNER_TEST_LONG_EVENTS_CLOSED")
        assert_response(request(server.port), 200, "OK")
        assert_equal(503, request(server.port, path: "/events").status)
        socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
      end
      Timeout.timeout(3) { sleep 0.025 until File.binread(server.log).include?("SPINNER_TEST_LONG_EVENTS_CLOSED") }
      assert_equal(200, request(server.port, path: "/events").status)
    end
  end

  def test_finite_stream_preserves_pipeline_and_head_does_not_enumerate
    with_server do |server|
      tcp(server.port) do |socket|
        socket.write("GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\nGET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        assert_equal("one\x00two".b, decoded_body(read_response(socket)))
        assert_response(read_response(socket), 200, "OK")
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal(200, request(server.port, method: "HEAD", path: "/slow-stream").status)
      assert_operator(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2)
    end
  end

  def test_malformed_forwarding_cannot_change_identity_or_scheme
    with_server("TRUST_PROXY" => "1") do |server|
      ["for=unknown;proto=https", "for=203.0.113.1;proto=ftp", "for=203.0.113.1;for=127.0.0.1;proto=https"].each do |value|
        response = request(server.port, path: "/env", headers: {"Forwarded" => value})
        assert_includes(response.body, "REMOTE_ADDR=127.0.0.1")
        assert_includes(response.body, "rack.url_scheme=http")
      end
      response = request(server.port, path: "/env", headers: {"Forwarded" => "for=192.0.2.9;proto=http, for=198.51.100.7;proto=https"})
      assert_includes(response.body, "REMOTE_ADDR=198.51.100.7")
      assert_includes(response.body, "rack.url_scheme=https")
    end
  end
end

class ExpandedContractTest
  def test_stream_error_closes_body_without_appending_an_http_error
    with_server do |server|
      tcp(server.port) do |socket|
        socket.write("GET /broken-stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        bytes = Timeout.timeout(3) { socket.read }
        assert_includes(bytes, "first")
        refute_includes(bytes, "500 Internal")
        assert_equal(1, bytes.scan("HTTP/1.1").length)
      end
      assert_includes(File.binread(server.log), "SPINNER_TEST_BROKEN_STREAM_CLOSED")
      assert_includes(File.binread(server.log), "event=stream_failure")
      assert_response(request(server.port), 200, "OK")
    end
  end

  def test_idle_stream_transport_closes_while_application_worker_remains_available
    with_server("THREADS" => "1", "STREAM_IDLE_TIMEOUT" => "0.2") do |server|
      tcp(server.port) do |socket|
        socket.write("GET /slow-stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        bytes = Timeout.timeout(2) { socket.read }
        assert_includes(bytes, "first")
        refute_includes(bytes, "second")
      end
      assert_response(request(server.port), 200, "OK")
    end
  end

  def test_shutdown_removes_partial_spools
    Dir.mktmpdir("spinner-shutdown-") do |directory|
      with_server("BODY_MEMORY_BYTES" => "64", "SPOOL_DIRECTORY" => directory,
                  "DRAIN_TIMEOUT" => "0.3") do |server|
        tcp(server.port) do |socket|
          socket.write("POST /consume HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10000\r\n\r\n" + "x" * 1000)
          Timeout.timeout(2) { sleep 0.01 while Dir.empty?(directory) }
          server.signal("TERM")
          Timeout.timeout(3) { sleep 0.025 while server.alive? }
          assert_empty(Dir.children(directory))
        end
      end
    end
  end
end
