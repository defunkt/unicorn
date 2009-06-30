require 'test/unit'
require 'unicorn'
require 'tempfile'
require 'io/nonblock'
require 'digest/sha1'

class TestChunkedReader < Test::Unit::TestCase

  def setup
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
  end

  def test_eof1
    cr = bin_reader(@rd, "0\r\n")
    assert_raises(EOFError) { cr.readpartial(8192) }
  end

  def test_eof2
    cr = bin_reader(@rd, "0\r\n\r\n")
    assert_raises(EOFError) { cr.readpartial(8192) }
  end

  def test_readpartial1
    cr = bin_reader(@rd, "4\r\nasdf\r\n0\r\n")
    assert_equal 'asdf', cr.readpartial(8192)
    assert_raises(EOFError) { cr.readpartial(8192) }
  end

  def test_gets1
    cr = bin_reader(@rd, "4\r\nasdf\r\n0\r\n")
    STDOUT.sync = true
    assert_equal 'asdf', cr.gets
    assert_raises(EOFError) { cr.readpartial(8192) }
  end

  def test_gets2
    cr = bin_reader(@rd, "4\r\nasd\n\r\n0\r\n\r\n")
    assert_equal "asd\n", cr.gets
    assert_nil cr.gets
  end

  def test_gets3
    max = Unicorn::Const::CHUNK_SIZE * 2
    str = ('a' * max).freeze
    first = 5
    last = str.size - first
    cr = bin_reader(@rd,
      "#{'%x' % first}\r\n#{str[0, first]}\r\n" \
      "#{'%x' % last}\r\n#{str[-last, last]}\r\n" \
      "0\r\n")
    assert_equal str, cr.gets
    assert_nil cr.gets
  end

  def test_readpartial_gets_mixed1
    max = Unicorn::Const::CHUNK_SIZE * 2
    str = ('a' * max).freeze
    first = 5
    last = str.size - first
    cr = bin_reader(@rd,
      "#{'%x' % first}\r\n#{str[0, first]}\r\n" \
      "#{'%x' % last}\r\n#{str[-last, last]}\r\n" \
      "0\r\n")
    partial = cr.readpartial(16384)
    assert String === partial

    len = max - partial.size
    assert_equal(str[-len, len], cr.gets)
    assert_raises(EOFError) { cr.readpartial(1) }
    assert_nil cr.gets
  end

  def test_gets_mixed_readpartial
    max = 10
    str = ("z\n" * max).freeze
    first = 5
    last = str.size - first
    cr = bin_reader(@rd,
      "#{'%x' % first}\r\n#{str[0, first]}\r\n" \
      "#{'%x' % last}\r\n#{str[-last, last]}\r\n" \
      "0\r\n")
    assert_equal("z\n", cr.gets)
    assert_equal("z\n", cr.gets)
  end

  def test_dd
    cr = bin_reader(@rd, "6\r\nhello\n\r\n")
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
    assert_equal "hello\n", cr.gets
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

private

  def bin_reader(sock, buf)
    buf.force_encoding(Encoding::BINARY) if buf.respond_to?(:force_encoding)
    Unicorn::ChunkedReader.new(sock, buf)
  end

end
