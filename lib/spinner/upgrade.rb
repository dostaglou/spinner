module Spinner
  # The callback owns the transport for its lifetime. Returning closes it.
  class Upgrade
    def initialize(close_handler = nil, &handler)
      @handler = handler
      @close_handler = close_handler
      @closed = false
    end

    def call(transport, buffered_bytes)
      @handler.call(transport, buffered_bytes)
    end

    def close
      return if @closed
      @closed = true
      @close_handler.call unless @close_handler.nil?
    end
  end
end
