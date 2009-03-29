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

  def test_response_OFS_set
    old_ofs = $,
    $, = "\f\v"
    out = StringIO.new
    HttpResponse.write(out,[200, {"X-Whatever" => "stuff"}, ["cool"]])
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
    assert_match(/.* #{HTTP_STATUS_CODES[code]}$/, lines.first,
                 "wrong default reason phrase")
  end

  def test_rack_multivalue_headers
    out = StringIO.new
    HttpResponse.write(out,[200, {"X-Whatever" => "stuff\nbleh"}, []])
    assert out.closed?
    assert_match(/^X-Whatever: stuff\r\nX-Whatever: bleh\r\n/, out.string)
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

end
