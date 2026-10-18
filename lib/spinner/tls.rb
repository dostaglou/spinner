require "ffi"

module Spinner
  module TLSNative
    extend FFI::Library

    def self.load!
      return if @loaded
      # macOS's system libssl can be incompatible with the libcrypto used by
      # Spinel's bundled OpenSSL package. Allow an explicit, matching library.
      library = ENV["SPINNER_SSL_LIBRARY"]
      if library.nil? || library.empty?
        library = ["/opt/homebrew/opt/openssl@3/lib/libssl.dylib",
                   "/usr/local/opt/openssl@3/lib/libssl.dylib"].find { |path| File.file?(path) }
        library ||= "libssl.so.3"
      end
      ffi_lib library

      attach_function :TLS_server_method, [], :pointer
      callback :alpn_select, [:pointer, :pointer, :pointer, :pointer, :uint, :pointer], :int
      attach_function :SSL_CTX_set_alpn_select_cb, [:pointer, :alpn_select, :pointer], :void
      attach_function :SSL_CTX_new, [:pointer], :pointer
      attach_function :SSL_CTX_free, [:pointer], :void
      attach_function :SSL_CTX_ctrl, [:pointer, :int, :long, :pointer], :long
      attach_function :SSL_CTX_use_certificate_chain_file, [:pointer, :string], :int
      attach_function :SSL_CTX_use_PrivateKey_file, [:pointer, :string, :int], :int
      attach_function :SSL_CTX_check_private_key, [:pointer], :int
      attach_function :SSL_new, [:pointer], :pointer
      attach_function :SSL_free, [:pointer], :void
      attach_function :SSL_set_fd, [:pointer, :int], :int
      attach_function :SSL_accept, [:pointer], :int
      attach_function :SSL_get_error, [:pointer, :int], :int
      attach_function :SSL_read, [:pointer, :pointer, :int], :int
      attach_function :SSL_write, [:pointer, :pointer, :int], :int
      attach_function :SSL_pending, [:pointer], :int
      attach_function :SSL_shutdown, [:pointer], :int
      attach_function :ERR_get_error, [], :ulong
      attach_function :ERR_error_string_n, [:ulong, :pointer, :size_t], :void

      @loaded = true
    end

    def self.error(prefix)
      code = self.ERR_get_error
      return prefix if code == 0
      buffer = FFI::MemoryPointer.new(:char, 256)
      self.ERR_error_string_n(code, buffer, 256)
      "#{prefix}: #{buffer.read_string}"
    end
  end

  module TLSFileControl
    extend FFI::Library
    ffi_lib FFI::Library::LIBC
    attach_function :fcntl, [:int, :int, :int], :int

    def self.nonblock!(fd)
      flags = fcntl(fd, 3, 0) # F_GETFL
      raise IOError, "fcntl(F_GETFL) failed" if flags < 0
      bit = RUBY_PLATFORM.include?("darwin") ? 4 : 2048
      raise IOError, "fcntl(F_SETFL) failed" if fcntl(fd, 4, flags | bit) < 0
    end
  end

  module TLS
    class Context
      attr_reader :pointer

      def initialize(cert_file, key_file)
        TLSNative.load!
        @pointer = TLSNative.SSL_CTX_new(TLSNative.TLS_server_method)
        raise IOError, TLSNative.error("SSL_CTX_new") if @pointer.null?
        begin
          # SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION.
          raise IOError, "TLS 1.2 minimum unavailable" unless TLSNative.SSL_CTX_ctrl(@pointer, 123, 0x0303, nil) == 1
          raise IOError, "TLS 1.3 maximum unavailable" unless TLSNative.SSL_CTX_ctrl(@pointer, 124, 0x0304, nil) == 1
          @alpn_callback = proc do |_ssl, output, output_length, offered, length, _arg|
            protocols = offered.read_string(length)
            offset = 0
            selected = nil
            while offset < length
              size = protocols.getbyte(offset)
              break if size.nil? || size == 0 || offset + size + 1 > length
              if protocols.byteslice(offset + 1, size) == "http/1.1"
                selected = offset + 1
                break
              end
              offset += size + 1
            end
            if selected.nil?
              2 # fatal alert: never select HTTP/2
            else
              output.write_pointer(offered + selected)
              output_length.write_uint8(8)
              0
            end
          end
          TLSNative.SSL_CTX_set_alpn_select_cb(@pointer, @alpn_callback, nil)
          raise IOError, TLSNative.error("certificate chain") unless TLSNative.SSL_CTX_use_certificate_chain_file(@pointer, cert_file) == 1
          raise IOError, TLSNative.error("private key") unless TLSNative.SSL_CTX_use_PrivateKey_file(@pointer, key_file, 1) == 1
          raise IOError, TLSNative.error("certificate/key mismatch") unless TLSNative.SSL_CTX_check_private_key(@pointer) == 1
        rescue StandardError
          close
          raise
        end
      end

      def close
        return if @pointer.nil? || @pointer.null?
        TLSNative.SSL_CTX_free(@pointer)
        @pointer = nil
      end
    end

  end
end
