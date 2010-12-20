# -*- encoding: binary -*-

require 'test/test_helper'
require 'digest/md5'

include Unicorn

class HttpParserNgTest < Test::Unit::TestCase

  def setup
    HttpParser.keepalive_requests = HttpParser::KEEPALIVE_REQUESTS_DEFAULT
    @parser = HttpParser.new
  end

  def test_keepalive_requests_default_constant
    assert_kind_of Integer, HttpParser::KEEPALIVE_REQUESTS_DEFAULT
    assert HttpParser::KEEPALIVE_REQUESTS_DEFAULT >= 0
  end

  def test_keepalive_requests_setting
    HttpParser.keepalive_requests = 0
    assert_equal 0, HttpParser.keepalive_requests
    HttpParser.keepalive_requests = nil
    assert HttpParser.keepalive_requests >= 0xffffffff
    HttpParser.keepalive_requests = 1
    assert_equal 1, HttpParser.keepalive_requests
    HttpParser.keepalive_requests = 666
    assert_equal 666, HttpParser.keepalive_requests

    assert_raises(TypeError) { HttpParser.keepalive_requests = "666" }
    assert_raises(TypeError) { HttpParser.keepalive_requests = [] }
  end

  def test_keepalive_requests_with_next?
    req = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n".freeze
    expect = {
      "SERVER_NAME" => "example.com",
      "HTTP_HOST" => "example.com",
      "rack.url_scheme" => "http",
      "REQUEST_PATH" => "/",
      "SERVER_PROTOCOL" => "HTTP/1.1",
      "PATH_INFO" => "/",
      "HTTP_VERSION" => "HTTP/1.1",
      "REQUEST_URI" => "/",
      "SERVER_PORT" => "80",
      "REQUEST_METHOD" => "GET",
      "QUERY_STRING" => ""
    }.freeze
    HttpParser::KEEPALIVE_REQUESTS_DEFAULT.times do |nr|
      @parser.buf << req
      assert_equal expect, @parser.parse
      assert @parser.next?
    end
    @parser.buf << req
    assert_equal expect, @parser.parse
    assert ! @parser.next?
  end

  def test_fewer_keepalive_requests_with_next?
    HttpParser.keepalive_requests = 5
    @parser = HttpParser.new
    req = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n".freeze
    expect = {
      "SERVER_NAME" => "example.com",
      "HTTP_HOST" => "example.com",
      "rack.url_scheme" => "http",
      "REQUEST_PATH" => "/",
      "SERVER_PROTOCOL" => "HTTP/1.1",
      "PATH_INFO" => "/",
      "HTTP_VERSION" => "HTTP/1.1",
      "REQUEST_URI" => "/",
      "SERVER_PORT" => "80",
      "REQUEST_METHOD" => "GET",
      "QUERY_STRING" => ""
    }.freeze
    5.times do |nr|
      @parser.buf << req
      assert_equal expect, @parser.parse
      assert @parser.next?
    end
    @parser.buf << req
    assert_equal expect, @parser.parse
    assert ! @parser.next?
  end

  def test_default_keepalive_is_off
    assert ! @parser.keepalive?
    assert ! @parser.next?
    assert_nothing_raised do
      @parser.buf << "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
      @parser.parse
    end
    assert @parser.keepalive?
    @parser.reset
    assert ! @parser.keepalive?
    assert ! @parser.next?
  end

  def test_identity_byte_headers
    req = {}
    str = "PUT / HTTP/1.1\r\n"
    str << "Content-Length: 123\r\n"
    str << "\r"
    hdr = ""
    str.each_byte { |byte|
      assert_nil @parser.headers(req, hdr << byte.chr)
    }
    hdr << "\n"
    assert_equal req.object_id, @parser.headers(req, hdr).object_id
    assert_equal '123', req['CONTENT_LENGTH']
    assert_equal 0, hdr.size
    assert ! @parser.keepalive?
    assert @parser.headers?
    assert_equal 123, @parser.content_length
    dst = ""
    buf = '.' * 123
    @parser.filter_body(dst, buf)
    assert_equal '.' * 123, dst
    assert_equal "", buf
    assert @parser.keepalive?
  end

  def test_identity_step_headers
    req = {}
    str = "PUT / HTTP/1.1\r\n"
    assert ! @parser.headers(req, str)
    str << "Content-Length: 123\r\n"
    assert ! @parser.headers(req, str)
    str << "\r\n"
    assert_equal req.object_id, @parser.headers(req, str).object_id
    assert_equal '123', req['CONTENT_LENGTH']
    assert_equal 0, str.size
    assert ! @parser.keepalive?
    assert @parser.headers?
    dst = ""
    buf = '.' * 123
    @parser.filter_body(dst, buf)
    assert_equal '.' * 123, dst
    assert_equal "", buf
    assert @parser.keepalive?
  end

  def test_identity_oneshot_header
    req = {}
    str = "PUT / HTTP/1.1\r\nContent-Length: 123\r\n\r\n"
    assert_equal req.object_id, @parser.headers(req, str).object_id
    assert_equal '123', req['CONTENT_LENGTH']
    assert_equal 0, str.size
    assert ! @parser.keepalive?
    assert @parser.headers?
    dst = ""
    buf = '.' * 123
    @parser.filter_body(dst, buf)
    assert_equal '.' * 123, dst
    assert_equal "", buf
  end

  def test_identity_oneshot_header_with_body
    body = ('a' * 123).freeze
    req = {}
    str = "PUT / HTTP/1.1\r\n" \
          "Content-Length: #{body.length}\r\n" \
          "\r\n#{body}"
    assert_equal req.object_id, @parser.headers(req, str).object_id
    assert_equal '123', req['CONTENT_LENGTH']
    assert_equal 123, str.size
    assert_equal body, str
    tmp = ''
    assert_nil @parser.filter_body(tmp, str)
    assert_equal 0, str.size
    assert_equal tmp, body
    assert_equal "", @parser.filter_body(tmp, str)
    assert @parser.keepalive?
  end

  def test_identity_oneshot_header_with_body_partial
    str = "PUT / HTTP/1.1\r\nContent-Length: 123\r\n\r\na"
    assert_equal Hash, @parser.headers({}, str).class
    assert_equal 1, str.size
    assert_equal 'a', str
    tmp = ''
    assert_nil @parser.filter_body(tmp, str)
    assert_equal "", str
    assert_equal "a", tmp
    str << ' ' * 122
    rv = @parser.filter_body(tmp, str)
    assert_equal 122, tmp.size
    assert_nil rv
    assert_equal "", str
    assert_equal str.object_id, @parser.filter_body(tmp, str).object_id
    assert @parser.keepalive?
  end

  def test_identity_oneshot_header_with_body_slop
    str = "PUT / HTTP/1.1\r\nContent-Length: 1\r\n\r\naG"
    assert_equal Hash, @parser.headers({}, str).class
    assert_equal 2, str.size
    assert_equal 'aG', str
    tmp = ''
    assert_nil @parser.filter_body(tmp, str)
    assert_equal "G", str
    assert_equal "G", @parser.filter_body(tmp, str)
    assert_equal 1, tmp.size
    assert_equal "a", tmp
    assert @parser.keepalive?
  end

  def test_chunked
    str = "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n"
    req = {}
    assert_equal req, @parser.headers(req, str)
    assert_equal 0, str.size
    tmp = ""
    assert_nil @parser.filter_body(tmp, "6")
    assert_equal 0, tmp.size
    assert_nil @parser.filter_body(tmp, rv = "\r\n")
    assert_equal 0, rv.size
    assert_equal 0, tmp.size
    tmp = ""
    assert_nil @parser.filter_body(tmp, "..")
    assert_equal "..", tmp
    assert_nil @parser.filter_body(tmp, "abcd\r\n0\r\n")
    assert_equal "abcd", tmp
    rv = "PUT"
    assert_equal rv.object_id, @parser.filter_body(tmp, rv).object_id
    assert_equal "PUT", rv
    assert ! @parser.keepalive?
    rv << "TY: FOO\r\n\r\n"
    assert_equal req, @parser.trailers(req, rv)
    assert_equal "FOO", req["HTTP_PUTTY"]
    assert @parser.keepalive?
  end

  def test_two_chunks
    str = "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n"
    req = {}
    assert_equal req, @parser.headers(req, str)
    assert_equal 0, str.size
    tmp = ""
    assert_nil @parser.filter_body(tmp, "6")
    assert_equal 0, tmp.size
    assert_nil @parser.filter_body(tmp, rv = "\r\n")
    assert_equal "", rv
    assert_equal 0, tmp.size
    tmp = ""
    assert_nil @parser.filter_body(tmp, "..")
    assert_equal 2, tmp.size
    assert_equal "..", tmp
    assert_nil @parser.filter_body(tmp, "abcd\r\n1")
    assert_equal "abcd", tmp
    assert_nil @parser.filter_body(tmp, "\r")
    assert_equal "", tmp
    assert_nil @parser.filter_body(tmp, "\n")
    assert_equal "", tmp
    assert_nil @parser.filter_body(tmp, "z")
    assert_equal "z", tmp
    assert_nil @parser.filter_body(tmp, "\r\n")
    assert_nil @parser.filter_body(tmp, "0")
    assert_nil @parser.filter_body(tmp, "\r")
    rv = @parser.filter_body(tmp, buf = "\nGET")
    assert_equal "GET", rv
    assert_equal buf.object_id, rv.object_id
    assert ! @parser.keepalive?
  end

  def test_big_chunk
    str = "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n" \
          "4000\r\nabcd"
    req = {}
    assert_equal req, @parser.headers(req, str)
    tmp = ''
    assert_nil @parser.filter_body(tmp, str)
    assert_equal '', str
    str = ' ' * 16300
    assert_nil @parser.filter_body(tmp, str)
    assert_equal '', str
    str = ' ' * 80
    assert_nil @parser.filter_body(tmp, str)
    assert_equal '', str
    assert ! @parser.body_eof?
    assert_equal "", @parser.filter_body(tmp, "\r\n0\r\n")
    assert_equal "", tmp
    assert @parser.body_eof?
    assert_equal req, @parser.trailers(req, moo = "\r\n")
    assert_equal "", moo
    assert @parser.body_eof?
    assert @parser.keepalive?
  end

  def test_two_chunks_oneshot
    str = "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n" \
          "1\r\na\r\n2\r\n..\r\n0\r\n"
    req = {}
    assert_equal req, @parser.headers(req, str)
    tmp = ''
    assert_nil @parser.filter_body(tmp, str)
    assert_equal 'a..', tmp
    rv = @parser.filter_body(tmp, str)
    assert_equal rv.object_id, str.object_id
    assert ! @parser.keepalive?
  end

  def test_chunks_bytewise
    chunked = "10\r\nabcdefghijklmnop\r\n11\r\n0123456789abcdefg\r\n0\r\n"
    str = "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n#{chunked}"
    req = {}
    assert_equal req, @parser.headers(req, str)
    assert_equal chunked, str
    tmp = ''
    buf = ''
    body = ''
    str = str[0..-2]
    str.each_byte { |byte|
      assert_nil @parser.filter_body(tmp, buf << byte.chr)
      body << tmp
    }
    assert_equal 'abcdefghijklmnop0123456789abcdefg', body
    rv = @parser.filter_body(tmp, buf << "\n")
    assert_equal rv.object_id, buf.object_id
    assert ! @parser.keepalive?
  end

  def test_trailers
    str = "PUT / HTTP/1.1\r\n" \
          "Trailer: Content-MD5\r\n" \
          "transfer-Encoding: chunked\r\n\r\n" \
          "1\r\na\r\n2\r\n..\r\n0\r\n"
    req = {}
    assert_equal req, @parser.headers(req, str)
    assert_equal 'Content-MD5', req['HTTP_TRAILER']
    assert_nil req['HTTP_CONTENT_MD5']
    tmp = ''
    assert_nil @parser.filter_body(tmp, str)
    assert_equal 'a..', tmp
    md5_b64 = [ Digest::MD5.digest(tmp) ].pack('m').strip.freeze
    rv = @parser.filter_body(tmp, str)
    assert_equal rv.object_id, str.object_id
    assert_equal '', str
    md5_hdr = "Content-MD5: #{md5_b64}\r\n".freeze
    str << md5_hdr
    assert_nil @parser.trailers(req, str)
    assert_equal md5_b64, req['HTTP_CONTENT_MD5']
    assert_equal "CONTENT_MD5: #{md5_b64}\r\n", str
    assert_nil @parser.trailers(req, str << "\r")
    assert_equal req, @parser.trailers(req, str << "\nGET / ")
    assert_equal "GET / ", str
    assert @parser.keepalive?
  end

  def test_trailers_slowly
    str = "PUT / HTTP/1.1\r\n" \
          "Trailer: Content-MD5\r\n" \
          "transfer-Encoding: chunked\r\n\r\n" \
          "1\r\na\r\n2\r\n..\r\n0\r\n"
    req = {}
    assert_equal req, @parser.headers(req, str)
    assert_equal 'Content-MD5', req['HTTP_TRAILER']
    assert_nil req['HTTP_CONTENT_MD5']
    tmp = ''
    assert_nil @parser.filter_body(tmp, str)
    assert_equal 'a..', tmp
    md5_b64 = [ Digest::MD5.digest(tmp) ].pack('m').strip.freeze
    rv = @parser.filter_body(tmp, str)
    assert_equal rv.object_id, str.object_id
    assert_equal '', str
    assert_nil @parser.trailers(req, str)
    md5_hdr = "Content-MD5: #{md5_b64}\r\n".freeze
    md5_hdr.each_byte { |byte|
      str << byte.chr
      assert_nil @parser.trailers(req, str)
    }
    assert_equal md5_b64, req['HTTP_CONTENT_MD5']
    assert_equal "CONTENT_MD5: #{md5_b64}\r\n", str
    assert_nil @parser.trailers(req, str << "\r")
    assert_equal req, @parser.trailers(req, str << "\n")
  end

  def test_max_chunk
    str = "PUT / HTTP/1.1\r\n" \
          "transfer-Encoding: chunked\r\n\r\n" \
          "#{HttpParser::CHUNK_MAX.to_s(16)}\r\na\r\n2\r\n..\r\n0\r\n"
    req = {}
    assert_equal req, @parser.headers(req, str)
    assert_nil @parser.content_length
    assert_nothing_raised { @parser.filter_body('', str) }
    assert ! @parser.keepalive?
  end

  def test_max_body
    n = HttpParser::LENGTH_MAX
    str = "PUT / HTTP/1.1\r\nContent-Length: #{n}\r\n\r\n"
    req = {}
    assert_nothing_raised { @parser.headers(req, str) }
    assert_equal n, req['CONTENT_LENGTH'].to_i
    assert ! @parser.keepalive?
  end

  def test_overflow_chunk
    n = HttpParser::CHUNK_MAX + 1
    str = "PUT / HTTP/1.1\r\n" \
          "transfer-Encoding: chunked\r\n\r\n" \
          "#{n.to_s(16)}\r\na\r\n2\r\n..\r\n0\r\n"
    req = {}
    assert_equal req, @parser.headers(req, str)
    assert_nil @parser.content_length
    assert_raise(HttpParserError) { @parser.filter_body('', str) }
  end

  def test_overflow_content_length
    n = HttpParser::LENGTH_MAX + 1
    str = "PUT / HTTP/1.1\r\nContent-Length: #{n}\r\n\r\n"
    assert_raise(HttpParserError) { @parser.headers({}, str) }
  end

  def test_bad_chunk
    str = "PUT / HTTP/1.1\r\n" \
          "transfer-Encoding: chunked\r\n\r\n" \
          "#zzz\r\na\r\n2\r\n..\r\n0\r\n"
    req = {}
    assert_equal req, @parser.headers(req, str)
    assert_nil @parser.content_length
    assert_raise(HttpParserError) { @parser.filter_body('', str) }
  end

  def test_bad_content_length
    str = "PUT / HTTP/1.1\r\nContent-Length: 7ff\r\n\r\n"
    assert_raise(HttpParserError) { @parser.headers({}, str) }
  end

  def test_bad_trailers
    str = "PUT / HTTP/1.1\r\n" \
          "Trailer: Transfer-Encoding\r\n" \
          "transfer-Encoding: chunked\r\n\r\n" \
          "1\r\na\r\n2\r\n..\r\n0\r\n"
    req = {}
    assert_equal req, @parser.headers(req, str)
    assert_equal 'Transfer-Encoding', req['HTTP_TRAILER']
    tmp = ''
    assert_nil @parser.filter_body(tmp, str)
    assert_equal 'a..', tmp
    assert_equal '', str
    str << "Transfer-Encoding: identity\r\n\r\n"
    assert_raise(HttpParserError) { @parser.trailers(req, str) }
  end

  def test_repeat_headers
    str = "PUT / HTTP/1.1\r\n" \
          "Trailer: Content-MD5\r\n" \
          "Trailer: Content-SHA1\r\n" \
          "transfer-Encoding: chunked\r\n\r\n" \
          "1\r\na\r\n2\r\n..\r\n0\r\n"
    req = {}
    assert_equal req, @parser.headers(req, str)
    assert_equal 'Content-MD5,Content-SHA1', req['HTTP_TRAILER']
    assert ! @parser.keepalive?
  end

  def test_parse_simple_request
    parser = HttpParser.new
    req = {}
    http = "GET /read-rfc1945-if-you-dont-believe-me\r\n"
    assert_equal req, parser.headers(req, http)
    assert_equal '', http
    expect = {
      "SERVER_NAME"=>"localhost",
      "rack.url_scheme"=>"http",
      "REQUEST_PATH"=>"/read-rfc1945-if-you-dont-believe-me",
      "PATH_INFO"=>"/read-rfc1945-if-you-dont-believe-me",
      "REQUEST_URI"=>"/read-rfc1945-if-you-dont-believe-me",
      "SERVER_PORT"=>"80",
      "SERVER_PROTOCOL"=>"HTTP/0.9",
      "REQUEST_METHOD"=>"GET",
      "QUERY_STRING"=>""
    }
    assert_equal expect, req
    assert ! parser.headers?
  end

  def test_path_info_semicolon
    qs = "QUERY_STRING"
    pi = "PATH_INFO"
    req = {}
    str = "GET %s HTTP/1.1\r\nHost: example.com\r\n\r\n"
    {
      "/1;a=b?c=d&e=f" => { qs => "c=d&e=f", pi => "/1;a=b" },
      "/1?c=d&e=f" => { qs => "c=d&e=f", pi => "/1" },
      "/1;a=b" => { qs => "", pi => "/1;a=b" },
      "/1;a=b?" => { qs => "", pi => "/1;a=b" },
      "/1?a=b;c=d&e=f" => { qs => "a=b;c=d&e=f", pi => "/1" },
      "*" => { qs => "", pi => "" },
    }.each do |uri,expect|
      assert_equal req, @parser.headers(req.clear, str % [ uri ])
      req = req.dup
      @parser.reset
      assert_equal uri, req["REQUEST_URI"], "REQUEST_URI mismatch"
      assert_equal expect[qs], req[qs], "#{qs} mismatch"
      assert_equal expect[pi], req[pi], "#{pi} mismatch"
      next if uri == "*"
      uri = URI.parse("http://example.com#{uri}")
      assert_equal uri.query.to_s, req[qs], "#{qs} mismatch URI.parse disagrees"
      assert_equal uri.path, req[pi], "#{pi} mismatch URI.parse disagrees"
    end
  end

  def test_path_info_semicolon_absolute
    qs = "QUERY_STRING"
    pi = "PATH_INFO"
    req = {}
    str = "GET http://example.com%s HTTP/1.1\r\nHost: www.example.com\r\n\r\n"
    {
      "/1;a=b?c=d&e=f" => { qs => "c=d&e=f", pi => "/1;a=b" },
      "/1?c=d&e=f" => { qs => "c=d&e=f", pi => "/1" },
      "/1;a=b" => { qs => "", pi => "/1;a=b" },
      "/1;a=b?" => { qs => "", pi => "/1;a=b" },
      "/1?a=b;c=d&e=f" => { qs => "a=b;c=d&e=f", pi => "/1" },
    }.each do |uri,expect|
      assert_equal req, @parser.headers(req.clear, str % [ uri ])
      req = req.dup
      @parser.reset
      assert_equal uri, req["REQUEST_URI"], "REQUEST_URI mismatch"
      assert_equal "example.com", req["HTTP_HOST"], "Host: mismatch"
      assert_equal expect[qs], req[qs], "#{qs} mismatch"
      assert_equal expect[pi], req[pi], "#{pi} mismatch"
    end
  end

  def test_negative_content_length
    req = {}
    str = "PUT / HTTP/1.1\r\n" \
          "Content-Length: -1\r\n" \
          "\r\n"
    assert_raises(HttpParserError) do
      @parser.headers(req, str)
    end
  end

  def test_invalid_content_length
    req = {}
    str = "PUT / HTTP/1.1\r\n" \
          "Content-Length: zzzzz\r\n" \
          "\r\n"
    assert_raises(HttpParserError) do
      @parser.headers(req, str)
    end
  end

  def test_backtrace_is_empty
    begin
      @parser.headers({}, "AAADFSFDSFD\r\n\r\n")
      assert false, "should never get here line:#{__LINE__}"
    rescue HttpParserError => e
      assert_equal [], e.backtrace
      return
    end
    assert false, "should never get here line:#{__LINE__}"
  end

  def test_ignore_version_header
    http = "GET / HTTP/1.1\r\nVersion: hello\r\n\r\n"
    req = {}
    assert_equal req, @parser.headers(req, http)
    assert_equal '', http
    expect = {
      "SERVER_NAME" => "localhost",
      "rack.url_scheme" => "http",
      "REQUEST_PATH" => "/",
      "SERVER_PROTOCOL" => "HTTP/1.1",
      "PATH_INFO" => "/",
      "HTTP_VERSION" => "HTTP/1.1",
      "REQUEST_URI" => "/",
      "SERVER_PORT" => "80",
      "REQUEST_METHOD" => "GET",
      "QUERY_STRING" => ""
    }
    assert_equal expect, req
  end

  def test_pipelined_requests
    host = "example.com"
    expect = {
      "HTTP_HOST" => host,
      "SERVER_NAME" => host,
      "REQUEST_PATH" => "/",
      "rack.url_scheme" => "http",
      "SERVER_PROTOCOL" => "HTTP/1.1",
      "PATH_INFO" => "/",
      "HTTP_VERSION" => "HTTP/1.1",
      "REQUEST_URI" => "/",
      "SERVER_PORT" => "80",
      "REQUEST_METHOD" => "GET",
      "QUERY_STRING" => ""
    }
    req1 = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
    req2 = "GET / HTTP/1.1\r\nHost: www.example.com\r\n\r\n"
    @parser.buf << (req1 + req2)
    env1 = @parser.parse.dup
    assert_equal expect, env1
    assert_equal req2, @parser.buf
    assert ! @parser.env.empty?
    assert @parser.next?
    assert_equal expect, @parser.env
    env2 = @parser.parse.dup
    host.replace "www.example.com"
    assert_equal "www.example.com", expect["HTTP_HOST"]
    assert_equal "www.example.com", expect["SERVER_NAME"]
    assert_equal expect, env2
    assert_equal "", @parser.buf
  end
end
