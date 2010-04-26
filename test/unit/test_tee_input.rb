# -*- encoding: binary -*-

require 'test/unit'
require 'digest/sha1'
require 'unicorn'

class TestTeeInput < Test::Unit::TestCase

  def setup
    @rs = $/
    @env = {}
    @rd, @wr = IO.pipe
    @rd.sync = @wr.sync = true
    @start_pid = $$
  end

  def teardown
    return if $$ != @start_pid
    $/ = @rs
    @rd.close rescue nil
    @wr.close rescue nil
    begin
      Process.wait
    rescue Errno::ECHILD
      break
    end while true
  end

  def test_gets_long
    init_parser("hello", 5 + (4096 * 4 * 3) + "#$/foo#$/".size)
    ti = Unicorn::TeeInput.new(@rd, @env, @parser, @buf)
    status = line = nil
    pid = fork {
      @rd.close
      3.times { @wr.write("ffff" * 4096) }
      @wr.write "#$/foo#$/"
      @wr.close
    }
    @wr.close
    assert_nothing_raised { line = ti.gets }
    assert_equal(4096 * 4 * 3 + 5 + $/.size, line.size)
    assert_equal("hello" << ("ffff" * 4096 * 3) << "#$/", line)
    assert_nothing_raised { line = ti.gets }
    assert_equal "foo#$/", line
    assert_nil ti.gets
    assert_nothing_raised { pid, status = Process.waitpid2(pid) }
    assert status.success?
  end

  def test_gets_short
    init_parser("hello", 5 + "#$/foo".size)
    ti = Unicorn::TeeInput.new(@rd, @env, @parser, @buf)
    status = line = nil
    pid = fork {
      @rd.close
      @wr.write "#$/foo"
      @wr.close
    }
    @wr.close
    assert_nothing_raised { line = ti.gets }
    assert_equal("hello#$/", line)
    assert_nothing_raised { line = ti.gets }
    assert_equal "foo", line
    assert_nil ti.gets
    assert_nothing_raised { pid, status = Process.waitpid2(pid) }
    assert status.success?
  end

  def test_small_body
    init_parser('hello')
    ti = Unicorn::TeeInput.new(@rd, @env, @parser, @buf)
    assert_equal 0, @parser.content_length
    assert @parser.body_eof?
    assert_equal StringIO, ti.tmp.class
    assert_equal 0, ti.tmp.pos
    assert_equal 5, ti.size
    assert_equal 'hello', ti.read
    assert_equal '', ti.read
    assert_nil ti.read(4096)
  end

  def test_read_with_buffer
    init_parser('hello')
    ti = Unicorn::TeeInput.new(@rd, @env, @parser, @buf)
    buf = ''
    rv = ti.read(4, buf)
    assert_equal 'hell', rv
    assert_equal 'hell', buf
    assert_equal rv.object_id, buf.object_id
    assert_equal 'o', ti.read
    assert_equal nil, ti.read(5, buf)
    assert_equal 0, ti.rewind
    assert_equal 'hello', ti.read(5, buf)
    assert_equal 'hello', buf
  end

  def test_big_body
    init_parser('.' * Unicorn::Const::MAX_BODY << 'a')
    ti = Unicorn::TeeInput.new(@rd, @env, @parser, @buf)
    assert_equal 0, @parser.content_length
    assert @parser.body_eof?
    assert_kind_of File, ti.tmp
    assert_equal 0, ti.tmp.pos
    assert_equal Unicorn::Const::MAX_BODY + 1, ti.size
  end

  def test_read_in_full_if_content_length
    a, b = 300, 3
    init_parser('.' * b, 300)
    assert_equal 300, @parser.content_length
    ti = Unicorn::TeeInput.new(@rd, @env, @parser, @buf)
    pid = fork {
      @wr.write('.' * 197)
      sleep 1 # still a *potential* race here that would make the test moot...
      @wr.write('.' * 100)
    }
    assert_equal a, ti.read(a).size
    _, status = Process.waitpid2(pid)
    assert status.success?
    @wr.close
  end

  def test_big_body_multi
    init_parser('.', Unicorn::Const::MAX_BODY + 1)
    ti = Unicorn::TeeInput.new(@rd, @env, @parser, @buf)
    assert_equal Unicorn::Const::MAX_BODY, @parser.content_length
    assert ! @parser.body_eof?
    assert_kind_of File, ti.tmp
    assert_equal 0, ti.tmp.pos
    assert_equal 1, ti.tmp.size
    assert_equal Unicorn::Const::MAX_BODY + 1, ti.size
    nr = Unicorn::Const::MAX_BODY / 4
    pid = fork {
      @rd.close
      nr.times { @wr.write('....') }
      @wr.close
    }
    @wr.close
    assert_equal '.', ti.read(1)
    assert_equal Unicorn::Const::MAX_BODY + 1, ti.size
    nr.times {
      assert_equal '....', ti.read(4)
      assert_equal Unicorn::Const::MAX_BODY + 1, ti.size
    }
    assert_nil ti.read(1)
    status = nil
    assert_nothing_raised { pid, status = Process.waitpid2(pid) }
    assert status.success?
  end

  def test_chunked
    @parser = Unicorn::HttpParser.new
    @buf = "POST / HTTP/1.1\r\n" \
           "Host: localhost\r\n" \
           "Transfer-Encoding: chunked\r\n" \
           "\r\n"
    assert_equal @env, @parser.headers(@env, @buf)
    assert_equal "", @buf

    pid = fork {
      @rd.close
      5.times { @wr.write("5\r\nabcde\r\n") }
      @wr.write("0\r\n\r\n")
    }
    @wr.close
    ti = Unicorn::TeeInput.new(@rd, @env, @parser, @buf)
    assert_nil @parser.content_length
    assert_nil ti.len
    assert ! @parser.body_eof?
    assert_equal 25, ti.size
    assert @parser.body_eof?
    assert_equal 25, ti.len
    assert_equal 0, ti.tmp.pos
    assert_nothing_raised { ti.rewind }
    assert_equal 0, ti.tmp.pos
    assert_equal 'abcdeabcdeabcdeabcde', ti.read(20)
    assert_equal 20, ti.tmp.pos
    assert_nothing_raised { ti.rewind }
    assert_equal 0, ti.tmp.pos
    assert_kind_of File, ti.tmp
    status = nil
    assert_nothing_raised { pid, status = Process.waitpid2(pid) }
    assert status.success?
  end

  def test_chunked_ping_pong
    @parser = Unicorn::HttpParser.new
    @buf = "POST / HTTP/1.1\r\n" \
           "Host: localhost\r\n" \
           "Transfer-Encoding: chunked\r\n" \
           "\r\n"
    assert_equal @env, @parser.headers(@env, @buf)
    assert_equal "", @buf
    chunks = %w(aa bbb cccc dddd eeee)
    rd, wr = IO.pipe

    pid = fork {
      chunks.each do |chunk|
        rd.read(1) == "." and
          @wr.write("#{'%x' % [ chunk.size]}\r\n#{chunk}\r\n")
      end
      @wr.write("0\r\n\r\n")
    }
    ti = Unicorn::TeeInput.new(@rd, @env, @parser, @buf)
    assert_nil @parser.content_length
    assert_nil ti.len
    assert ! @parser.body_eof?
    chunks.each do |chunk|
      wr.write('.')
      assert_equal chunk, ti.read(16384)
    end
    _, status = Process.waitpid2(pid)
    assert status.success?
  end

  def test_chunked_with_trailer
    @parser = Unicorn::HttpParser.new
    @buf = "POST / HTTP/1.1\r\n" \
           "Host: localhost\r\n" \
           "Trailer: Hello\r\n" \
           "Transfer-Encoding: chunked\r\n" \
           "\r\n"
    assert_equal @env, @parser.headers(@env, @buf)
    assert_equal "", @buf

    pid = fork {
      @rd.close
      5.times { @wr.write("5\r\nabcde\r\n") }
      @wr.write("0\r\n")
      @wr.write("Hello: World\r\n\r\n")
    }
    @wr.close
    ti = Unicorn::TeeInput.new(@rd, @env, @parser, @buf)
    assert_nil @parser.content_length
    assert_nil ti.len
    assert ! @parser.body_eof?
    assert_equal 25, ti.size
    assert_equal "World", @env['HTTP_HELLO']
    status = nil
    assert_nothing_raised { pid, status = Process.waitpid2(pid) }
    assert status.success?
  end

private

  def init_parser(body, size = nil)
    @parser = Unicorn::HttpParser.new
    body = body.to_s.freeze
    @buf = "POST / HTTP/1.1\r\n" \
           "Host: localhost\r\n" \
           "Content-Length: #{size || body.size}\r\n" \
           "\r\n#{body}"
    assert_equal @env, @parser.headers(@env, @buf)
    assert_equal body, @buf
  end

end
