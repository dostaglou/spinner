# frozen_string_literal: true

require_relative "test_helper"
require "base64"

class ProxyTest < Minitest::Test
  include SpinnerTest::Wire
  include SpinnerTest::Certificates

  def test_nginx_http11_tls_to_http11_upstream_and_trusted_forwarding
    with_certificate do |cert, key|
      with_server("TRUST_PROXY" => "1") do |server|
        with_nginx(server.port, cert, key) do |proxy_port|
          tls_client(proxy_port, ca_file: cert, alpn: %w[h2 http/1.1]) do |socket|
            assert_equal("http/1.1", socket.alpn_protocol)
            socket.write("GET /env HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n" \
                         "Forwarded: for=203.0.113.9;proto=http\r\n\r\n")
            response = read_response(socket)
            assert_equal(200, response.status)
            assert_includes(response.body, "rack.url_scheme=https")
            assert_includes(response.body, "REMOTE_ADDR=127.0.0.1")
            assert_includes(response.body, "SERVER_PROTOCOL=HTTP/1.1")
          end
          tls_client(proxy_port, ca_file: cert) do |socket|
            socket.write("POST /echo HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n" \
                         "Content-Length: 5\r\n\r\na\x00bcd")
            assert_response(read_response(socket), 200, "a\x00bcd".b)
          end
        end
      end
    end
  end

  def test_nginx_forwards_sse_and_websocket_upgrade
    with_certificate do |cert, key|
      with_server("TRUST_PROXY" => "1") do |server|
        with_nginx(server.port, cert, key) do |proxy_port|
          tls_client(proxy_port, ca_file: cert) do |socket|
            socket.write("GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            events = read_response(socket)
            assert_equal(200, events.status)
            assert_includes(events.body, "data: 0\n\n")
            assert_includes(events.body, "data: 2\n\n")
          end
          tls_client(proxy_port, ca_file: cert) do |socket|
            token = Base64.strict_encode64("spinner-test-key")
            socket.write("GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" \
                         "Connection: Upgrade\r\nSec-WebSocket-Key: #{token}\r\n" \
                         "Sec-WebSocket-Version: 13\r\n\r\n")
            assert_equal(101, read_response(socket).status)
            socket.write([0x81, 0x82].pack("C*") + "abcd" + ["h".ord ^ "a".ord, "i".ord ^ "b".ord].pack("C*"))
            assert_equal("\x81\x02hi".b, Timeout.timeout(3) { socket.read(4) })
          end
        end
      end
    end
  end

  private

  def with_nginx(upstream, cert, key)
    raise "missing test prerequisite: nginx" unless ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |path|
      File.executable?(File.join(path, "nginx"))
    end

    directory = Dir.mktmpdir("spinner-nginx-")
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.addr[1]
    listener.close
    config = File.join(directory, "nginx.conf")
    File.write(config, <<~NGINX)
      worker_processes 1;
      pid #{directory}/nginx.pid;
      error_log #{directory}/error.log info;
      events { worker_connections 128; }
      http {
        access_log off;
        server {
          listen 127.0.0.1:#{port} ssl;
          ssl_certificate #{cert};
          ssl_certificate_key #{key};
          location / {
            proxy_pass http://127.0.0.1:#{upstream};
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header Forwarded "for=127.0.0.1;proto=https";
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $http_connection;
            proxy_buffering off;
          }
        }
      }
    NGINX
    log = File.open(File.join(directory, "stdout.log"), "wb")
    pid = Process.spawn("nginx", "-c", config, "-p", directory, "-g", "daemon off;", out: log, err: log)
    log.close
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      begin
        socket = Socket.tcp("127.0.0.1", port, connect_timeout: 0.2)
        socket.close
        break
      rescue Errno::ECONNREFUSED
        raise "nginx startup timeout: #{File.binread(File.join(directory, 'error.log'))}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.025
      end
    end
    yield port
  ensure
    if pid
      begin
        Process.kill("TERM", pid)
        Timeout.timeout(3) { Process.wait(pid) }
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
    FileUtils.remove_entry(directory) if directory && ENV["KEEP_SPINNER_TEST_ARTIFACTS"] != "1"
  end
end
