# frozen_string_literal: true

require_relative "test_helper"

class LifecycleTest < Minitest::Test
  include SpinnerTest::Wire

  def test_slow_client_does_not_block_other_requests
    with_server("THREADS" => "2") do |server|
      tcp(server.port) do |slow|
        slow.write("POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\npartial")
        assert_response(request(server.port), 200, "OK")
      end
    end
  end

  def test_worker_process_recovery_and_rolling_restart
    with_server("WORKER_PROCESSES" => "2") do |server|
      assert_response(request(server.port), 200, "OK")
      initial = worker_pids(server)
      Process.kill("KILL", initial.first)
      wait_workers(server) { |pids| pids.length == 2 && !pids.include?(initial.first) }
      recovered = worker_pids(server)
      assert_response(request(server.port), 200, "OK")
      server.signal("HUP")
      wait_workers(server) { |pids| pids.length == 2 && (pids & recovered).empty? }
      5.times do
        assert_response(request(server.port), 200, "OK")
        sleep 0.1
      end
      assert(server.alive?)
    end
  end

  def test_sigterm_drains_active_request
    with_server("THREADS" => "1") do |server|
      tcp(server.port) do |socket|
        socket.write("GET /sleep HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        sleep 0.1
        server.signal("TERM")
        assert_response(read_response(socket), 200, "awake")
      end
    end
  end

  def test_queue_pressure_returns_service_unavailable_then_recovers
    with_server("THREADS" => "1", "QUEUE_CAPACITY" => "1") do |server|
      clients = 8.times.map do
        Thread.new { request(server.port, path: "/sleep").status }
      end
      statuses = clients.map(&:value)
      assert_includes(statuses, 503)
      assert_includes(statuses, 200)
      assert_response(request(server.port), 200, "OK")
    end
  end

  def test_transport_failures_and_client_disconnects_do_not_kill_server
    with_server do |server|
      50.times do
        socket = Socket.tcp("127.0.0.1", server.port, connect_timeout: 2)
        socket.write("GET /health HTTP/1.1\r\nHost: localhost\r\n")
        socket.close
      end
      assert_response(request(server.port), 200, "OK")
      assert(server.alive?)
    end
  end

  def test_shutdown_closes_idle_and_partial_clients
    with_server do |server|
      idle = Socket.tcp("127.0.0.1", server.port, connect_timeout: 2)
      partial = Socket.tcp("127.0.0.1", server.port, connect_timeout: 2)
      partial.write("GET /health HTTP/1.1\r\nHost:")
      server.signal("TERM")
      [idle, partial].each do |socket|
        assert(IO.select([socket], nil, nil, 3), "shutdown left client open")
        begin
          assert_nil(socket.read_nonblock(1, exception: false))
        rescue Errno::ECONNRESET
          assert(true, "peer reset proves transport closure")
        end
      end
    ensure
      idle&.close
      partial&.close
    end
  end

  def test_shutdown_emits_structured_metrics
    with_server do |server|
      assert_response(request(server.port), 200, "OK")
      server.signal("TERM")
      Timeout.timeout(5) { sleep 0.025 while server.alive? }
      assert_match(/SPINNER_METRIC .*event=/, File.binread(server.log))
    end
  end

  def test_invalid_worker_configuration_fails_startup
    binary = SpinnerTest.build.binary
    error = assert_raises(RuntimeError) do
      SpinnerTest::Server.new(binary, "THREADS" => "0")
    end
    assert_match(/threads|positive/i, error.message)
  end
end

class LifecycleTest
  private

  def worker_pids(server)
    log = File.binread(server.log)
    spawned = log.scan(/event=worker_spawn pid=(\d+)/).flatten.map(&:to_i)
    exited = log.scan(/event=worker_exit pid=(\d+)/).flatten.map(&:to_i)
    spawned - exited
  end

  def wait_workers(server)
    Timeout.timeout(10) { sleep 0.025 until yield(worker_pids(server)) }
  end
end

class LifecycleTest
  def test_unexpected_parent_death_stops_worker_listeners
    with_server("WORKER_PROCESSES" => "2", "DRAIN_TIMEOUT" => "0.3") do |server|
      assert_response(request(server.port), 200, "OK")
      pids = worker_pids(server)
      assert_equal(2, pids.length)
      server.signal("KILL")
      Timeout.timeout(4) do
        sleep 0.025 until pids.all? { |pid| File.binread(server.log).include?("event=shutdown_complete pid=#{pid}") }
      end
      assert_raises(Errno::ECONNREFUSED) { Socket.tcp("127.0.0.1", server.port, connect_timeout: 1) }
    end
  end

  def test_restart_storm_stops_supervisor_after_limit
    with_server("WORKER_PROCESSES" => "2") do |server|
      6.times do
        pids = worker_pids(server)
        Process.kill("KILL", pids.first)
        Timeout.timeout(4) do
          sleep 0.025 until !server.alive? || !worker_pids(server).include?(pids.first)
        end
        break unless server.alive?
        wait_workers(server) { |workers| workers.length == 2 || !server.alive? }
      end
      Timeout.timeout(5) { sleep 0.025 while server.alive? }
      assert_includes(File.binread(server.log), "worker restart limit reached")
    end
  end

  def test_descriptor_exhaustion_recovers_after_clients_close
    server = SpinnerTest::Server.new(SpinnerTest.build.binary, {"MAX_CONNECTIONS" => "256"},
                                    launch_options: {rlimit_nofile: 64})
    sockets = []
    80.times { sockets << Socket.tcp("127.0.0.1", server.port, connect_timeout: 2) }
    Timeout.timeout(3) { sleep 0.025 until File.binread(server.log).include?("Spinner accept:") }
    sockets.each(&:close)
    sockets.clear
    Timeout.timeout(4) do
      loop do
        begin
          break if request(server.port).status == 200
        rescue IOError, SystemCallError, RuntimeError
          sleep 0.025
        end
      end
    end
    assert(server.alive?)
  ensure
    sockets&.each(&:close)
    server&.stop(retain: !$!.nil?)
  end
end
