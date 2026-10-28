# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/spinner"

class ProxyMetadataUnitTest < Minitest::Test
  def test_bracketed_ipv6_with_and_without_port
    metadata = Spinner::ProxyMetadata.new(["127.0.0.1/32"])
    ["[2001:db8::1]", "[2001:db8::1]:443"].each do |address|
      env = {"HTTP_FORWARDED" => "for=\"#{address}\";proto=https"}
      metadata.apply(env, "127.0.0.1")
      assert_equal "2001:db8::1", env["REMOTE_ADDR"]
      assert_equal "https", env["rack.url_scheme"]
    end
  end

  def test_malformed_bracketed_addresses_keep_peer
    metadata = Spinner::ProxyMetadata.new(["127.0.0.1/32"])
    ["[2001:db8::1", "[2001:db8::1]:bad", "[]", "[no-ip]", "[2001:db8::1]extra"].each do |address|
      env = {"HTTP_FORWARDED" => "for=\"#{address}\""}
      metadata.apply(env, "127.0.0.1")
      assert_equal "127.0.0.1", env["REMOTE_ADDR"]
    end
  end
end
