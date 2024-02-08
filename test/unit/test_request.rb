# -*- encoding: binary -*-
# frozen_string_literal: false

# Copyright (c) 2009 Eric Wong
# You can redistribute it and/or modify it under the same terms as Ruby 1.8 or
# the GPLv2+ (GPLv3+ preferred)

require './test/test_helper'

include Unicorn

class RequestTest < Test::Unit::TestCase

  MockRequest = Class.new(StringIO)

  AI = Addrinfo.new(Socket.sockaddr_un('/unicorn/sucks'))

  def setup
    @request = HttpRequest.new
    @app = lambda do |env|
      [ 200, { 'content-length' => '0', 'content-type' => 'text/plain' }, [] ]
    end
    @lint = Rack::Lint.new(@app)
  end

  def test_options
    client = MockRequest.new("OPTIONS * HTTP/1.1\r\n" \
                             "Host: foo\r\n\r\n")
    env = @request.read_headers(client, AI)
    assert_equal '', env['REQUEST_PATH']
    assert_equal '', env['PATH_INFO']
    assert_equal '*', env['REQUEST_URI']
    assert_kind_of Array, @lint.call(env)
  end

  def test_absolute_uri_with_query
    client = MockRequest.new("GET http://e:3/x?y=z HTTP/1.1\r\n" \
                             "Host: foo\r\n\r\n")
    env = @request.read_headers(client, AI)
    assert_equal '/x', env['REQUEST_PATH']
    assert_equal '/x', env['PATH_INFO']
    assert_equal 'y=z', env['QUERY_STRING']
    assert_kind_of Array, @lint.call(env)
  end

  def test_absolute_uri_with_fragment
    client = MockRequest.new("GET http://e:3/x#frag HTTP/1.1\r\n" \
                             "Host: foo\r\n\r\n")
    env = @request.read_headers(client, AI)
    assert_equal '/x', env['REQUEST_PATH']
    assert_equal '/x', env['PATH_INFO']
    assert_equal '', env['QUERY_STRING']
    assert_equal 'frag', env['FRAGMENT']
    assert_kind_of Array, @lint.call(env)
  end

  def test_absolute_uri_with_query_and_fragment
    client = MockRequest.new("GET http://e:3/x?a=b#frag HTTP/1.1\r\n" \
                             "Host: foo\r\n\r\n")
    env = @request.read_headers(client, AI)
    assert_equal '/x', env['REQUEST_PATH']
    assert_equal '/x', env['PATH_INFO']
    assert_equal 'a=b', env['QUERY_STRING']
    assert_equal 'frag', env['FRAGMENT']
    assert_kind_of Array, @lint.call(env)
  end

  def test_absolute_uri_unsupported_schemes
    %w(ssh+http://e/ ftp://e/x http+ssh://e/x).each do |abs_uri|
      client = MockRequest.new("GET #{abs_uri} HTTP/1.1\r\n" \
                               "Host: foo\r\n\r\n")
      assert_raises(HttpParserError) { @request.read_headers(client, AI) }
    end
  end

  def test_x_forwarded_proto_https
    client = MockRequest.new("GET / HTTP/1.1\r\n" \
                             "X-Forwarded-Proto: https\r\n" \
                             "Host: foo\r\n\r\n")
    env = @request.read_headers(client, AI)
    assert_equal "https", env['rack.url_scheme']
    assert_kind_of Array, @lint.call(env)
  end

  def test_x_forwarded_proto_http
    client = MockRequest.new("GET / HTTP/1.1\r\n" \
                             "X-Forwarded-Proto: http\r\n" \
                             "Host: foo\r\n\r\n")
    env = @request.read_headers(client, AI)
    assert_equal "http", env['rack.url_scheme']
    assert_kind_of Array, @lint.call(env)
  end

  def test_x_forwarded_proto_invalid
    client = MockRequest.new("GET / HTTP/1.1\r\n" \
                             "X-Forwarded-Proto: ftp\r\n" \
                             "Host: foo\r\n\r\n")
    env = @request.read_headers(client, AI)
    assert_equal "http", env['rack.url_scheme']
    assert_kind_of Array, @lint.call(env)
  end

  def test_rack_lint_get
    client = MockRequest.new("GET / HTTP/1.1\r\nHost: foo\r\n\r\n")
    env = @request.read_headers(client, AI)
    assert_equal "http", env['rack.url_scheme']
    assert_equal '127.0.0.1', env['REMOTE_ADDR']
    assert_kind_of Array, @lint.call(env)
  end

  def test_no_content_stringio
    client = MockRequest.new("GET / HTTP/1.1\r\nHost: foo\r\n\r\n")
    env = @request.read_headers(client, AI)
    assert_equal StringIO, env['rack.input'].class
  end

  def test_zero_content_stringio
    client = MockRequest.new("PUT / HTTP/1.1\r\n" \
                             "Content-Length: 0\r\n" \
                             "Host: foo\r\n\r\n")
    env = @request.read_headers(client, AI)
    assert_equal StringIO, env['rack.input'].class
  end

  def test_real_content_not_stringio
    client = MockRequest.new("PUT / HTTP/1.1\r\n" \
                             "Content-Length: 1\r\n" \
                             "Host: foo\r\n\r\n")
    env = @request.read_headers(client, AI)
    assert_equal Unicorn::TeeInput, env['rack.input'].class
  end

  def test_rack_lint_put
    client = MockRequest.new(
      "PUT / HTTP/1.1\r\n" \
      "Host: foo\r\n" \
      "Content-Length: 5\r\n" \
      "\r\n" \
      "abcde")
    env = @request.read_headers(client, AI)
    assert ! env.include?(:http_body)
    assert_kind_of Array, @lint.call(env)
  end

  def test_rack_lint_big_put
    count = 100
    bs = 0x10000
    buf = (' ' * bs).freeze
    length = bs * count
    client = Tempfile.new('big_put')
    client.syswrite(
      "PUT / HTTP/1.1\r\n" \
      "Host: foo\r\n" \
      "Content-Length: #{length}\r\n" \
      "\r\n")
    count.times { assert_equal bs, client.syswrite(buf) }
    assert_equal 0, client.sysseek(0)
    env = @request.read_headers(client, AI)
    assert ! env.include?(:http_body)
    assert_equal length, env['rack.input'].size
    count.times {
      tmp = env['rack.input'].read(bs)
      tmp << env['rack.input'].read(bs - tmp.size) if tmp.size != bs
      assert_equal buf, tmp
    }
    assert_nil env['rack.input'].read(bs)
    env['rack.input'].rewind
    assert_kind_of Array, @lint.call(env)
  end
end
