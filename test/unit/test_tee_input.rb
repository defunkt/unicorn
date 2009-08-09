# encoding: binary
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
    ti = Unicorn::TeeInput.new(@rd)
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
    ti = Unicorn::TeeInput.new(@rd)
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

private

  def init_parser(body, size = nil)
    @parser = Unicorn::TeeInput::PARSER
    @parser.reset
    body = body.to_s.freeze
    buf = "POST / HTTP/1.1\r\n" \
          "Host: localhost\r\n" \
          "Content-Length: #{size || body.size}\r\n" \
          "\r\n#{body}"
    buf = Unicorn::TeeInput::RAW.replace(buf)
    assert_equal @env, @parser.headers(@env, buf)
    assert_equal body, buf
  end

end
