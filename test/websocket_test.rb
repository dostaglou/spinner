# frozen_string_literal: true

require "base64"
require "digest/sha1"
require_relative "test_helper"

class WebSocketTest < Minitest::Test
  include SpinnerTest::Wire

  def test_upgrade_echo_ping_and_close
    with_server do |server|
      tcp(server.port) do |socket|
        response, key = handshake(socket)
        assert_equal(101, response.status)
        expected = Base64.strict_encode64(Digest::SHA1.digest(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
        assert_equal([expected], response.header("sec-websocket-accept"))
        socket.write(masked_frame("p", 9))
        assert_equal([10, "p"], read_frame(socket))
        socket.write(masked_frame("he", 1, false))
        socket.write(masked_frame("llo", 0))
        assert_equal([1, "hello"], read_frame(socket))
        assert_equal(8, read_frame(socket)[0])
      end
      assert_response(request(server.port), 200, "OK")
    end
  end

  def test_binary_message_preserves_opcode_and_bytes
    with_server do |server|
      tcp(server.port) do |socket|
        assert_equal(101, handshake(socket).first.status)
        socket.write(masked_frame("a\x00\xff".b, 2))
        assert_equal([2, "a\x00\xff".b], read_frame(socket))
      end
    end
  end

  def test_native_outbound_frame_lengths_ping_pong_and_clean_close
    with_server do |server|
      tcp(server.port) do |socket|
        assert_equal(101, handshake(socket, "/ws-frames").first.status)
        socket.write(masked_frame("start"))
        [0, 125, 126, 248, 65_535, 65_536].each do |size|
          assert_equal([1, "x" * size], read_frame(socket))
        end
        assert_equal([2, "\x00\xff".b], read_frame(socket))
        socket.write(masked_frame("p", 9))
        assert_equal([10, "p"], read_frame(socket))
        socket.write(masked_frame([1000].pack("n"), 8))
        assert_equal([8, [1000].pack("n")], read_frame(socket))
      end
    end
  end

  def test_invalid_upgrade_key_does_not_dispatch
    with_server do |server|
      before = request(server.port, path: "/count").body.to_i
      response = raw_request(server.port,
                             "GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" \
                             "Connection: Upgrade\r\nSec-WebSocket-Key: invalid\r\n" \
                             "Sec-WebSocket-Version: 13\r\n\r\n")
      assert_equal(400, response.status)
      assert_equal(before, request(server.port, path: "/count").body.to_i)
    end
  end

  def test_unmasked_client_frame_is_rejected_without_echo
    with_server do |server|
      tcp(server.port) do |socket|
        assert_equal(101, handshake(socket).first.status)
        socket.write("\x81\x02hi".b)
        assert(IO.select([socket], nil, nil, 3), "unmasked frame was not rejected")
        result = socket.read_nonblock(32, exception: false)
        if result.is_a?(String) && result.bytesize >= 4
          refute_equal("\x81\x02hi".b, result.byteslice(0, 4))
        else
          assert_nil(result)
        end
      end
      assert_response(request(server.port), 200, "OK")
    end
  end

  private

  def handshake(socket, path = "/ws")
    key = Base64.strict_encode64("spinner-test-key")
    socket.write("GET #{path} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" \
                 "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\n" \
                 "Sec-WebSocket-Version: 13\r\n\r\n")
    [read_response(socket), key]
  end

  def masked_frame(payload, opcode = 1, fin = true)
    mask = "abcd".b
    bytes = payload.b.bytes.each_with_index.map { |byte, index| byte ^ mask.getbyte(index % 4) }.pack("C*")
    [(fin ? 0x80 : 0) | opcode, 0x80 | payload.bytesize].pack("C*") + mask + bytes
  end

  def read_frame(socket)
    Timeout.timeout(3) do
      head = socket.read(2)
      raise "closed before WebSocket frame" unless head&.bytesize == 2

      length = head.getbyte(1) & 0x7f
      length = socket.read(2).unpack1("n") if length == 126
      length = socket.read(8).unpack1("Q>") if length == 127

      [head.getbyte(0) & 0x0f, socket.read(length)]
    end
  end
end

class WebSocketTest
  def test_upgrade_limit_and_shutdown_accounting
    with_server("MAX_UPGRADES" => "1", "DRAIN_TIMEOUT" => "0.3") do |server|
      tcp(server.port) do |socket|
        assert_equal(101, handshake(socket).first.status)
        tcp(server.port) { |second| assert_equal(503, handshake(second).first.status) }
        assert_response(request(server.port), 200, "OK")
        server.signal("TERM")
        assert(IO.select([socket], nil, nil, 2), "upgrade survived shutdown deadline")
        assert_nil(socket.read_nonblock(1, exception: false))
      end
      assert_includes(File.binread(server.log), "upgrades=1")
    end
  end

  def test_peer_close_handshake_is_echoed
    with_server do |server|
      tcp(server.port) do |socket|
        assert_equal(101, handshake(socket).first.status)
        socket.write(masked_frame([1000].pack("n"), 8))
        assert_equal([8, [1000].pack("n")], read_frame(socket))
      end
      assert_response(request(server.port), 200, "OK")
    end
  end

  def test_oversized_frame_is_rejected_before_payload_arrives
    with_server do |server|
      tcp(server.port) do |socket|
        assert_equal(101, handshake(socket).first.status)
        socket.write([0x82, 0xff, 0, 0, 0, 0, 0, 0x10, 0, 1].pack("C*"))
        opcode, bytes = read_frame(socket)
        assert_equal(8, opcode)
        assert_equal(1009, bytes.unpack1("n"))
      end
      assert_response(request(server.port), 200, "OK")
    end
  end
end
