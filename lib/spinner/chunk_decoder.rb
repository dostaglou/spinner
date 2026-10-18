module Spinner
  # Incremental HTTP/1.1 chunk framing. Only decoded bytes count toward the
  # body limit; trailer fields are deliberately rejected until modeled safely.
  class ChunkDecoder
    attr_reader :remainder

    def initialize(storage, maximum = RequestParser::MAX_BODY_BYTES)
      @storage = storage
      @maximum = maximum
      @buffer = "".b
      @size = 0
      @remaining = 0
      @state = :size
      @remainder = "".b
    end

    def complete?
      @state == :done
    end

    def body
      @storage.input
    end

    def feed(bytes)
      raise RequestError.new(400, "chunk body already complete") if complete?
      @buffer << bytes
      loop do
        case @state
        when :size
          boundary = @buffer.index("\r\n")
          raise RequestError.new(400, "chunk size line too long") if boundary.nil? && @buffer.bytesize > 1024
          break if boundary.nil?
          raise RequestError.new(400, "chunk size line too long") if boundary > 1024
          line = @buffer.slice!(0, boundary + 2).byteslice(0, boundary)
          token = line.split(";", 2).first
          raise RequestError.new(400, "invalid chunk size") unless token.match?(/\A[0-9a-fA-F]+\z/)
          raise RequestError.new(400, "invalid chunk extension") if line.match?(/[\x00-\x1f\x7f]/)
          digits = token.downcase.sub(/\A0+/, "")
          digits = "0" if digits.empty?
          limit = (@maximum - @size).to_s(16)
          if digits.length > limit.length || (digits.length == limit.length && digits > limit)
            raise RequestError.new(413, "request body exceeds configured limit")
          end
          @remaining = digits.to_i(16)
          @state = @remaining == 0 ? :trailers : :data
        when :data
          break if @buffer.empty?
          count = [@remaining, @buffer.bytesize].min
          part = @buffer.slice!(0, count).b
          @storage.append(part)
          @size += count
          @remaining -= count
          @state = :terminator if @remaining == 0
        when :terminator
          break if @buffer.bytesize < 2
          raise RequestError.new(400, "invalid chunk terminator") unless @buffer.start_with?("\r\n")
          @buffer.slice!(0, 2)
          @state = :size
        when :trailers
          break if @buffer.bytesize < 2
          raise RequestError.new(400, "chunk trailers unsupported") unless @buffer.start_with?("\r\n")
          @remainder = @buffer.byteslice(2, @buffer.bytesize - 2).to_s.b
          @buffer = "".b
          @state = :done
          break
        end
      end
      complete?
    end
  end
end
