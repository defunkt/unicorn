root_dir = File.join(File.dirname(__FILE__), "../..")
require File.join(root_dir, "test/test_helper")

include Unicorn

class FakeHandler
  @@concurrent_threads = 0
  @@threads = 0
  
  def self.max_concurrent_threads
    @@threads ||= 0
  end
  
  def initialize
    super
    @@mutex = Mutex.new
  end
  
  def call(env)
    @@mutex.synchronize do
      @@concurrent_threads += 1 # !!! same for += and -=
      @@threads = [@@concurrent_threads, @@threads].max
    end
    
    sleep(0.1)
    [200, {'Content-Type' => 'text/plain'}, ['hello!']]
  ensure
    @@mutex.synchronize { @@concurrent_threads -= 1 }
  end
end

class ThreadingTest < Test::Unit::TestCase
  def setup
    @valid_request = "GET / HTTP/1.1\r\nHost: www.google.com\r\nContent-Type: text/plain\r\n\r\n"
    @port = process_based_port
    @app = Rack::URLMap.new('/test' => FakeHandler.new)
    @threads = 4
    redirect_test_io { @server = HttpServer.new(@app, :Host => "127.0.0.1", :Port => @port, :Max_concurrent_threads => @threads) }    
    redirect_test_io { @server.start }
  end

  def teardown
    redirect_test_io { @server.stop(true) }
  end

  def test_server_respects_max_concurrent_threads_option
    threads = []
    (@threads * 3).times do
      threads << Thread.new do
        send_data_over_socket("GET /test HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\n\r\n")
      end
    end
    while threads.any? { |thread| thread.alive? }
      sleep(0)
    end
    assert_equal @threads, FakeHandler.max_concurrent_threads
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
