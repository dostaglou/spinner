# frozen_string_literal: true

require_relative "test_helper"

class HttpSecurityTest < Minitest::Test
  include SpinnerTest::Wire

  def test_rejects_ambiguous_framing_without_dispatch
    with_server do |server|
      initial = request(server.port, path: "/count").body.to_i
      cases = [
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\na",
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1, 1\r\n\r\na",
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip\r\n\r\n",
        "GET /echo HTTP/1.1\r\nHost: localhost\r\nX-Trace: a\r\nX_Trace: b\r\n\r\n",
        "GET /echo HTTP/1.1\r\nHost: localhost\r\nContent_Type: a\r\n\r\n"
      ]
      cases.each { |bytes| assert_equal(400, raw_request(server.port, bytes).status) }
      assert_equal(initial, request(server.port, path: "/count").body.to_i)
      assert_response(request(server.port), 200, "OK")
    end
  end

  def test_chunked_upload_fragmentation_and_pipeline_boundary
    with_server do |server|
      tcp(server.port) do |socket|
        socket.write("POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n")
        ["3\r\n", "a\x00", "b\r\n", "0\r\n\r\n"].each { |part| socket.write(part) }
        socket.write("GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        assert_response(read_response(socket), 200, "a\x00b".b)
        assert_response(read_response(socket), 200, "OK")
      end
    end
  end

  def test_expect_continue_and_unsupported_expectation
    with_server do |server|
      tcp(server.port) do |socket|
        socket.write("POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
        assert_equal(100, read_response(socket).status)
        socket.write("abc")
        assert_response(read_response(socket), 200, "abc")
      end
      assert_equal(417, raw_request(server.port,
                                    "POST /echo HTTP/1.1\r\nHost: localhost\r\nExpect: nonsense\r\n\r\n").status)
    end
  end

  def test_limits_methods_and_recovery
    with_server do |server|
      assert_equal(431, raw_request(server.port,
                                    "GET /health HTTP/1.1\r\nHost: localhost\r\nX-Large: #{'x' * 33_000}\r\n\r\n").status)
      assert_equal(413, raw_request(server.port,
                                    "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048577\r\n\r\n").status)
      assert_equal(405, raw_request(server.port,
                                    "TRACE /health HTTP/1.1\r\nHost: localhost\r\n\r\n").status)
      assert_equal(405, raw_request(server.port,
                                    "CONNECT localhost:443 HTTP/1.1\r\nHost: localhost:443\r\n\r\n").status)
      assert_equal(400, raw_request(server.port,
                                    "GET /health HTTP/1.1\r\n\r\n").status)
      assert_response(request(server.port), 200, "OK")
    end
  end

  def test_malformed_request_lines_hosts_and_header_syntax
    with_server do |server|
      malformed = [
        "GET /health\r\nHost: localhost\r\n\r\n",
        "GET /health HTTP/1.1\r\nHost: localhost\r\nBadHeader\r\n\r\n",
        "GET /health HTTP/1.1\r\nHost: localhost\r\nX-Test: a\r\n b\r\n\r\n",
        "GET /health HTTP/1.1\r\nHost: localhost\r\nHost: example.com\r\n\r\n",
        "GET /health HTTP/1.1\r\nHost: bad host\r\n\r\n",
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 999999999999999999999999\r\n\r\n"
      ]
      malformed.each do |bytes|
        status = raw_request(server.port, bytes).status
        assert_includes([400, 413], status)
      end
      assert_response(request(server.port), 200, "OK")
    end
  end

  def test_tls_and_plaintext_ports_do_not_confuse_protocols
    with_server do |server|
      assert_response(request(server.port), 200, "OK")
      before = request(server.port, path: "/count").body.to_i
      tcp(server.port) do |socket|
        socket.write("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
        assert(IO.select([socket], nil, nil, 3), "unsupported protocol did not close")
        bytes = socket.read_nonblock(1024, exception: false)
        assert(bytes.nil? || bytes.start_with?("HTTP/1.1 400", "HTTP/1.1 505"))
      end
      assert_equal(before, request(server.port, path: "/count").body.to_i)
      assert_response(request(server.port), 200, "OK")
    end
  end

  def test_malformed_chunks_and_truncated_bodies_never_dispatch
    with_server do |server|
      before = request(server.port, path: "/count").body.to_i
      ["z\r\n", "1\r\nxX\r\n0\r\n\r\n", "0\r\nX-Trailer: a\r\n\r\n"].each do |ending|
        assert_equal(400, raw_request(server.port,
                                      "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" + ending).status)
      end
      tcp(server.port) do |socket|
        socket.write("POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nabc")
        socket.shutdown(Socket::SHUT_WR)
        assert_equal(400, read_response(socket).status)
      end
      assert_equal(before, request(server.port, path: "/count").body.to_i)
    end
  end

  def test_header_and_body_deadlines_close_stalled_clients
    with_server do |server|
      tcp(server.port) do |socket|
        socket.write("GET /health HTTP/1.1\r\nHost: localhost\r\nX-Slow:")
        assert_equal(408, read_response(socket, timeout: 7).status)
      end
      tcp(server.port) do |socket|
        socket.write("POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\na")
        assert_equal(408, read_response(socket, timeout: 7).status)
      end
      assert_response(request(server.port), 200, "OK")
    end
  end
end
