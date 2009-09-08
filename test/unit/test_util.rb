# -*- encoding: binary -*-

require 'test/test_helper'
require 'tempfile'

class TestUtil < Test::Unit::TestCase

  EXPECT_FLAGS = File::WRONLY | File::APPEND
  def test_reopen_logs_noop
    tmp = Tempfile.new(nil)
    tmp.reopen(tmp.path, 'a')
    tmp.sync = true
    ext = tmp.external_encoding rescue nil
    int = tmp.internal_encoding rescue nil
    before = tmp.stat.inspect
    Unicorn::Util.reopen_logs
    assert_equal before, File.stat(tmp.path).inspect
    assert_equal ext, (tmp.external_encoding rescue nil)
    assert_equal int, (tmp.internal_encoding rescue nil)
    assert_nothing_raised { tmp.close! }
  end

  def test_reopen_logs_renamed
    tmp = Tempfile.new(nil)
    tmp_path = tmp.path.freeze
    tmp.reopen(tmp_path, 'a')
    tmp.sync = true
    ext = tmp.external_encoding rescue nil
    int = tmp.internal_encoding rescue nil
    before = tmp.stat.inspect
    to = Tempfile.new(nil)
    File.rename(tmp_path, to.path)
    assert ! File.exist?(tmp_path)
    Unicorn::Util.reopen_logs
    assert_equal tmp_path, tmp.path
    assert File.exist?(tmp_path)
    assert before != File.stat(tmp_path).inspect
    assert_equal tmp.stat.inspect, File.stat(tmp_path).inspect
    assert_equal ext, (tmp.external_encoding rescue nil)
    assert_equal int, (tmp.internal_encoding rescue nil)
    assert_equal(EXPECT_FLAGS, EXPECT_FLAGS & tmp.fcntl(Fcntl::F_GETFL))
    assert tmp.sync
    assert_nothing_raised { tmp.close! }
    assert_nothing_raised { to.close! }
  end

  def test_reopen_logs_renamed_with_encoding
    tmp = Tempfile.new(nil)
    tmp_path = tmp.path.dup.freeze
    Encoding.list.each { |encoding|
      File.open(tmp_path, "a:#{encoding.to_s}") { |fp|
        fp.sync = true
        assert_equal encoding, fp.external_encoding
        assert_nil fp.internal_encoding
        File.unlink(tmp_path)
        assert ! File.exist?(tmp_path)
        Unicorn::Util.reopen_logs
        assert_equal tmp_path, fp.path
        assert File.exist?(tmp_path)
        assert_equal fp.stat.inspect, File.stat(tmp_path).inspect
        assert_equal encoding, fp.external_encoding
        assert_nil fp.internal_encoding
        assert_equal(EXPECT_FLAGS, EXPECT_FLAGS & fp.fcntl(Fcntl::F_GETFL))
        assert fp.sync
      }
    }
    assert_nothing_raised { tmp.close! }
  end if STDIN.respond_to?(:external_encoding)

  def test_reopen_logs_renamed_with_internal_encoding
    tmp = Tempfile.new(nil)
    tmp_path = tmp.path.dup.freeze
    Encoding.list.each { |ext|
      Encoding.list.each { |int|
        next if ext == int
        File.open(tmp_path, "a:#{ext.to_s}:#{int.to_s}") { |fp|
          fp.sync = true
          assert_equal ext, fp.external_encoding
          assert_equal int, fp.internal_encoding
          File.unlink(tmp_path)
          assert ! File.exist?(tmp_path)
          Unicorn::Util.reopen_logs
          assert_equal tmp_path, fp.path
          assert File.exist?(tmp_path)
          assert_equal fp.stat.inspect, File.stat(tmp_path).inspect
          assert_equal ext, fp.external_encoding
          assert_equal int, fp.internal_encoding
          assert_equal(EXPECT_FLAGS, EXPECT_FLAGS & fp.fcntl(Fcntl::F_GETFL))
          assert fp.sync
        }
      }
    }
    assert_nothing_raised { tmp.close! }
  end if STDIN.respond_to?(:external_encoding)

end
