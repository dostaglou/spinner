# frozen_string_literal: true

require_relative "test_helper"
require "puma"

class HarnessTest < Minitest::Test
  include SpinnerTest::Wire

  def test_framed_response_keeps_pipelined_bytes
    left, right = UNIXSocket.pair
    right.write("HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nOK" \
                "HTTP/1.1 204 No Content\r\n\r\n")
    first = read_response(left)
    second = read_response(left)
    assert_response(first, 200, "OK")
    assert_response(second, 204, "")
  ensure
    left&.close
    right&.close
  end

  def test_chunk_framing_rejects_invalid_size
    assert_raises(RuntimeError) { chunked_end("x\r\n", 0) }
    assert_equal(12, chunked_end("2\r\nab\r\n0\r\n\r\n", 0))
  end

  def test_build_requires_packaged_native_server
    assert(File.file?(SpinnerTest.build.binary))
  end

  def test_owns_reference_process_and_reads_binary_wire_response
    fixture = File.join(__dir__, "fixtures", "reference_server.rb")
    server = SpinnerTest::Server.new([RbConfig.ruby, fixture])
    assert_response(request(server.port, method: "POST", path: "/echo", body: "a\x00b".b),
                    200, "a\x00b".b)
  ensure
    server&.stop(retain: !$!.nil?)
  end

  def test_puma_reference_listener_uses_same_wire_client
    puma = Puma::Server.new(->(_env) { [200, { "content-type" => "text/plain" }, ["OK"]] })
    puma.add_tcp_listener("127.0.0.1", 0)
    puma.run
    assert_response(request(puma.connected_ports.first), 200, "OK")
  ensure
    puma&.stop(true)
  end
end
