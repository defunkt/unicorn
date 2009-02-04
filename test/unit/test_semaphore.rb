root_dir = File.join(File.dirname(__FILE__), "../..")
require File.join(root_dir, "test/test_helper")
require File.join(root_dir, "lib/unicorn/semaphore")

class TestSemaphore < Test::Unit::TestCase
  def setup
    super
    
    @semaphore = Semaphore.new
  end
  
  def test_wait_prevents_thread_from_running
    thread = Thread.new { @semaphore.wait }
    give_up_my_time_slice
    
    assert thread.stop?
  end
  
  def test_signal_allows_waiting_thread_to_run
    ran = false
    thread = Thread.new { @semaphore.wait; ran = true }
    give_up_my_time_slice
    
    @semaphore.signal
    give_up_my_time_slice
    
    assert ran
  end
  
  def test_wait_allows_only_specified_number_of_resources
    @semaphore = Semaphore.new(1)
    
    run_count = 0
    thread1 = Thread.new { @semaphore.wait; run_count += 1 }
    thread2 = Thread.new { @semaphore.wait; run_count += 1 }
    give_up_my_time_slice
    
    assert_equal 1, run_count
  end
  
  def test_semaphore_serializes_threads
    @semaphore = Semaphore.new(1)
    
    result = ""
    thread1 = Thread.new do
      @semaphore.wait
      4.times do |i|
        give_up_my_time_slice
        result << i.to_s
      end
      @semaphore.signal 
    end
    
    thread2 = Thread.new do
      @semaphore.wait
      ("a".."d").each do |char|
        give_up_my_time_slice
        result << char
      end
      @semaphore.signal 
    end
    
    give_up_my_time_slice
    @semaphore.wait
    
    assert_equal "0123abcd", result
  end
  
  def test_synchronize_many_threads
    @semaphore = Semaphore.new(1)
    
    result = []
    5.times do |i|
      Thread.new do 
        @semaphore.wait
        2.times { |j| result << [i, j] }
        @semaphore.signal
      end
    end
    
    give_up_my_time_slice
    @semaphore.wait
    
    5.times do |i|
      2.times do |j|
        assert_equal i, result[2 * i + j][0]
        assert_equal j, result[2 * i + j][1]
      end
    end
  end
  
  def test_synchronize_ensures_signal
    @semaphore = Semaphore.new(1)
    threads = []
    run_count = 0
    threads << Thread.new do 
      @semaphore.synchronize { run_count += 1 }
    end
    threads << Thread.new do
      @semaphore.synchronize { run_count += 1; raise "I'm throwing an error." }
    end
    threads << Thread.new do
      @semaphore.synchronize { run_count += 1 }
    end
    
    give_up_my_time_slice
    @semaphore.wait
    
    assert !threads.any? { |thread| thread.alive? }
    assert_equal 3, run_count
  end
  
  private 
  
  def give_up_my_time_slice
    sleep(1)
  end
end
