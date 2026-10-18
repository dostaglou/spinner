require "stringio"

module Spinner
  # Both backends expose binary IO semantics without copying a spool into RAM.
  class Input
    def initialize(bytes, file = nil)
      @file = file
      @memory = file.nil? ? StringIO.new(bytes.b, "rb") : nil
      @closed = false
    end

    def read(length = nil, buffer = nil)
      raise IOError, "closed input" if @closed
      result = if @file.nil?
                 length.nil? ? @memory.read : @memory.read(length)
               else
                 length.nil? ? @file.read : @file.read(length)
               end
      buffer.replace(result.to_s.b) unless buffer.nil?
      result.nil? ? nil : (buffer.nil? ? result.b : buffer)
    end

    def gets(separator = "\n", limit = nil)
      raise IOError, "closed input" if @closed
      result = if @file.nil?
        limit.nil? ? @memory.gets(separator) : @memory.gets(separator, limit)
      else
        limit.nil? ? @file.gets(separator) : @file.gets(separator, limit)
      end
      result.nil? ? nil : result.b
    end

    def each
      return enum_for(:each) unless block_given?
      while (line = gets)
        yield line
      end
      self
    end

    def rewind
      raise IOError, "closed input" if @closed
      @file.nil? ? @memory.rewind : @file.rewind
      0
    end

    def close
      return if @closed
      @closed = true
      if @file.nil?
        @memory.close
      else
        @file.close unless @file.closed?
      end
      nil
    end
  end
end
