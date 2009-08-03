# coding: binary
require 'test/test_helper'
require 'digest/md5'

include Unicorn

class HttpParserNgTest < Test::Unit::TestCase

  def setup
    @parser = HttpParser.new
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
  end

  def test_identity_oneshot_header
    req = {}
    str = "PUT / HTTP/1.1\r\nContent-Length: 123\r\n\r\n"
    assert_equal req.object_id, @parser.headers(req, str).object_id
    assert_equal '123', req['CONTENT_LENGTH']
    assert_equal 0, str.size
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
    assert_nil @parser.read_body(tmp, str)
    assert_equal 0, str.size
    assert_equal tmp, body
    assert_equal "", @parser.read_body(tmp, str)
  end

  def test_identity_oneshot_header_with_body_partial
    str = "PUT / HTTP/1.1\r\nContent-Length: 123\r\n\r\na"
    assert_equal Hash, @parser.headers({}, str).class
    assert_equal 1, str.size
    assert_equal 'a', str
    tmp = ''
    assert_nil @parser.read_body(tmp, str)
    assert_equal "", str
    assert_equal "a", tmp
    str << ' ' * 122
    rv = @parser.read_body(tmp, str)
    assert_equal 122, tmp.size
    assert_nil rv
    assert_equal "", str
    assert_equal str.object_id, @parser.read_body(tmp, str).object_id
  end

  def test_identity_oneshot_header_with_body_slop
    str = "PUT / HTTP/1.1\r\nContent-Length: 1\r\n\r\naG"
    assert_equal Hash, @parser.headers({}, str).class
    assert_equal 2, str.size
    assert_equal 'aG', str
    tmp = ''
    assert_nil @parser.read_body(tmp, str)
    assert_equal "G", str
    assert_equal "G", @parser.read_body(tmp, str)
    assert_equal 1, tmp.size
    assert_equal "a", tmp
  end

  def test_chunked
    str = "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n"
    req = {}
    assert_equal req, @parser.headers(req, str)
    assert_equal 0, str.size
    tmp = ""
    assert_nil @parser.read_body(tmp, "6")
    assert_equal 0, tmp.size
    assert_nil @parser.read_body(tmp, rv = "\r\n")
    assert_equal 0, rv.size
    assert_equal 0, tmp.size
    tmp = ""
    assert_nil @parser.read_body(tmp, "..")
    assert_equal "..", tmp
    assert_nil @parser.read_body(tmp, "abcd\r\n0\r\n")
    assert_equal "abcd", tmp
    rv = "PUT"
    assert_equal rv.object_id, @parser.read_body(tmp, rv).object_id
    assert_equal "PUT", rv
  end

  def test_two_chunks
    str = "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n"
    req = {}
    assert_equal req, @parser.headers(req, str)
    assert_equal 0, str.size
    tmp = ""
    assert_nil @parser.read_body(tmp, "6")
    assert_equal 0, tmp.size
    assert_nil @parser.read_body(tmp, rv = "\r\n")
    assert_equal "", rv
    assert_equal 0, tmp.size
    tmp = ""
    assert_nil @parser.read_body(tmp, "..")
    assert_equal 2, tmp.size
    assert_equal "..", tmp
    assert_nil @parser.read_body(tmp, "abcd\r\n1")
    assert_equal "abcd", tmp
    assert_nil @parser.read_body(tmp, "\r")
    assert_equal "", tmp
    assert_nil @parser.read_body(tmp, "\n")
    assert_equal "", tmp
    assert_nil @parser.read_body(tmp, "z")
    assert_equal "z", tmp
    assert_nil @parser.read_body(tmp, "\r\n")
    assert_nil @parser.read_body(tmp, "0")
    assert_nil @parser.read_body(tmp, "\r")
    rv = @parser.read_body(tmp, buf = "\nGET")
    assert_equal "GET", rv
    assert_equal buf.object_id, rv.object_id
  end

  def test_big_chunk
    str = "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n" \
          "4000\r\nabcd"
    req = {}
    assert_equal req, @parser.headers(req, str)
    tmp = ''
    assert_nil @parser.read_body(tmp, str)
    assert_equal '', str
    str = ' ' * 16300
    assert_nil @parser.read_body(tmp, str)
    assert_equal '', str
    str = ' ' * 80
    assert_nil @parser.read_body(tmp, str)
    assert_equal '', str
    assert ! @parser.body_eof?
    assert_equal "", @parser.read_body(tmp, "\r\n0\r\n")
    assert @parser.body_eof?
  end

  def test_two_chunks_oneshot
    str = "PUT / HTTP/1.1\r\ntransfer-Encoding: chunked\r\n\r\n" \
          "1\r\na\r\n2\r\n..\r\n0\r\n"
    req = {}
    assert_equal req, @parser.headers(req, str)
    tmp = ''
    assert_nil @parser.read_body(tmp, str)
    assert_equal 'a..', tmp
    rv = @parser.read_body(tmp, str)
    assert_equal rv.object_id, str.object_id
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
    assert_nil @parser.read_body(tmp, str)
    assert_equal 'a..', tmp
    md5_b64 = [ Digest::MD5.digest(tmp) ].pack('m').strip.freeze
    rv = @parser.read_body(tmp, str)
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
  end

end
