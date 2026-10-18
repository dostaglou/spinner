module Spinner
  class ResponseWriter
    def upgrade_header(response)
      status, headers, body = response
      raise ArgumentError, "expected upgrade response" unless status == 101 && body.is_a?(Upgrade)
      unless headers.is_a?(Hash) && headers["upgrade"].is_a?(String) && headers["upgrade"].match?(/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+(?:\/[!#$%&'*+.^_`|~0-9A-Za-z-]+)?\z/)
        raise ArgumentError, "expected upgrade protocol"
      end
      # Reuse header validation, replacing only server-owned connection framing.
      head = header(200, headers, nil, false, "HTTP/1.1", false)
      head.sub("200 OK", "101 Switching Protocols").sub("connection: close", "connection: Upgrade")
    end

    def self.reason(status)
      reasons = {200 => "OK", 201 => "Created", 202 => "Accepted", 204 => "No Content",
                 205 => "Reset Content", 301 => "Moved Permanently", 302 => "Found",
                 304 => "Not Modified", 400 => "Bad Request", 404 => "Not Found",
                 405 => "Method Not Allowed", 408 => "Request Timeout",
                 413 => "Content Too Large", 417 => "Expectation Failed",
                 431 => "Request Header Fields Too Large", 500 => "Internal Server Error",
                 503 => "Service Unavailable"}
      reasons.fetch(status, "Response")
    end

    # Validate and serialize before any bytes reach the client.
    def prepare(response, keep_alive = false, protocol = "HTTP/1.1", head_request = false)
      unless response.is_a?(Array) && response.length == 3
        raise ArgumentError, "expected [status, headers, body]"
      end
      status, headers, body = response
      unless status.is_a?(Integer) && status >= 200 && status <= 599
        raise ArgumentError, "expected a final HTTP status"
      end
      raise ArgumentError, "expected header hash" unless headers.is_a?(Hash)
      raise ArgumentError, "expected body array" unless body.is_a?(Array)
      length = 0
      body.each do |chunk|
        raise ArgumentError, "expected string body chunks" unless chunk.is_a?(String)
        length += chunk.bytesize
      end
      if [204, 205, 304].include?(status) && length != 0
        raise ArgumentError, "status requires an empty body"
      end
      head = header(status, headers, length, keep_alive, protocol, false)
      chunks = [head]
      body.each { |chunk| chunks << chunk } unless head_request
      chunks
    end

    def prepare_stream(response, keep_alive = false, protocol = "HTTP/1.1")
      unless response.is_a?(Array) && response.length == 3
        raise ArgumentError, "expected [status, headers, body]"
      end
      status, headers, body = response
      raise ArgumentError, "expected enumerable body" unless body.respond_to?(:each)
      raise ArgumentError, "bodyless status cannot stream" if [204, 205, 304].include?(status)
      chunked = protocol == "HTTP/1.1"
      [header(status, headers, nil, keep_alive && chunked, protocol, chunked), chunked]
    end

    def header(status, headers, length, keep_alive, protocol, chunked)
      unless status.is_a?(Integer) && status >= 200 && status <= 599
        raise ArgumentError, "expected a final HTTP status"
      end
      raise ArgumentError, "expected header hash" unless headers.is_a?(Hash)
      head = "#{protocol} #{status} #{ResponseWriter.reason(status)}\r\n"
      headers.each do |name, value|
        unless name.is_a?(String) && name.match?(/\A[!#$%&'*+.^_`|~0-9a-z-]+\z/)
          raise ArgumentError, "expected lowercase header names"
        end
        values = value.is_a?(Array) ? value : [value]
        values.each do |field|
          raise ArgumentError, "invalid header value" unless field.is_a?(String) && !field.match?(/[\x00-\x08\x0a-\x1f\x7f]/)
        end
        raise ArgumentError, "transfer encoding unsupported" if name == "transfer-encoding"
        next if name == "content-length" || name == "connection"
        values.each { |field| head += "#{name}: #{field}\r\n" }
      end
      head += "transfer-encoding: chunked\r\n" if chunked
      head += "content-length: #{length}\r\n" if !length.nil? && status != 204 && status != 304
      head += "allow: #{RequestParser::SUPPORTED_METHODS.join(', ')}\r\n" if status == 405 && !headers.key?("allow")
      head += "connection: #{keep_alive ? 'keep-alive' : 'close'}\r\n\r\n"
      head
    end

    def write_stream(transport, response, deadline, head, chunked, head_request = false, idle_timeout = 30.0, client = nil)
      body = response[2]
      begin
        write(transport, [head], deadline)
        unless head_request
          body.each do |part|
            raise ArgumentError, "expected string body chunks" unless part.is_a?(String)
            active_deadline = client.nil? ? deadline : client.stream_deadline
            raise IOError, "stream idle timeout" if Transport.now >= active_deadline
            next if part.empty?
            deadline = Transport.now + idle_timeout
            client.stream_deadline = deadline unless client.nil?
            if chunked
              write(transport, ["#{part.bytesize.to_s(16)}\r\n", part, "\r\n"], deadline)
            else
              write(transport, [part], deadline)
            end
          end
          write(transport, ["0\r\n\r\n"], deadline) if chunked
        end
      ensure
        body.close if body.respond_to?(:close)
      end
    end

    def write(transport, chunks, deadline)
      chunks.each do |chunk|
        offset = 0
        while offset < chunk.bytesize
          remaining = chunk.byteslice(offset, chunk.bytesize - offset)
          count = transport.write_some(remaining, deadline)
          raise IOError, "invalid write progress" if count <= 0 || count > remaining.bytesize
          offset += count
        end
      end
    end
  end
end
