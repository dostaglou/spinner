module Spinner
  class RequestError < StandardError
    attr_reader :status

    def initialize(status, message)
      super(message)
      @status = status
    end
  end

  # Incremental framing stays separate from socket reads and application code.
  class RequestParser
    MAX_BODY_BYTES = 1048576
    SUPPORTED_METHODS = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]

    attr_reader :method, :path, :query, :headers, :remainder, :content_length, :protocol

    def initialize(max_header_bytes = 32768, server_port = "4000", scheme = "http", max_body_bytes = MAX_BODY_BYTES)
      @max_body_bytes = max_body_bytes
      @max_header_bytes = max_header_bytes
      @buffer = "".b
      @complete = false
      @method = ""
      @path = ""
      @query = ""
      @headers = {}
      @remainder = "".b
      @content_length = 0
      @chunked = false
      @expect_continue = false
      @server_name = ""
      @server_port = server_port
      @scheme = scheme
      @protocol = ""
      @http_headers = {}
    end

    def complete?
      @complete
    end

    def chunked?
      @chunked
    end

    def expect_continue?
      @expect_continue
    end

    def keep_alive?
      tokens = @headers.fetch("connection", "").downcase.split(",").map(&:strip)
      return false if tokens.include?("close")
      @protocol == "HTTP/1.1" || tokens.include?("keep-alive")
    end

    def feed(bytes)
      raise RequestError.new(400, "request already complete") if @complete
      @buffer += bytes
      boundary = @buffer.index("\r\n\r\n")
      if boundary.nil?
        raise RequestError.new(431, "headers too large") if @buffer.bytesize > @max_header_bytes
        return false
      end
      size = boundary + 4
      raise RequestError.new(431, "headers too large") if size > @max_header_bytes
      head = @buffer.byteslice(0, boundary)
      @remainder = @buffer.byteslice(size, @buffer.bytesize - size)
      parse(head)
      @buffer = "".b
      @complete = true
      true
    end

    def environment(body = "".b)
      raise RequestError.new(400, "incomplete headers") unless @complete
      env = {"REQUEST_METHOD" => @method, "SCRIPT_NAME" => "", "PATH_INFO" => @path,
             "QUERY_STRING" => @query, "SERVER_NAME" => @server_name,
             "SERVER_PORT" => @server_port, "SERVER_PROTOCOL" => @protocol,
             "rack.url_scheme" => @scheme, "rack.input" => (body.is_a?(Input) ? body : Input.new(body))}
      env["CONTENT_LENGTH"] = @headers["content-length"] if @headers.key?("content-length")
      env["CONTENT_TYPE"] = @headers["content-type"] if @headers.key?("content-type")
      @http_headers.each { |key, value| env[key] = value }
      env
    end

    def parse(head)
      lines = head.split("\r\n")
      request = lines.shift.to_s
      unless request.match?(/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+ [^\x00-\x20\x7f-\xff]+ HTTP\/1\.[01]\z/n)
        raise RequestError.new(400, "invalid request line")
      end
      parts = request.split(" ")
      @method = parts[0]
      @protocol = parts[2]
      target = parts[1]
      raise RequestError.new(400, "invalid request target") if target.include?("#")
      @target_authority = nil
      @target_scheme = nil
      if target.start_with?("http://") || target.start_with?("https://")
        match = target.match(/\A(https?):\/\/([^\/\?]+)(.*)\z/)
        raise RequestError.new(400, "invalid absolute target") if match.nil?
        @target_scheme = match[1]
        @target_authority = match[2]
        HostAuthority.new(@target_authority)
        target = match[3]
        target = "/" + target if target.empty? || target.start_with?("?")
      end
      raise RequestError.new(405, "unsupported method") if @method == "CONNECT"
      unless target.start_with?("/") || (target == "*" && @method == "OPTIONS")
        raise RequestError.new(400, "unsupported request target")
      end
      path_and_query = target.split("?", 2)
      @path = path_and_query[0]
      @query = path_and_query.length == 2 ? path_and_query[1] : ""

      normalized_names = {}
      lines.each do |line|
        pair = line.split(":", 2)
        unless pair.length == 2 && pair[0].match?(/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/)
          raise RequestError.new(400, "invalid header")
        end
        name = pair[0].downcase
        value = pair[1].strip
        if pair[1].match?(/[\x00-\x08\x0a-\x1f\x7f]/)
          raise RequestError.new(400, "invalid or duplicate header")
        end
        normalized = name.upcase.tr("-", "_")
        if normalized_names.key?(normalized) && normalized_names[normalized] != name
          raise RequestError.new(400, "ambiguous header normalization")
        end
        if (normalized == "CONTENT_TYPE" && name != "content-type") ||
           (normalized == "CONTENT_LENGTH" && name != "content-length")
          raise RequestError.new(400, "ambiguous content header")
        end
        normalized_names[normalized] = name
        if @headers.key?(name)
          if ["host", "content-length", "transfer-encoding", "content-type", "expect", "authorization", "sec-websocket-key", "sec-websocket-version"].include?(name)
            raise RequestError.new(400, "duplicate singleton header")
          end
          value = @headers[name] + (name == "cookie" ? "; " : ", ") + value
        end
        @headers[name] = value
        unless name == "content-type" || name == "content-length"
          @http_headers["HTTP_#{normalized}"] = value
        end
      end
      host = @headers.fetch("host", "")
      if host.empty? && @protocol == "HTTP/1.0"
        @server_name = "localhost"
      else
        @server_name = HostAuthority.new(host).name
      end
      unless @target_authority.nil?
        default_port = @target_scheme == "https" ? "443" : "80"
        canonical_target = @target_authority.downcase.delete_suffix(":" + default_port)
        canonical_host = host.downcase.delete_suffix(":" + default_port)
        raise RequestError.new(400, "conflicting target authority") unless canonical_target == canonical_host
        raise RequestError.new(400, "conflicting target scheme") unless @target_scheme == @scheme
      end
      if @headers.key?("transfer-encoding")
        raise RequestError.new(400, "HTTP/1.0 transfer encoding unsupported") if @protocol != "HTTP/1.1"
        raise RequestError.new(400, "ambiguous message framing") if @headers.key?("content-length")
        raise RequestError.new(400, "unsupported transfer encoding") unless @headers["transfer-encoding"].downcase == "chunked"
        @chunked = true
      end
      length = @headers.fetch("content-length", "0")
      raise RequestError.new(400, "invalid Content-Length") unless length.match?(/\A[0-9]+\z/)
      # Compare decimal strings before conversion; even enormous valid lengths
      # must be rejected without overflowing the compiler's integer type.
      digits = length.sub(/\A0+/, "")
      limit = @max_body_bytes.to_s
      if digits.length > limit.length || (digits.length == limit.length && digits > limit)
        raise RequestError.new(413, "request body exceeds configured limit")
      end
      @content_length = digits.empty? ? 0 : digits.to_i
      raise RequestError.new(405, "unsupported method") unless SUPPORTED_METHODS.include?(@method)
      if @headers.key?("expect")
        raise RequestError.new(417, "expectations unsupported") unless @headers["expect"].downcase == "100-continue" && @protocol == "HTTP/1.1"
        @expect_continue = true
      end
    end
  end
end
