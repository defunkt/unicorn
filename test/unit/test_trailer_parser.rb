require 'test/unit'
require 'unicorn'
require 'unicorn/http11'
require 'unicorn/trailer_parser'

class TestTrailerParser < Test::Unit::TestCase

  def test_basic
    tp = Unicorn::TrailerParser.new('Content-MD5')
    env = {}
    assert ! tp.execute!(env, "Content-MD5: asdf")
    assert env.empty?
    assert tp.execute!(env, "Content-MD5: asdf\r\n")
    assert_equal 'asdf', env['CONTENT_MD5']
    assert_equal 1, env.size
  end

  def test_invalid_trailer
    tp = Unicorn::TrailerParser.new('Content-MD5')
    env = {}
    assert_raises(Unicorn::HttpParserError) {
      tp.execute!(env, "Content-MD: asdf\r\n")
    }
    assert env.empty?
  end

  def test_multiple_trailer
    tp = Unicorn::TrailerParser.new('Foo,Bar')
    env = {}
    buf = "Bar: a\r\nFoo: b\r\n"
    assert tp.execute!(env, buf)
    assert_equal 'a', env['BAR']
    assert_equal 'b', env['FOO']
  end

  def test_too_big_key
    tp = Unicorn::TrailerParser.new('Foo,Bar')
    env = {}
    buf = "Bar#{'a' * 1024}: a\r\nFoo: b\r\n"
    assert_raises(Unicorn::HttpParserError) { tp.execute!(env, buf) }
    assert env.empty?
  end

  def test_too_big_value
    tp = Unicorn::TrailerParser.new('Foo,Bar')
    env = {}
    buf = "Bar: #{'a' * (1024 * 1024)}: a\r\nFoo: b\r\n"
    assert_raises(Unicorn::HttpParserError) { tp.execute!(env, buf) }
    assert env.empty?
  end

end
