module Spinner
  module TLS
    class Socket
      def initialize(socket, context)
        @socket = socket
        @io_lock = Mutex.new
        @ssl = nil
        @handshake_complete = false
        @pending_write = nil
        @pending_bytes = nil
        return if context.nil?
        TLSFileControl.nonblock!(socket.fileno)
        @ssl = TLSNative.SSL_new(context.pointer)
        raise IOError, TLSNative.error("SSL_new") if @ssl.null?
        unless TLSNative.SSL_set_fd(@ssl, socket.fileno) == 1
          close
          raise IOError, TLSNative.error("SSL_set_fd")
        end
      end

      def to_io
        @socket
      end

      def closed?
        @socket.closed?
      end

      def pending
        @io_lock.synchronize { pending_unlocked }
      end

      def pending_unlocked
        @ssl.nil? ? 0 : TLSNative.SSL_pending(@ssl)
      end

      def accept_nonblock
        @io_lock.synchronize { accept_nonblock_unlocked }
      end

      def accept_nonblock_unlocked
        return self if @ssl.nil?
        result = TLSNative.SSL_accept(@ssl)
        if result == 1
          @handshake_complete = true
          return self
        end
        wait_or_raise(result, "SSL_accept")
      end

      def read_nonblock(max_bytes)
        @io_lock.synchronize { read_nonblock_unlocked(max_bytes) }
      end

      def read_nonblock_unlocked(max_bytes)
        return @socket.read_nonblock(max_bytes) if @ssl.nil?
        buffer = FFI::MemoryPointer.new(:char, max_bytes)
        result = TLSNative.SSL_read(@ssl, buffer, max_bytes)
        return buffer.read_string(result).b if result > 0
        wait_or_raise(result, "SSL_read")
      end

      def write_nonblock(bytes)
        @io_lock.synchronize { write_nonblock_unlocked(bytes) }
      end

      # Keep the binary conversion at the native socket call for framed writes.
      def write_stream_nonblock(bytes)
        @io_lock.synchronize do
          if @ssl.nil?
            @socket.write_nonblock(bytes.b)
          else
            write_nonblock_unlocked(bytes)
          end
        end
      end

      def write_nonblock_unlocked(bytes)
        return @socket.write_nonblock(bytes.b) if @ssl.nil?
        if @pending_write.nil?
          @pending_write = FFI::MemoryPointer.new(:char, bytes.bytesize)
          @pending_write.put_bytes(0, bytes)
          @pending_bytes = bytes
        elsif @pending_bytes != bytes
          raise IOError, "TLS write changed during retry"
        end
        result = TLSNative.SSL_write(@ssl, @pending_write, bytes.bytesize)
        if result > 0
          @pending_write = nil
          @pending_bytes = nil
          return result
        end
        wait_or_raise(result, "SSL_write")
      end

      def close
        @io_lock.synchronize { close_unlocked }
      end

      def close_unlocked
        unless @ssl.nil? || @ssl.null?
          TLSNative.SSL_shutdown(@ssl) if @handshake_complete && !@socket.closed?
          TLSNative.SSL_free(@ssl)
          @ssl = nil
        end
        @socket.close unless @socket.closed?
      end

      private

      def wait_or_raise(result, operation)
        case TLSNative.SSL_get_error(@ssl, result)
        when 2 then raise IO::EAGAINWaitReadable
        when 3 then raise IO::EAGAINWaitWritable
        when 6 then raise EOFError
        else raise IOError, TLSNative.error(operation)
        end
      end
    end
  end
end
