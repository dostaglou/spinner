module Spinner
  # Bounded admission; no unbounded task queue or per-request thread creation.
  class TaskPool
    def initialize(size, capacity = nil)
      @size = size
      @capacity = capacity || size
      @tasks = []
      @workers = []
      @count = 0
      @lock = Mutex.new
      @ready = ConditionVariable.new
      @stopping = false
    end

    def submit(on_cancel = nil, &task)
      @lock.synchronize do
        return false if @stopping || @count >= @capacity
        @count += 1
        @tasks << [task, on_cancel]
        if @workers.length < @size
          @workers << Thread.new { run }
        end
        @ready.signal
        true
      end
    end

    def run
      loop do
        task = @lock.synchronize do
          @ready.wait(@lock) while @tasks.empty? && !@stopping
          @tasks.empty? ? nil : @tasks.shift
        end
        break if task.nil?
        begin
          task[0].call
        rescue StandardError => error
          warn "Spinner task: #{error.message}"
        ensure
          @lock.synchronize { @count -= 1 }
        end
      end
    end

    def count
      @lock.synchronize { @count }
    end

    def stop
      cancelled = @lock.synchronize do
        @stopping = true
        tasks = @tasks
        @tasks = []
        @ready.broadcast
        tasks
      end
      @workers.each(&:kill)
      @workers.each(&:join)
      cancelled.each { |task| task[1].call unless task[1].nil? }
    end
  end
end
