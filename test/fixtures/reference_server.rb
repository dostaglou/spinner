# frozen_string_literal: true

# A CRuby-only reference fixture for proving the process and socket harness.
require "socket"

listener = TCPServer.new("127.0.0.1", 0)
puts "SPINNER_READY #{Process.pid} #{listener.addr[1]}"
$stdout.flush
trap("TERM") { listener.close; exit }

loop do
  client = listener.accept
  first = client.gets
  next client.close unless first

  headers = {}
  while (line = client.gets) && line != "\r\n"
    key, value = line.split(":", 2)
    headers[key.downcase] = value.strip
  end
  length = headers.fetch("content-length", "0").to_i
  body = client.read(length)
  payload = first.start_with?("POST /echo ") ? body : "OK"
  client.write("HTTP/1.1 200 OK\r\ncontent-length: #{payload.bytesize}\r\n" \
               "connection: close\r\n\r\n#{payload}")
  client.close
end
