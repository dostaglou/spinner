# frozen_string_literal: true

require_relative "../test_helper"

class SoakTest < Minitest::Test
  include SpinnerTest::Wire

  def test_repeated_connections_and_restart_remain_healthy
    with_server("WORKER_PROCESSES" => "2") do |server|
      1_000.times do |index|
        assert_response(request(server.port), 200, "OK")
        server.signal("HUP") if index == 500
      end
      assert(server.alive?)
    end
  end

  def test_file_descriptors_remain_bounded_after_connection_bursts
    with_server do |server|
      initial_fds = fd_count(server.pid)
      3.times do
        200.times { assert_response(request(server.port), 200, "OK") }
      end
      assert_operator(fd_count(server.pid), :<=, initial_fds + 8)
    end
  end

  def test_mixed_uploads_streams_and_disconnects
    with_server do |server|
      100.times do
        assert_response(request(server.port, method: "POST", path: "/echo", body: "x" * 4096),
                        200, "x" * 4096)
        assert_equal(200, request(server.port, path: "/stream").status)
        tcp(server.port) { |socket| socket.write("GET /health HTTP/1.1\r\nHost: localhost\r\n") }
      end
      assert_response(request(server.port), 200, "OK")
    end
  end

  private

  def fd_count(pid)
    path = "/proc/#{pid}/fd"
    return Dir.children(path).length if Dir.exist?(path)

    output, status = Open3.capture2("lsof", "-p", pid.to_s)
    raise "missing test prerequisite: /proc or lsof" unless status.success?

    output.lines.length - 1
  rescue Errno::ENOENT
    raise "missing test prerequisite: /proc or lsof"
  end
end

class SoakTest
  def test_large_incremental_upload_keeps_memory_and_descriptors_bounded
    Dir.mktmpdir("spinner-memory-") do |directory|
      with_server("MAX_BODY_BYTES" => "33554432", "BODY_MEMORY_BYTES" => "65536",
                  "BODY_TIMEOUT" => "30", "SPOOL_DIRECTORY" => directory) do |server|
        assert_response(request(server.port), 200, "OK")
        before_rss = resident_kib(server.pid)
        before_fds = fd_count(server.pid)
        size = 24 * 1024 * 1024
        tcp(server.port) do |socket|
          socket.write("POST /consume HTTP/1.1\r\nHost: localhost\r\nContent-Length: #{size}\r\nConnection: close\r\n\r\n")
          part = "x" * 65536
          (size / part.bytesize).times { socket.write(part) }
          assert_response(read_response(socket, timeout: 30), 200, size.to_s)
        end
        # A retained whole-body String would itself exceed this allowance.
        assert_operator(resident_kib(server.pid) - before_rss, :<, 16 * 1024)
        assert_operator(fd_count(server.pid), :<=, before_fds + 8)
        assert_empty(Dir.children(directory))
      end
    end
  end

  private

  def resident_kib(pid)
    output, status = Open3.capture2("ps", "-o", "rss=", "-p", pid.to_s)
    raise "cannot measure resident memory" unless status.success?
    Integer(output.strip)
  end
end
