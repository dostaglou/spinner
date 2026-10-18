# frozen_string_literal: true

require_relative "test_helper"

class TlsTest < Minitest::Test
  include SpinnerTest::Wire
  include SpinnerTest::Certificates

  def test_tls12_tls13_verified_http11_and_alpn
    with_certificate do |cert, key|
      with_server("TLS_CERT" => cert, "TLS_KEY" => key) do |server|
        [OpenSSL::SSL::TLS1_2_VERSION, OpenSSL::SSL::TLS1_3_VERSION].each do |version|
          tls_client(server.port, ca_file: cert, alpn: %w[h2 http/1.1],
                     min_version: version, max_version: version) do |socket|
            assert_equal("http/1.1", socket.alpn_protocol)
            socket.write("GET /env HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            response = read_response(socket)
            assert_equal(200, response.status)
            assert_includes(response.body, "rack.url_scheme=https")
          end
        end
        tcp = Socket.tcp("127.0.0.1", server.port, connect_timeout: 2)
        context = OpenSSL::SSL::SSLContext.new
        context.verify_mode = OpenSSL::SSL::VERIFY_PEER
        context.ca_file = cert
        context.alpn_protocols = ["h2"]
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
        ssl.hostname = "localhost"
        assert_raises(OpenSSL::SSL::SSLError) { Timeout.timeout(3) { ssl.connect } }
        assert(server.alive?)
        ssl&.close
        tcp&.close
        tls_client(server.port, ca_file: cert) do |socket|
          socket.write("GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
          assert_response(read_response(socket), 200, "OK")
        end
      end
    end
  end

  def test_untrusted_certificate_is_rejected_by_client
    with_certificate do |cert, key|
      with_server("TLS_CERT" => cert, "TLS_KEY" => key) do |server|
        tcp = Socket.tcp("127.0.0.1", server.port, connect_timeout: 2)
        context = OpenSSL::SSL::SSLContext.new
        context.verify_mode = OpenSSL::SSL::VERIFY_PEER
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
        ssl.hostname = "localhost"
        assert_raises(OpenSSL::SSL::SSLError) { Timeout.timeout(3) { ssl.connect } }
        assert(server.alive?)
      ensure
        ssl&.close
        tcp&.close
      end
    end
  end

  def test_bad_credentials_fail_startup
    binary = SpinnerTest.build.binary
    with_certificate do |cert, _key|
      assert_raises(RuntimeError) { SpinnerTest::Server.new(binary, "TLS_CERT" => cert, "TLS_KEY" => cert) }
    end
  end

  def test_stalled_handshake_does_not_block_other_clients
    with_certificate do |cert, key|
      with_server("TLS_CERT" => cert, "TLS_KEY" => key) do |server|
        stalled = Socket.tcp("127.0.0.1", server.port, connect_timeout: 2)
        tls_client(server.port, ca_file: cert) do |socket|
          socket.write("GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
          assert_response(read_response(socket), 200, "OK")
        end
        assert(server.alive?)
      ensure
        stalled&.close
      end
    end
  end

  def test_rolling_restart_loads_replaced_certificate
    with_certificate do |cert, key|
      with_certificate do |replacement_cert, replacement_key|
        with_server("TLS_CERT" => cert, "TLS_KEY" => key, "WORKER_PROCESSES" => "2") do |server|
          original = nil
          tls_client(server.port, ca_file: cert) { |socket| original = socket.peer_cert.to_der }
          FileUtils.cp(replacement_cert, cert)
          FileUtils.cp(replacement_key, key)
          server.signal("HUP")
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
          loop do
            changed = false
            begin
              tls_client(server.port, ca_file: replacement_cert) do |socket|
                changed = socket.peer_cert.to_der != original
              end
            rescue OpenSSL::SSL::SSLError
              nil # A retiring worker can still present the old certificate.
            end
            break if changed

            assert_operator(Process.clock_gettime(Process::CLOCK_MONOTONIC), :<, deadline,
                            "replacement certificate was not loaded")
            sleep 0.1
          end
          assert(server.alive?)
        end
      end
    end
  end
end
