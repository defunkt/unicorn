root_dir = File.join(File.dirname(__FILE__), "../..")
require File.join(root_dir, "test/test_helper")

include Mongrel

class FakeHandler < Mongrel::HttpHandler
  @@concurrent_threads = 0
  @@max_concurrent_threads = 0
  
  def self.max_concurrent_threads
    @@max_concurrent_threads ||= 0
  end
  
  def initialize
    super
    @@mutex = Mutex.new
  end
  
  def process(request, response)
    @@mutex.synchronize do
      @@concurrent_threads += 1 # !!! same for += and -=
      @@max_concurrent_threads = [@@concurrent_threads, @@max_concurrent_threads].max
    end
    
    sleep(0.1)
    response.socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nhello!\n")
  ensure
    @@mutex.synchronize { @@concurrent_threads -= 1 }
  end
end

class ThreadingTest < Test::Unit::TestCase
  def setup
    @valid_request = "GET / HTTP/1.1\r\nHost: www.google.com\r\nContent-Type: text/plain\r\n\r\n"
    @port = process_based_port
    
    @max_concurrent_threads = 4
    redirect_test_io do
      @server = HttpServer.new("127.0.0.1", @port, :max_concurrent_threads => @max_concurrent_threads)
    end
    
    @server.register("/test", FakeHandler.new)
    redirect_test_io do
      @server.run 
    end
  end

  def teardown
    redirect_test_io do
      @server.stop(true)
    end
  end

  def test_server_respects_max_current_threads_option
    threads = []
    (@max_concurrent_threads * 3).times do
      threads << Thread.new do
        send_data_over_socket("GET /test HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\n\r\n")
      end
    end
    while threads.any? { |thread| thread.alive? }
      sleep(0)
    end
    assert_equal @max_concurrent_threads, FakeHandler.max_concurrent_threads
  end
  
  private 
  
  def send_data_over_socket(string)
    socket = TCPSocket.new("127.0.0.1", @port)
    request = StringIO.new(string)

    while data = request.read(8)
      socket.write(data)
      socket.flush
      sleep(0)
    end
    sleep(0)
    socket.write(" ") # Some platforms only raise the exception on attempted write
    socket.flush
  end
end