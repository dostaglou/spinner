module Spinner
  # Host is mandatory in this HTTP/1.1 subset. Validate without DNS lookup.
  class HostAuthority
    attr_reader :name

    def initialize(authority)
      @name = ""
      if authority.start_with?("[")
        closing = authority.index("]")
        raise RequestError.new(400, "invalid Host literal") if closing.nil?
        literal = authority.byteslice(1, closing - 1)
        unless ipv6?(literal)
          raise RequestError.new(400, "invalid Host IPv6 address")
        end
        @name = authority.byteslice(0, closing + 1)
        suffix = authority.byteslice(closing + 1, authority.bytesize - closing - 1)
        unless suffix.empty?
          raise RequestError.new(400, "invalid Host authority") unless suffix.start_with?(":")
          validate_port(suffix.delete_prefix(":"))
        end
      else
        parts = authority.split(":", 2)
        @name = parts[0].to_s
        hostname = @name.delete_suffix(".")
        if hostname.empty? || hostname.bytesize > 253 || hostname.end_with?(".")
          raise RequestError.new(400, "missing or invalid Host")
        end
        hostname.split(".").each do |label|
          unless label.match?(/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/)
            raise RequestError.new(400, "invalid Host name")
          end
        end
        if hostname.match?(/\A[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\z/)
          raise RequestError.new(400, "invalid Host IPv4 address") unless ipv4?(hostname)
        end
        validate_port(parts[1]) if parts.length == 2
      end
    end

    def validate_port(port)
      unless port.match?(/\A[0-9]{1,5}\z/) && port.to_i >= 1 && port.to_i <= 65535
        raise RequestError.new(400, "invalid Host port")
      end
    end

    def ipv4?(address)
      parts = address.split(".", -1)
      return false unless parts.length == 4
      parts.each do |part|
        return false unless part.match?(/\A(?:0|[1-9][0-9]{0,2})\z/) && part.to_i <= 255
      end
      true
    end

    # Validate groups without constructing a 128-bit integer: the bundled
    # IPAddr overflows on addresses such as 2001:db8::1 in this Spinel revision.
    def ipv6?(address)
      text = address
      if text.include?(".")
        colon = text.rindex(":")
        return false if colon.nil?
        tail = text.byteslice(colon + 1, text.bytesize - colon - 1)
        return false unless ipv4?(tail)
        # An IPv4 tail occupies two hexadecimal groups.
        text = text.byteslice(0, colon + 1) + "0:0"
      end
      halves = text.split("::", -1)
      return false if halves.length > 2
      groups = []
      halves.each do |half|
        next if half.empty?
        return false if half.start_with?(":") || half.end_with?(":")
        groups += half.split(":")
      end
      if halves.length == 2
        return false unless groups.length < 8
      else
        return false unless groups.length == 8
      end
      groups.each do |group|
        return false unless group.match?(/\A[0-9A-Fa-f]{1,4}\z/)
      end
      true
    end
  end
end
