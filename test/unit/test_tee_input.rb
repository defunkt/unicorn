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
    ti = Unicorn::TeeInput.new(@rd, nil, "hello")
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
    ti = Unicorn::TeeInput.new(@rd, nil, "hello")
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

end
