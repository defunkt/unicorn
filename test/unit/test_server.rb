# Copyright (c) 2005 Zed A. Shaw 
# You can redistribute it and/or modify it under the same terms as Ruby.
#
# Additional work donated by contributors.  See http://mongrel.rubyforge.org/attributions.html
# for more information.

require 'test/test_helper'

include Unicorn

class TestHandler 

  def call(env) 
  #   response.socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nhello!\n")
    while env['rack.input'].read(4096)
    end
    [200, { 'Content-Type' => 'text/plain' }, ['hello!\n']]
   end
end


class WebServerTest < Test::Unit::TestCase

  def setup
    @valid_request = "GET / HTTP/1.1\r\nHost: www.zedshaw.com\r\nContent-Type: text/plain\r\n\r\n"
    @port = unused_port
    @tester = TestHandler.new
    redirect_test_io do
      @server = HttpServer.new(@tester, :listeners => [ "127.0.0.1:#{@port}" ] )
      @server.start
    end
  end

  def teardown
    redirect_test_io do
      @server.stop(true)
    end
  end

  def test_preload_app_config
    teardown
    tmp = Tempfile.new('test_preload_app_config')
    ObjectSpace.undefine_finalizer(tmp)
    app = lambda { ||
      tmp.sysseek(0)
      tmp.truncate(0)
      tmp.syswrite($$)
      lambda { |env| [ 200, { 'Content-Type' => 'text/plain' }, [ "#$$\n" ] ] }
    }
    redirect_test_io do
      @server = HttpServer.new(app, :listeners => [ "127.0.0.1:#@port"] )
      @server.start
    end
    results = hit(["http://localhost:#@port/"])
    worker_pid = results[0].to_i
    tmp.sysseek(0)
    loader_pid = tmp.sysread(4096).to_i
    assert_equal worker_pid, loader_pid
    teardown

    redirect_test_io do
      @server = HttpServer.new(app, :listeners => [ "127.0.0.1:#@port"],
                               :preload_app => true)
      @server.start
    end
    results = hit(["http://localhost:#@port/"])
    worker_pid = results[0].to_i
    tmp.sysseek(0)
    loader_pid = tmp.sysread(4096).to_i
    assert_equal $$, loader_pid
    assert worker_pid != loader_pid
    ensure
      tmp.close!
  end

  def test_broken_app
    teardown
    app = lambda { |env| raise RuntimeError, "hello" }
    # [200, {}, []] }
    redirect_test_io do
      @server = HttpServer.new(app, :listeners => [ "127.0.0.1:#@port"] )
      @server.start
    end
    sock = nil
    assert_nothing_raised do
      sock = TCPSocket.new('127.0.0.1', @port)
      sock.syswrite("GET / HTTP/1.0\r\n\r\n")
    end

    assert_match %r{\AHTTP/1.[01] 500\b}, sock.sysread(4096)
    assert_nothing_raised { sock.close }
  end

  def test_simple_server
    results = hit(["http://localhost:#{@port}/test"])
    assert_equal 'hello!\n', results[0], "Handler didn't really run"
  end


  def do_test(string, chunk, close_after=nil, shutdown_delay=0)
    # Do not use instance variables here, because it needs to be thread safe
    socket = TCPSocket.new("127.0.0.1", @port);
    request = StringIO.new(string)
    chunks_out = 0

    while data = request.read(chunk)
      chunks_out += socket.write(data)
      socket.flush
      sleep 0.2
      if close_after and chunks_out > close_after
        socket.close
        sleep 1
      end
    end
    sleep(shutdown_delay)
    socket.write(" ") # Some platforms only raise the exception on attempted write
    socket.flush
  end

  def test_trickle_attack
    do_test(@valid_request, 3)
  end

  def test_close_client
    assert_raises IOError do
      do_test(@valid_request, 10, 20)
    end
  end

  def test_bad_client
    redirect_test_io do
      do_test("GET /test HTTP/BAD", 3)
    end
  end

  def test_bad_client_400
    sock = nil
    assert_nothing_raised do
      sock = TCPSocket.new('127.0.0.1', @port)
      sock.syswrite("GET / HTTP/1.0\r\nHost: foo\rbar\r\n\r\n")
    end
    assert_match %r{\AHTTP/1.[01] 400\b}, sock.sysread(4096)
    assert_nothing_raised { sock.close }
  end

  def test_header_is_too_long
    redirect_test_io do
      long = "GET /test HTTP/1.1\r\n" + ("X-Big: stuff\r\n" * 15000) + "\r\n"
      assert_raises Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED, Errno::EINVAL, IOError do
        do_test(long, long.length/2, 10)
      end
    end
  end

  def test_file_streamed_request
    body = "a" * (Unicorn::Const::MAX_BODY * 2)
    long = "PUT /test HTTP/1.1\r\nContent-length: #{body.length}\r\n\r\n" + body
    do_test(long, Unicorn::Const::CHUNK_SIZE * 2 -400)
  end

  def test_file_streamed_request_bad_method
    body = "a" * (Unicorn::Const::MAX_BODY * 2)
    long = "GET /test HTTP/1.1\r\nContent-length: #{body.length}\r\n\r\n" + body
    assert_raises(EOFError,Errno::ECONNRESET,Errno::EPIPE,Errno::EINVAL,
                  Errno::EBADF) {
      do_test(long, Unicorn::Const::CHUNK_SIZE * 2 -400)
    }
  end

end

