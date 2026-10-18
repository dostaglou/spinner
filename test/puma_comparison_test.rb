# frozen_string_literal: true

require "puma"
require_relative "test_helper"

class PumaComparisonTest < Minitest::Test
  include SpinnerTest::Wire

  def test_shared_valid_http11_response_contract
    with_server do |spinner|
      app = lambda do |env|
        if env["PATH_INFO"] == "/echo"
          [200, { "content-type" => "application/octet-stream" }, [env["rack.input"].read]]
        else
          [200, { "content-type" => "text/plain" }, ["OK"]]
        end
      end
      puma = Puma::Server.new(app)
      puma.add_tcp_listener("127.0.0.1", 0)
      puma.run
      port = puma.connected_ports.first
      [
        { method: "GET", path: "/health", body: "".b },
        { method: "POST", path: "/echo", body: "a\x00\xff".b },
        { method: "PATCH", path: "/echo", body: "hello".b }
      ].each do |exchange|
        reference = request(port, **exchange)
        candidate = request(spinner.port, **exchange)
        assert_equal(reference.status, candidate.status)
        assert_equal(reference.header("content-type"), candidate.header("content-type"))
        assert_equal(reference.body.b, candidate.body.b)
      end
    ensure
      puma&.stop(true)
    end
  end
end
