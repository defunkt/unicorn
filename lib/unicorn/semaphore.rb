class Semaphore
  def initialize(resource_count = 0)
    @available_resource_count = resource_count
    @mutex = Mutex.new
    @waiting_threads = []
  end
  
  def wait
    make_thread_wait unless resource_is_available
  end
  
  def signal
    schedule_waiting_thread if thread_is_waiting
  end
  
  def synchronize
    self.wait
    yield
  ensure
    self.signal
  end
  
  private 
  
  def resource_is_available
    @mutex.synchronize do
      return (@available_resource_count -= 1) >= 0
    end
  end
  
  def make_thread_wait
    @waiting_threads << Thread.current
    Thread.stop  
  end
  
  def thread_is_waiting
    @mutex.synchronize do
      return (@available_resource_count += 1) <= 0
    end
  end
  
  def schedule_waiting_thread
    thread = @waiting_threads.shift
    thread.wakeup if thread
  end
end
