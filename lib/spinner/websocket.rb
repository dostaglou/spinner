require "base64"
require "digest/sha1"
require_relative "../spinner"

module Spinner
  module WebSocket
    class Adapter
      def initialize(application, max_message_bytes: 1048576, idle_timeout: 30.0)
        raise ArgumentError, "invalid WebSocket limits" unless max_message_bytes.is_a?(Integer) && max_message_bytes > 0 && idle_timeout.is_a?(Numeric) && idle_timeout > 0 && idle_timeout.finite?
        @application = application
        @maximum = max_message_bytes
        @timeout = idle_timeout
      end

      def call(env)
        upgrades = env["HTTP_UPGRADE"].to_s.downcase.split(",").map(&:strip)
        return @application.call(env) unless upgrades.include?("websocket")
        return [400, {}, ["Invalid WebSocket upgrade"]] unless upgrades == ["websocket"]
        key = env["HTTP_SEC_WEBSOCKET_KEY"].to_s
        valid_key = key.match?(/\A[A-Za-z0-9+\/]{22}==\z/)
        valid_key &&= Base64.strict_decode64(key).bytesize == 16
        valid_key &&= Base64.strict_encode64(Base64.strict_decode64(key)) == key
        connection = env["HTTP_CONNECTION"].to_s.downcase.split(",").map(&:strip)
        unless valid_key && connection.include?("upgrade") && env["REQUEST_METHOD"] == "GET" &&
               env["SERVER_PROTOCOL"] == "HTTP/1.1" && env["HTTP_SEC_WEBSOCKET_VERSION"] == "13" &&
               env["CONTENT_LENGTH"].to_s.to_i == 0 && env["HTTP_TRANSFER_ENCODING"].nil?
          return [400, {}, ["Invalid WebSocket request"]]
        end
        response = @application.call(env)
        return response unless response.is_a?(Array) && response.length == 3 && response[0] == 101
        handler = response[2]
        raise ArgumentError, "expected WebSocket handler" unless handler.respond_to?(:call)
        accept = Base64.strict_encode64(Digest::SHA1.digest(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
        headers = response[1].merge("upgrade" => "websocket", "sec-websocket-accept" => accept)
        upgrade = Upgrade.new(proc { handler.close if handler.respond_to?(:close) }) do |transport, buffered|
          session = Session.new(transport, buffered, @maximum, @timeout)
          begin
            handler.call(session)
          ensure
            session.close
          end
        end
        [101, headers, upgrade]
      rescue ArgumentError
        [400, {}, ["Invalid WebSocket request"]]
      end
    end

    class Session
      def initialize(transport, buffered, maximum, timeout)
        @transport = transport
        @buffer = buffered.b
        @maximum = maximum
        @timeout = timeout
        @closed = false
        @received_close = false
      end

      def exact(length, deadline)
        while @buffer.bytesize < length
          @buffer << @transport.read_chunk(deadline, [4096, length - @buffer.bytesize].min, "websocket")
        end
        @buffer.slice!(0, length).b
      end

      def read_message
        data = "".b
        message_opcode = nil
        deadline = Transport.now + @timeout
        loop do
          head = exact(2, deadline)
          first = head.getbyte(0)
          second = head.getbyte(1)
          fin = (first & 128) != 0
          opcode = first & 15
          return protocol_error(1002) if (first & 112) != 0 || (second & 128) == 0
          length = second & 127
          if length == 126 || length == 127
            count = length == 126 ? 2 : 8
            encoded = exact(count, deadline)
            length = 0
            return protocol_error(1002) if count == 8 && (encoded.getbyte(0) & 128) != 0
            encoded.bytes.each do |byte|
              return protocol_error(1009) if length > (@maximum >> 8)
              length = (length << 8) | byte
            end
            return protocol_error(1002) if (count == 2 && length < 126) || (count == 8 && length < 65536)
          end
          return protocol_error(1009) if opcode < 8 && (length > @maximum || data.bytesize + length > @maximum)
          return protocol_error(1002) if opcode >= 8 && (!fin || length > 125)
          mask = exact(4, deadline)
          payload = exact(length, deadline)
          decoded = "".b
          payload.bytes.each_with_index { |byte, index| decoded << (byte ^ mask.getbyte(index % 4)).chr.b }
          if opcode == 8
            return protocol_error(1002) if decoded.bytesize == 1
            if decoded.bytesize >= 2
              code = (decoded.getbyte(0) << 8) | decoded.getbyte(1)
              return protocol_error(1002) unless [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014].include?(code) || (code >= 3000 && code <= 4999)
              return protocol_error(1007) unless decoded.byteslice(2, decoded.bytesize - 2).dup.force_encoding("UTF-8").valid_encoding?
            end
            write_frame(8, decoded) unless @closed
            @received_close = true
            @closed = true
            return nil
          elsif opcode == 9
            write_frame(10, decoded)
            next
          elsif opcode == 10
            next
          elsif opcode == 1 || opcode == 2
            return protocol_error(1002) unless message_opcode.nil?
            message_opcode = opcode
          elsif opcode == 0
            return protocol_error(1002) if message_opcode.nil?
          else
            return protocol_error(1002)
          end
          data << decoded
          if fin
            return protocol_error(1007) if message_opcode == 1 && !data.dup.force_encoding("UTF-8").valid_encoding?
            return [message_opcode, data]
          end
        end
      end

      def write_message(opcode, bytes)
        raise IOError, "closed WebSocket" if @closed
        raise ArgumentError, "invalid message" unless [1, 2].include?(opcode) && bytes.is_a?(String) && bytes.bytesize <= @maximum
        raise ArgumentError, "invalid text message" if opcode == 1 && !bytes.dup.force_encoding("UTF-8").valid_encoding?
        write_frame(opcode, bytes)
      end

      def write_frame(opcode, bytes)
        length = bytes.bytesize
        header = [128 | opcode]
        if length < 126
          header << length
        else
          count = length <= 65535 ? 2 : 8
          header << (count == 2 ? 126 : 127)
          (count - 1).downto(0) { |index| header << ((length >> (index * 8)) & 255) }
        end
        deadline = Transport.now + @timeout
        write_binary_frame_bytes(header.pack("C*").b, deadline)
        # Pack dynamic payloads too: Spinel's native socket otherwise stops
        # a decoded string at an embedded NUL during an echo.
        write_binary_frame_bytes(bytes.bytes.pack("C*").b, deadline)
      end

      def write_binary_frame_bytes(bytes, deadline)
        offset = 0
        while offset < bytes.bytesize
          remaining = bytes.byteslice(offset, bytes.bytesize - offset).b
          count = @transport.write_stream_chunk(remaining, deadline)
          raise IOError, "invalid WebSocket write progress" if count <= 0 || count > remaining.bytesize
          offset += count
        end
      end

      def protocol_error(code)
        close(code, false)
        raise IOError, "invalid WebSocket frame"
      end

      def close(code = 1000, wait = true)
        return if @closed
        @closed = true
        write_frame(8, (code >> 8).chr.b + (code & 255).chr.b)
        deadline = Transport.now + @timeout
        while wait && !@received_close && Transport.now < deadline
          read_message
        end
      rescue IOError, SystemCallError, RequestError
        nil
      end
    end
  end
end
