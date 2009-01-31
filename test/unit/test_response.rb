# Copyright (c) 2005 Zed A. Shaw 
# You can redistribute it and/or modify it under the same terms as Ruby.
#
# Additional work donated by contributors.  See http://mongrel.rubyforge.org/attributions.html 
# for more information.

require 'test/test_helper'

include Mongrel

class ResponseTest < Test::Unit::TestCase
  
  def test_response_headers
    out = StringIO.new
    resp = HttpResponse.new(out,[200, {"X-Whatever" => "stuff"}, ["cool"]])
    resp.finished

    assert out.length > 0, "output didn't have data"
  end

  def test_response_200
    io = StringIO.new
    resp = HttpResponse.new(io, [200, {}, []])

    resp.finished
    assert io.length > 0, "output didn't have data"
  end

  def test_response_with_default_reason
    code = 400
    io = StringIO.new
    resp = HttpResponse.new(io, [code, {}, []])
    resp.start
    io.rewind
    assert_match(/.* #{HTTP_STATUS_CODES[code]}$/, io.readline.chomp, "wrong default reason phrase")
  end
end

