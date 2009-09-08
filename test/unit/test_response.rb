# -*- encoding: binary -*-

# Copyright (c) 2005 Zed A. Shaw 
# You can redistribute it and/or modify it under the same terms as Ruby.
#
# Additional work donated by contributors.  See http://mongrel.rubyforge.org/attributions.html 
# for more information.

require 'test/test_helper'

include Unicorn

class ResponseTest < Test::Unit::TestCase
  
  def test_response_headers
    out = StringIO.new
    HttpResponse.write(out,[200, {"X-Whatever" => "stuff"}, ["cool"]])
    assert out.closed?

    assert out.length > 0, "output didn't have data"
  end

  def test_response_string_status
    out = StringIO.new
    HttpResponse.write(out,['200', {}, []])
    assert out.closed?
    assert out.length > 0, "output didn't have data"
    assert_equal 1, out.string.split(/\r\n/).grep(/^Status: 200 OK/).size
  end

  def test_response_OFS_set
    old_ofs = $,
    $, = "\f\v"
    out = StringIO.new
    HttpResponse.write(out,[200, {"X-k" => "cd","X-y" => "z"}, ["cool"]])
    assert out.closed?
    resp = out.string
    assert ! resp.include?("\f\v"), "output didn't use $, ($OFS)"
    ensure
      $, = old_ofs
  end

  def test_response_200
    io = StringIO.new
    HttpResponse.write(io, [200, {}, []])
    assert io.closed?
    assert io.length > 0, "output didn't have data"
  end

  def test_response_with_default_reason
    code = 400
    io = StringIO.new
    HttpResponse.write(io, [code, {}, []])
    assert io.closed?
    lines = io.string.split(/\r\n/)
    assert_match(/.* Bad Request$/, lines.first,
                 "wrong default reason phrase")
  end

  def test_rack_multivalue_headers
    out = StringIO.new
    HttpResponse.write(out,[200, {"X-Whatever" => "stuff\nbleh"}, []])
    assert out.closed?
    assert_match(/^X-Whatever: stuff\r\nX-Whatever: bleh\r\n/, out.string)
  end

  # Even though Rack explicitly forbids "Status" in the header hash,
  # some broken clients still rely on it
  def test_status_header_added
    out = StringIO.new
    HttpResponse.write(out,[200, {"X-Whatever" => "stuff"}, []])
    assert out.closed?
    assert_equal 1, out.string.split(/\r\n/).grep(/^Status: 200 OK/i).size
  end

  # we always favor the code returned by the application, since "Status"
  # in the header hash is not allowed by Rack (but not every app is
  # fully Rack-compliant).
  def test_status_header_ignores_app_hash
    out = StringIO.new
    header_hash = {"X-Whatever" => "stuff", 'StaTus' => "666" }
    HttpResponse.write(out,[200, header_hash, []])
    assert out.closed?
    assert_equal 1, out.string.split(/\r\n/).grep(/^Status: 200 OK/i).size
    assert_equal 1, out.string.split(/\r\n/).grep(/^Status:/i).size
  end

  def test_body_closed
    expect_body = %w(1 2 3 4).join("\n")
    body = StringIO.new(expect_body)
    body.rewind
    out = StringIO.new
    HttpResponse.write(out,[200, {}, body])
    assert out.closed?
    assert body.closed?
    assert_match(expect_body, out.string.split(/\r\n/).last)
  end

  def test_unknown_status_pass_through
    out = StringIO.new
    HttpResponse.write(out,["666 I AM THE BEAST", {}, [] ])
    assert out.closed?
    headers = out.string.split(/\r\n\r\n/).first.split(/\r\n/)
    assert %r{\AHTTP/\d\.\d 666 I AM THE BEAST\z}.match(headers[0])
    status = headers.grep(/\AStatus:/i).first
    assert status
    assert_equal "Status: 666 I AM THE BEAST", status
  end

end
