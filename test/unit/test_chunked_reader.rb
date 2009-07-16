require 'test/unit'
require 'unicorn'
require 'unicorn_http'
require 'tempfile'
require 'io/nonblock'
require 'digest/sha1'

class TestChunkedReader < Test::Unit::TestCase

  def setup
    @env = {}
    @rd, @wr = IO.pipe
    @rd.binmode
    @wr.binmode
    @rd.sync = @wr.sync = true
    @start_pid = $$
  end

  def teardown
    return if $$ != @start_pid
    @rd.close rescue nil
    @wr.close rescue nil
    begin
      Process.wait
    rescue Errno::ECHILD
      break
    end while true
  end

  def test_error
    cr = bin_reader("8\r\nasdfasdf\r\n8\r\nasdfasdfa#{'a' * 1024}")
    a = nil
    assert_nothing_raised { a = cr.readpartial(8192) }
    assert_equal 'asdfasdf', a
    assert_nothing_raised { a = cr.readpartial(8192) }
    assert_equal 'asdfasdf', a
    assert_raises(Unicorn::HttpParserError) { cr.readpartial(8192) }
  end

  def test_eof1
    cr = bin_reader("0\r\n")
    assert_raises(EOFError) { cr.readpartial(8192) }
  end

  def test_eof2
    cr = bin_reader("0\r\n\r\n")
    assert_raises(EOFError) { cr.readpartial(8192) }
  end

  def test_readpartial1
    cr = bin_reader("4\r\nasdf\r\n0\r\n")
    assert_equal 'asdf', cr.readpartial(8192)
    assert_raises(EOFError) { cr.readpartial(8192) }
  end

  def test_dd
    cr = bin_reader("6\r\nhello\n\r\n")
    tmp = Tempfile.new('test_dd')
    tmp.sync = true

    pid = fork {
      crd, cwr = IO.pipe
      crd.binmode
      cwr.binmode
      crd.sync = cwr.sync = true

      pid = fork {
        STDOUT.reopen(cwr)
        crd.close
        cwr.close
        exec('dd', 'if=/dev/urandom', 'bs=93390', 'count=16')
      }
      cwr.close
      begin
        buf = crd.readpartial(16384)
        tmp.write(buf)
        @wr.write("#{'%x' % buf.size}\r\n#{buf}\r\n")
      rescue EOFError
        @wr.write("0\r\n\r\n")
        Process.waitpid(pid)
        exit 0
      end while true
    }
    assert_equal "hello\n", cr.readpartial(6)
    sha1 = Digest::SHA1.new
    buf = Unicorn::Z.dup
    begin
      cr.readpartial(16384, buf)
      sha1.update(buf)
    rescue EOFError
      break
    end while true

    assert_nothing_raised { Process.waitpid(pid) }
    sha1_file = Digest::SHA1.new
    File.open(tmp.path, 'rb') { |fp|
      while fp.read(16384, buf)
        sha1_file.update(buf)
      end
    }
    assert_equal sha1_file.hexdigest, sha1.hexdigest
  end

  def test_trailer
    @env['HTTP_TRAILER'] = 'Content-MD5'
    pid = fork { @wr.syswrite("Content-MD5: asdf\r\n") }
    cr = bin_reader("8\r\nasdfasdf\r\n8\r\nasdfasdf\r\n0\r\n")
    assert_equal 'asdfasdf', cr.readpartial(4096)
    assert_equal 'asdfasdf', cr.readpartial(4096)
    assert_raises(EOFError) { cr.readpartial(4096) }
    pid, status = Process.waitpid2(pid)
    assert status.success?
    assert_equal 'asdf', @env['HTTP_CONTENT_MD5']
  end

private

  def bin_reader(buf)
    buf.force_encoding(Encoding::BINARY) if buf.respond_to?(:force_encoding)
    Unicorn::ChunkedReader.new(@env, @rd, buf)
  end

end
