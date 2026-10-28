# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "openssl"
require "rbconfig"
require "rubygems/package"
require "socket"
require "tmpdir"
require "timeout"

module SpinnerTest
  ROOT = File.expand_path("..", __dir__)
  FIXTURE = File.join(__dir__, "fixtures", "framework_server.rb")

  class Build
    attr_reader :directory, :binary

    def initialize
      @directory = Dir.mktmpdir("spinner-contract-")
      gem_file = File.join(@directory, "spinel-spinner.gem")
      run!("gem", "build", "spinel-spinner.gemspec", "--output", gem_file, chdir: ROOT)
      package = File.join(@directory, "package")
      Gem::Package.new(gem_file).extract_files(package)
      basic = File.join(@directory, "basic_server")
      run!("spinel", File.join(__dir__, "fixtures", "basic_server.rb"), "--require-gate",
           "-I", File.join(package, "lib"), "-o", basic, chdir: @directory)
      Server.new(basic, {"SPINNER_SSL_LIBRARY" => "/nonexistent-spinner-ssl"}).stop
      components = File.join(@directory, "native_components")
      run!("spinel", File.join(__dir__, "fixtures", "native_components.rb"), "--require-gate",
           "-I", File.join(package, "lib"), "-o", components, chdir: @directory)
      run!(components, chdir: @directory)
      @binary = File.join(@directory, "framework_server")
      run!("spinel", FIXTURE, "--require-gate", "-I", File.join(package, "lib"), "-o", @binary,
           chdir: @directory)
      # Spinel can compile an unresolved application constant and raise only
      # when the executable starts, so readiness is part of the build gate.
      Server.new(@binary).stop
      Minitest.after_run do
        if ENV["KEEP_SPINNER_TEST_ARTIFACTS"] != "1"
          FileUtils.remove_entry(@directory)
        else
          warn "Spinner build artifacts retained in #{@directory}"
        end
      end
    rescue StandardError => error
      warn "Spinner build artifacts retained in #{@directory}: #{error.message}"
      raise
    end

    private

    def run!(*command, chdir:)
      output, status = Open3.capture2e(*command, chdir: chdir)
      raise "#{command.first} failed (#{status.exitstatus}):\n#{output}" unless status.success?

      output
    rescue Errno::ENOENT
      raise "missing test prerequisite: #{command.first}"
    end
  end

  def self.build
    unless defined?(@build_attempted)
      @build_attempted = true
      begin
        @build = Build.new
      rescue StandardError => error
        @build_error = error
      end
    end
    raise @build_error if @build_error

    @build
  end

  class Server
    attr_reader :port, :pid, :log

    def initialize(binary, env = {}, launch_options: {}, **environment)
      env = env.merge(environment)
      @directory = Dir.mktmpdir("spinner-server-")
      @log = File.join(@directory, "server.log")
      output = File.open(@log, "wb")
      @pid = Process.spawn({ "HOST" => "127.0.0.1", "PORT" => "0" }.merge(env), *Array(binary),
                           out: output, err: output, pgroup: true, **launch_options)
      output.close
      wait_ready
    rescue StandardError
      stop(retain: true)
      raise
    end

    def alive?
      return false if @status

      @status = Process.waitpid2(@pid, Process::WNOHANG)&.last
      @status.nil?
    rescue Errno::ECHILD
      false
    end

    def signal(name)
      Process.kill(name, @pid)
    end

    def stop(retain: false)
      return unless @pid

      begin
        Process.kill("TERM", -@pid) if alive?
      rescue Errno::ESRCH
        nil
      end
      Timeout.timeout(3) { Process.wait(@pid) }
    rescue Timeout::Error
      begin
        Process.kill("KILL", -@pid)
      rescue Errno::ESRCH
        nil
      end
      Process.wait(@pid)
    rescue Errno::ECHILD
      nil
    ensure
      @pid = nil
      if @directory && !retain && ENV["KEEP_SPINNER_TEST_ARTIFACTS"] != "1"
        FileUtils.remove_entry(@directory)
      elsif @directory
        warn "Spinner process log retained in #{@log}"
      end
    end

    private

    def wait_ready
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      loop do
        data = File.binread(@log)
        match = data.match(/^SPINNER_READY (\d+) (\d+)$/)
        if match
          raise "readiness PID did not match child: #{data}" unless match[1].to_i == @pid

          @port = match[2].to_i
          return
        end
        raise "server exited before ready: #{data}" unless alive?
        raise "readiness timeout: #{data}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.025
      end
    end
  end

  module Wire
    Response = Struct.new(:version, :status, :headers, :body, :raw, keyword_init: true) do
      def header(name)
        headers.fetch(name.downcase, [])
      end
    end

    def with_server(env = {})
      server = Server.new(SpinnerTest.build.binary, env)
      yield server
    ensure
      server&.stop(retain: !$!.nil?)
    end

    def tcp(port)
      socket = Socket.tcp("127.0.0.1", port, connect_timeout: 2)
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      yield socket
    ensure
      socket&.close
    end

    def request(port, method: "GET", path: "/health", headers: {}, body: "".b)
      data = "#{method} #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
      headers.each { |key, value| data << "#{key}: #{value}\r\n" }
      data << "Content-Length: #{body.bytesize}\r\n" unless body.empty?
      data << "\r\n" << body.b
      tcp(port) do |socket|
        socket.write(data)
        read_response(socket, no_body: method == "HEAD")
      end
    end

    def raw_request(port, bytes, no_body: false)
      tcp(port) do |socket|
        socket.write(bytes)
        read_response(socket, no_body: no_body)
      end
    end

    def read_response(socket, no_body: false, timeout: 8)
      @wire_remainders ||= {}
      bytes = @wire_remainders.delete(socket.object_id) || "".b
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        split = bytes.index("\r\n\r\n")
        if split
          head = bytes.byteslice(0, split)
          lines = head.split("\r\n")
          version, status = lines.shift.split(" ", 3)
          raise "invalid response status: #{head.inspect}" unless version&.match?(/\AHTTP\/1\.[01]\z/) && status&.match?(/\A\d{3}\z/)
          headers = Hash.new { |hash, key| hash[key] = [] }
          lines.each do |line|
            key, value = line.split(":", 2)
            raise "invalid response header: #{line.inspect}" unless value

            headers[key.downcase] << value.strip
          end
          start = split + 4
          raise "duplicate content-length" if headers["content-length"].length > 1
          raise "conflicting response framing" if headers["content-length"].any? && headers["transfer-encoding"].any?
          bodyless = no_body || status.to_i < 200 || [204, 304].include?(status.to_i)
          finish = if bodyless
                     start
                   elsif headers["transfer-encoding"].include?("chunked")
                     chunked_end(bytes, start)
                   elsif headers["content-length"].length == 1
                     start + Integer(headers["content-length"].first)
                   end
          if finish && bytes.bytesize >= finish
            @wire_remainders[socket.object_id] = bytes.byteslice(finish..).to_s.b
            return Response.new(version: version, status: status.to_i, headers: headers,
                                body: bytes.byteslice(start, finish - start), raw: bytes.byteslice(0, finish))
          end
        end
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise "response timeout: #{bytes.inspect}" if remaining <= 0

        readable = IO.select([socket], nil, nil, remaining)
        raise "response timeout: #{bytes.inspect}" unless readable

        piece = socket.read_nonblock(65_536, exception: false)
        raise "connection closed during response: #{bytes.inspect}" if piece.nil?

        bytes << piece unless piece == :wait_readable
      end
    end

    def chunked_end(bytes, start)
      position = start
      loop do
        line_end = bytes.index("\r\n", position)
        return nil unless line_end

        size_text = bytes.byteslice(position, line_end - position).split(";", 2).first
        raise "invalid chunk size" unless size_text.match?(/\A[0-9a-fA-F]+\z/)

        size = size_text.to_i(16)
        position = line_end + 2 + size
        return nil if bytes.bytesize < position + 2
        raise "invalid chunk terminator" unless bytes.byteslice(position, 2) == "\r\n"

        position += 2
        return position if size.zero?
      end
    end

    def decoded_body(response)
      return response.body unless response.header("transfer-encoding").include?("chunked")
      bytes = response.body
      result = "".b
      offset = 0
      loop do
        ending = bytes.index("\r\n", offset)
        size = bytes.byteslice(offset, ending - offset).to_i(16)
        break if size.zero?
        result << bytes.byteslice(ending + 2, size)
        offset = ending + 2 + size + 2
      end
      result
    end

    def assert_response(response, status, body = nil)
      assert_equal(status, response.status)
      assert_equal(body.b, response.body.b) unless body.nil?
      if body && status != 204 && status != 304 && response.header("transfer-encoding").empty?
        assert_equal([body.bytesize.to_s], response.header("content-length"))
      end
    end
  end

  module Certificates
    def with_certificate
      directory = Dir.mktmpdir("spinner-cert-")
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = OpenSSL::X509::Name.parse("/CN=localhost")
      cert.issuer = cert.subject
      cert.public_key = key.public_key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      extension = OpenSSL::X509::ExtensionFactory.new
      extension.subject_certificate = cert
      extension.issuer_certificate = cert
      cert.add_extension(extension.create_extension("subjectAltName", "DNS:localhost"))
      cert.sign(key, OpenSSL::Digest::SHA256.new)
      cert_path = File.join(directory, "cert.pem")
      key_path = File.join(directory, "key.pem")
      File.write(cert_path, cert.to_pem)
      File.write(key_path, key.to_pem)
      yield cert_path, key_path
    ensure
      FileUtils.remove_entry(directory) if directory
    end

    def tls_client(port, ca_file:, alpn: ["http/1.1"], min_version: nil, max_version: nil)
      tcp = Socket.tcp("127.0.0.1", port, connect_timeout: 2)
      context = OpenSSL::SSL::SSLContext.new
      context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      context.ca_file = ca_file
      context.alpn_protocols = alpn
      context.min_version = min_version if min_version
      context.max_version = max_version if max_version
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
      ssl.sync_close = true
      ssl.hostname = "localhost"
      Timeout.timeout(3) { ssl.connect }
      ssl.post_connection_check("localhost")
      yield ssl
    ensure
      ssl&.close
      tcp&.close
    end
  end
end
