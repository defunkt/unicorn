# Copyright (c) 2009 Eric Wong
require 'test/test_helper'

include Unicorn

class UploadTest < Test::Unit::TestCase

  def setup
    @addr = ENV['UNICORN_TEST_ADDR'] || '127.0.0.1'
    @port = unused_port
    @hdr = {'Content-Type' => 'text/plain', 'Content-Length' => '0'}
    @bs = 4096
    @count = 256
    @server = nil

    # we want random binary data to test 1.9 encoding-aware IO craziness
    @random = File.open('/dev/urandom','rb')
    @sha1 = Digest::SHA1.new
    @sha1_app = lambda do |env|
      input = env['rack.input']
      resp = { :pos => input.pos, :size => input.stat.size }
      begin
        loop { @sha1.update(input.sysread(@bs)) }
      rescue EOFError
      end
      resp[:sha1] = @sha1.hexdigest
      [ 200, @hdr.merge({'X-Resp' => resp.inspect}), [] ]
    end
  end

  def teardown
    redirect_test_io { @server.stop(true) } if @server
  end

  def test_put
    start_server(@sha1_app)
    sock = TCPSocket.new(@addr, @port)
    sock.syswrite("PUT / HTTP/1.0\r\nContent-Length: #{length}\r\n\r\n")
    @count.times do
      buf = @random.sysread(@bs)
      @sha1.update(buf)
      sock.syswrite(buf)
    end
    read = sock.read.split(/\r\n/)
    assert_equal "HTTP/1.1 200 OK", read[0]
    resp = eval(read.grep(/^X-Resp: /).first.sub!(/X-Resp: /, ''))
    assert_equal length, resp[:size]
    assert_equal 0, resp[:pos]
    assert_equal @sha1.hexdigest, resp[:sha1]
  end


  def test_put_keepalive_truncates_small_overwrite
    start_server(@sha1_app)
    sock = TCPSocket.new(@addr, @port)
    to_upload = length + 1
    sock.syswrite("PUT / HTTP/1.0\r\nContent-Length: #{to_upload}\r\n\r\n")
    @count.times do
      buf = @random.sysread(@bs)
      @sha1.update(buf)
      sock.syswrite(buf)
    end
    sock.syswrite('12345') # write 4 bytes more than we expected
    @sha1.update('1')

    read = sock.read.split(/\r\n/)
    assert_equal "HTTP/1.1 200 OK", read[0]
    resp = eval(read.grep(/^X-Resp: /).first.sub!(/X-Resp: /, ''))
    assert_equal to_upload, resp[:size]
    assert_equal 0, resp[:pos]
    assert_equal @sha1.hexdigest, resp[:sha1]
  end

  def test_put_excessive_overwrite_closed
    start_server(lambda { |env| [ 200, @hdr, [] ] })
    sock = TCPSocket.new(@addr, @port)
    buf = ' ' * @bs
    sock.syswrite("PUT / HTTP/1.0\r\nContent-Length: #{length}\r\n\r\n")
    @count.times { sock.syswrite(buf) }
    assert_raise Errno::ECONNRESET do
      ::Unicorn::Const::CHUNK_SIZE.times { sock.syswrite(buf) }
    end
  end

  def test_put_handler_closed_file
    nr = '0'
    start_server(lambda { |env|
      env['rack.input'].close
      resp = { :nr => nr.succ! }
      [ 200, @hdr.merge({ 'X-Resp' => resp.inspect}), [] ]
    })
    sock = TCPSocket.new(@addr, @port)
    buf = ' ' * @bs
    sock.syswrite("PUT / HTTP/1.0\r\nContent-Length: #{length}\r\n\r\n")
    @count.times { sock.syswrite(buf) }
    read = sock.read.split(/\r\n/)
    assert_equal "HTTP/1.1 200 OK", read[0]
    resp = eval(read.grep(/^X-Resp: /).first.sub!(/X-Resp: /, ''))
    assert_equal '1', resp[:nr]

    # server still alive?
    sock = TCPSocket.new(@addr, @port)
    sock.syswrite("GET / HTTP/1.0\r\n\r\n")
    read = sock.read.split(/\r\n/)
    assert_equal "HTTP/1.1 200 OK", read[0]
    resp = eval(read.grep(/^X-Resp: /).first.sub!(/X-Resp: /, ''))
    assert_equal '2', resp[:nr]
  end

  def test_renamed_file_not_closed
    start_server(lambda { |env|
      new_tmp = Tempfile.new('unicorn_test')
      input = env['rack.input']
      File.rename(input.path, new_tmp)
      resp = {
        :inode => input.stat.ino,
        :size => input.stat.size,
        :new_tmp => new_tmp.path,
        :old_tmp => input.path,
      }
      [ 200, @hdr.merge({ 'X-Resp' => resp.inspect}), [] ]
    })
    sock = TCPSocket.new(@addr, @port)
    buf = ' ' * @bs
    sock.syswrite("PUT / HTTP/1.0\r\nContent-Length: #{length}\r\n\r\n")
    @count.times { sock.syswrite(buf) }
    read = sock.read.split(/\r\n/)
    assert_equal "HTTP/1.1 200 OK", read[0]
    resp = eval(read.grep(/^X-Resp: /).first.sub!(/X-Resp: /, ''))
    new_tmp = File.open(resp[:new_tmp])
    assert_equal resp[:inode], new_tmp.stat.ino
    assert_equal length, resp[:size]
    assert ! File.exist?(resp[:old_tmp])
    assert_equal resp[:size], new_tmp.stat.size
  end

  private

  def length
    @bs * @count
  end

  def start_server(app)
    redirect_test_io do
      @server = HttpServer.new(app, :listeners => [ "#{@addr}:#{@port}" ] )
      @server.start
    end
  end

end
