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

    assert out.length > 0, "output didn't have data"
  end

  def test_response_200
    io = StringIO.new
    HttpResponse.write(io, [200, {}, []])
    assert io.length > 0, "output didn't have data"
  end

  def test_response_with_default_reason
    code = 400
    io = StringIO.new
    HttpResponse.write(io, [code, {}, []])
    io.rewind
    assert_match(/.* #{HTTP_STATUS_CODES[code]}$/, io.readline.chomp, "wrong default reason phrase")
  end
end

