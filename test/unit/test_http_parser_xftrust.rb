# -*- encoding: binary -*-
require 'test/test_helper'

include Unicorn

class HttpParserXFTrustTest < Test::Unit::TestCase
  def setup
    assert HttpParser.x_forwarded_trust?
  end

  def test_xf_trust_false_xfp
    HttpParser.x_forwarded_trust = false
    parser = HttpParser.new
    parser.buf << "GET / HTTP/1.1\r\nHost: foo:\r\n" \
                  "X-Forwarded-Proto: https\r\n\r\n"
    env = parser.parse
    assert_kind_of Hash, env
    assert_equal 'foo', env['SERVER_NAME']
    assert_equal '80', env['SERVER_PORT']
    assert_equal 'http', env['rack.url_scheme']
  end

  def test_xf_trust_false_xfs
    HttpParser.x_forwarded_trust = false
    parser = HttpParser.new
    parser.buf << "GET / HTTP/1.1\r\nHost: foo:\r\n" \
                  "X-Forwarded-SSL: on\r\n\r\n"
    env = parser.parse
    assert_kind_of Hash, env
    assert_equal 'foo', env['SERVER_NAME']
    assert_equal '80', env['SERVER_PORT']
    assert_equal 'http', env['rack.url_scheme']
  end

  def teardown
    HttpParser.x_forwarded_trust = true
  end
end
