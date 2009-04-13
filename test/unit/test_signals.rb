# Copyright (c) 2009 Eric Wong
# You can redistribute it and/or modify it under the same terms as Ruby.
#
# Ensure we stay sane in the face of signals being sent to us

require 'test/test_helper'

include Unicorn

class Dd
  def initialize(bs, count)
    @count = count
    @buf = ' ' * bs
  end

  def each(&block)
    @count.times { yield @buf }
  end
end

class SignalsTest < Test::Unit::TestCase

  def setup
    @bs = 1 * 1024 * 1024
    @count = 100
    @port = unused_port
    tmp = @tmp = Tempfile.new('unicorn.sock')
    File.unlink(@tmp.path)
    n = 0
    tmp.chmod(0)
    @server_opts = {
      :listeners => [ "127.0.0.1:#@port", @tmp.path ],
      :after_fork => lambda { |server,worker|
        trap(:HUP) { tmp.chmod(n += 1) }
      },
    }
    @server = nil
  end

  def test_response_write
    app = lambda { |env|
      [ 200, { 'Content-Type' => 'text/plain', 'X-Pid' => Process.pid.to_s },
        Dd.new(@bs, @count) ]
    }
    redirect_test_io { @server = HttpServer.new(app, @server_opts).start }
    sock = nil
    assert_nothing_raised do
      sock = TCPSocket.new('127.0.0.1', @port)
      sock.syswrite("GET / HTTP/1.0\r\n\r\n")
    end
    buf = ''
    header_len = pid = nil
    assert_nothing_raised do
      buf = sock.sysread(16384, buf)
      pid = buf[/\r\nX-Pid: (\d+)\r\n/, 1].to_i
      header_len = buf[/\A(.+?\r\n\r\n)/m, 1].size
    end
    read = buf.size
    mode_before = @tmp.stat.mode
    assert_raises(EOFError,Errno::ECONNRESET,Errno::EPIPE,Errno::EINVAL,
                  Errno::EBADF) do
      loop do
        3.times { Process.kill(:HUP, pid) }
        sock.sysread(16384, buf)
        read += buf.size
        3.times { Process.kill(:HUP, pid) }
      end
    end

    redirect_test_io { @server.stop(true) }
    # can't check for == since pending signals get merged
    assert mode_before < @tmp.stat.mode
    assert_equal(read - header_len, @bs * @count)
    assert_nothing_raised { sock.close }
  end

  def test_request_read
    app = lambda { |env|
      [ 200, {'Content-Type'=>'text/plain', 'X-Pid'=>Process.pid.to_s}, [] ]
    }
    redirect_test_io { @server = HttpServer.new(app, @server_opts).start }
    pid = nil

    assert_nothing_raised do
      sock = TCPSocket.new('127.0.0.1', @port)
      sock.syswrite("GET / HTTP/1.0\r\n\r\n")
      pid = sock.sysread(4096)[/\r\nX-Pid: (\d+)\r\n/, 1].to_i
      sock.close
    end

    sock = TCPSocket.new('127.0.0.1', @port)
    sock.syswrite("PUT / HTTP/1.0\r\n")
    sock.syswrite("Content-Length: #{@bs * @count}\r\n\r\n")
    1000.times { Process.kill(:HUP, pid) }
    mode_before = @tmp.stat.mode
    killer = fork { loop { Process.kill(:HUP, pid); sleep(0.0001) } }
    buf = ' ' * @bs
    @count.times { sock.syswrite(buf) }
    Process.kill(:TERM, killer)
    Process.waitpid2(killer)
    redirect_test_io { @server.stop(true) }
    # can't check for == since pending signals get merged
    assert mode_before < @tmp.stat.mode
    assert_equal pid, sock.sysread(4096)[/\r\nX-Pid: (\d+)\r\n/, 1].to_i
    sock.close
  end

end
