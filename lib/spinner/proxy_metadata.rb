module Spinner
  class ProxyMetadata
    def initialize(proxies)
      raise ArgumentError, "trusted_proxies must be an array of CIDRs" unless proxies.is_a?(Array) && proxies.all? { |proxy| proxy.is_a?(String) }
      @networks = proxies.map do |proxy|
        address, prefix = proxy.split("/", 2)
        bytes = address_bytes(address)
        raise ArgumentError, "invalid trusted proxy" if bytes.nil?
        bits = prefix.nil? ? bytes.length * 8 : prefix.to_i
        if (!prefix.nil? && !prefix.match?(/\A[0-9]+\z/)) || bits < 0 || bits > bytes.length * 8
          raise ArgumentError, "invalid proxy prefix"
        end
        [bytes, bits]
      end
    end

    def address_bytes(address)
      validator = HostAuthority.allocate
      if validator.ipv4?(address)
        return address.split(".").map(&:to_i)
      end
      return nil unless validator.ipv6?(address)
      text = address
      if text.include?(".")
        index = text.rindex(":")
        tail = text.byteslice(index + 1, text.bytesize).split(".").map(&:to_i)
        text = text.byteslice(0, index + 1) + ((tail[0] << 8) | tail[1]).to_s(16) + ":" + ((tail[2] << 8) | tail[3]).to_s(16)
      end
      halves = text.split("::", -1)
      left = halves[0].empty? ? [] : halves[0].split(":")
      right = halves.length == 2 && !halves[1].empty? ? halves[1].split(":") : []
      groups = halves.length == 2 ? left + Array.new(8 - left.length - right.length, "0") + right : left
      bytes = []
      groups.each { |group| value = group.to_i(16); bytes << (value >> 8); bytes << (value & 255) }
      bytes
    end

    def trusted?(address)
      bytes = address_bytes(address)
      return false if bytes.nil?
      @networks.any? do |network, bits|
        next false unless bytes.length == network.length
        whole = bits / 8
        rest = bits % 8
        bytes.take(whole) == network.take(whole) && (rest == 0 || (bytes[whole] >> (8 - rest)) == (network[whole] >> (8 - rest)))
      end
    end

    def apply(env, peer)
      env["REMOTE_ADDR"] = peer
      return env unless trusted?(peer) && env.key?("HTTP_FORWARDED")
      chain = []
      env["HTTP_FORWARDED"].split(",").each do |element|
        fields = {}
        element.split(";").each do |part|
          key, value = part.strip.split("=", 2)
          return env if value.nil? || fields.key?(key.downcase)
          if value.start_with?('"') && value.end_with?('"')
            value = value.byteslice(1, value.bytesize - 2)
          end
          return env if value.include?('"') || value.include?("\\")
          fields[key.downcase] = value
        end
        address = fields["for"]
        return env if address.nil?
        if address.start_with?("[")
          return env unless address.match?(/\A\[([^\]]+)\](?::[0-9]{1,5})?\z/)
          closing = address.index("]")
          address = address.byteslice(1, closing - 1)
        elsif address.include?(":")
          return env unless address.match?(/\A[0-9.]+:[0-9]{1,5}\z/)
          address = address.split(":")[0]
        end
        return env if address_bytes(address).nil?
        proto = fields["proto"]
        return env if !proto.nil? && !["http", "https"].include?(proto)
        chain << [address, proto]
      end
      current = peer
      selected = nil
      chain.reverse_each do |entry|
        break unless trusted?(current)
        selected = entry
        current = entry[0]
      end
      unless selected.nil?
        env["REMOTE_ADDR"] = selected[0]
        env["rack.url_scheme"] = selected[1] unless selected[1].nil?
      end
      env
    end
  end
end
