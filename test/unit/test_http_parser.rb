# Copyright (c) 2005 Zed A. Shaw 
# You can redistribute it and/or modify it under the same terms as Ruby.
#
# Additional work donated by contributors.  See http://mongrel.rubyforge.org/attributions.html
# for more information.

require 'test/test_helper'

include Unicorn

class HttpParserTest < Test::Unit::TestCase
    
  def test_parse_simple
    parser = HttpParser.new
    req = {}
    http = "GET / HTTP/1.1\r\n\r\n"
    assert parser.execute(req, http)

    assert_equal 'HTTP/1.1', req['SERVER_PROTOCOL']
    assert_equal '/', req['REQUEST_PATH']
    assert_equal 'HTTP/1.1', req['HTTP_VERSION']
    assert_equal '/', req['REQUEST_URI']
    assert_equal 'GET', req['REQUEST_METHOD']
    assert_nil req['FRAGMENT']
    assert_nil req['QUERY_STRING']

    parser.reset
    req.clear

    assert ! parser.execute(req, "G")
    assert req.empty?

    # try parsing again to ensure we were reset correctly
    http = "GET /hello-world HTTP/1.1\r\n\r\n"
    assert parser.execute(req, http)

    assert_equal 'HTTP/1.1', req['SERVER_PROTOCOL']
    assert_equal '/hello-world', req['REQUEST_PATH']
    assert_equal 'HTTP/1.1', req['HTTP_VERSION']
    assert_equal '/hello-world', req['REQUEST_URI']
    assert_equal 'GET', req['REQUEST_METHOD']
    assert_nil req['FRAGMENT']
    assert_nil req['QUERY_STRING']
  end

  def test_parse_strange_headers
    parser = HttpParser.new
    req = {}
    should_be_good = "GET / HTTP/1.1\r\naaaaaaaaaaaaa:++++++++++\r\n\r\n"
    assert parser.execute(req, should_be_good)

    # ref: http://thread.gmane.org/gmane.comp.lang.ruby.Unicorn.devel/37/focus=45
    # (note we got 'pen' mixed up with 'pound' in that thread,
    # but the gist of it is still relevant: these nasty headers are irrelevant
    #
    # nasty_pound_header = "GET / HTTP/1.1\r\nX-SSL-Bullshit:   -----BEGIN CERTIFICATE-----\r\n\tMIIFbTCCBFWgAwIBAgICH4cwDQYJKoZIhvcNAQEFBQAwcDELMAkGA1UEBhMCVUsx\r\n\tETAPBgNVBAoTCGVTY2llbmNlMRIwEAYDVQQLEwlBdXRob3JpdHkxCzAJBgNVBAMT\r\n\tAkNBMS0wKwYJKoZIhvcNAQkBFh5jYS1vcGVyYXRvckBncmlkLXN1cHBvcnQuYWMu\r\n\tdWswHhcNMDYwNzI3MTQxMzI4WhcNMDcwNzI3MTQxMzI4WjBbMQswCQYDVQQGEwJV\r\n\tSzERMA8GA1UEChMIZVNjaWVuY2UxEzARBgNVBAsTCk1hbmNoZXN0ZXIxCzAJBgNV\r\n\tBAcTmrsogriqMWLAk1DMRcwFQYDVQQDEw5taWNoYWVsIHBhcmQYJKoZIhvcNAQEB\r\n\tBQADggEPADCCAQoCggEBANPEQBgl1IaKdSS1TbhF3hEXSl72G9J+WC/1R64fAcEF\r\n\tW51rEyFYiIeZGx/BVzwXbeBoNUK41OK65sxGuflMo5gLflbwJtHBRIEKAfVVp3YR\r\n\tgW7cMA/s/XKgL1GEC7rQw8lIZT8RApukCGqOVHSi/F1SiFlPDxuDfmdiNzL31+sL\r\n\t0iwHDdNkGjy5pyBSB8Y79dsSJtCW/iaLB0/n8Sj7HgvvZJ7x0fr+RQjYOUUfrePP\r\n\tu2MSpFyf+9BbC/aXgaZuiCvSR+8Snv3xApQY+fULK/xY8h8Ua51iXoQ5jrgu2SqR\r\n\twgA7BUi3G8LFzMBl8FRCDYGUDy7M6QaHXx1ZWIPWNKsCAwEAAaOCAiQwggIgMAwG\r\n\tA1UdEwEB/wQCMAAwEQYJYIZIAYb4QgEBBAQDAgWgMA4GA1UdDwEB/wQEAwID6DAs\r\n\tBglghkgBhvhCAQ0EHxYdVUsgZS1TY2llbmNlIFVzZXIgQ2VydGlmaWNhdGUwHQYD\r\n\tVR0OBBYEFDTt/sf9PeMaZDHkUIldrDYMNTBZMIGaBgNVHSMEgZIwgY+AFAI4qxGj\r\n\tloCLDdMVKwiljjDastqooXSkcjBwMQswCQYDVQQGEwJVSzERMA8GA1UEChMIZVNj\r\n\taWVuY2UxEjAQBgNVBAsTCUF1dGhvcml0eTELMAkGA1UEAxMCQ0ExLTArBgkqhkiG\r\n\t9w0BCQEWHmNhLW9wZXJhdG9yQGdyaWQtc3VwcG9ydC5hYy51a4IBADApBgNVHRIE\r\n\tIjAggR5jYS1vcGVyYXRvckBncmlkLXN1cHBvcnQuYWMudWswGQYDVR0gBBIwEDAO\r\n\tBgwrBgEEAdkvAQEBAQYwPQYJYIZIAYb4QgEEBDAWLmh0dHA6Ly9jYS5ncmlkLXN1\r\n\tcHBvcnQuYWMudmT4sopwqlBWsvcHViL2NybC9jYWNybC5jcmwwPQYJYIZIAYb4QgEDBDAWLmh0\r\n\tdHA6Ly9jYS5ncmlkLXN1cHBvcnQuYWMudWsvcHViL2NybC9jYWNybC5jcmwwPwYD\r\n\tVR0fBDgwNjA0oDKgMIYuaHR0cDovL2NhLmdyaWQt5hYy51ay9wdWIv\r\n\tY3JsL2NhY3JsLmNybDANBgkqhkiG9w0BAQUFAAOCAQEAS/U4iiooBENGW/Hwmmd3\r\n\tXCy6Zrt08YjKCzGNjorT98g8uGsqYjSxv/hmi0qlnlHs+k/3Iobc3LjS5AMYr5L8\r\n\tUO7OSkgFFlLHQyC9JzPfmLCAugvzEbyv4Olnsr8hbxF1MbKZoQxUZtMVu29wjfXk\r\n\thTeApBv7eaKCWpSp7MCbvgzm74izKhu3vlDk9w6qVrxePfGgpKPqfHiOoGhFnbTK\r\n\twTC6o2xq5y0qZ03JonF7OJspEd3I5zKY3E+ov7/ZhW6DqT8UFvsAdjvQbXyhV8Eu\r\n\tYhixw1aKEPzNjNowuIseVogKOLXxWI5vAi5HgXdS0/ES5gDGsABo4fqovUKlgop3\r\n\tRA==\r\n\t-----END CERTIFICATE-----\r\n\r\n"
    # parser = HttpParser.new
    # req = {}
    # assert parser.execute(req, nasty_pound_header, 0)
  end

  def test_parse_ie6_urls
    %w(/some/random/path"
       /some/random/path>
       /some/random/path<
       /we/love/you/ie6?q=<"">
       /url?<="&>="
       /mal"formed"?
    ).each do |path|
      parser = HttpParser.new
      req = {}
      sorta_safe = %(GET #{path} HTTP/1.1\r\n\r\n)
      assert parser.execute(req, sorta_safe)
    end
  end
  
  def test_parse_error
    parser = HttpParser.new
    req = {}
    bad_http = "GET / SsUTF/1.1"

    assert_raises(HttpParserError) { parser.execute(req, bad_http) }
    parser.reset
    assert(parser.execute({}, "GET / HTTP/1.0\r\n\r\n"))
  end

  def test_piecemeal
    parser = HttpParser.new
    req = {}
    http = "GET"
    assert ! parser.execute(req, http)
    assert_raises(HttpParserError) { parser.execute(req, http) }
    assert ! parser.execute(req, http << " / HTTP/1.0")
    assert_equal '/', req['REQUEST_PATH']
    assert_equal '/', req['REQUEST_URI']
    assert_equal 'GET', req['REQUEST_METHOD']
    assert ! parser.execute(req, http << "\r\n")
    assert_equal 'HTTP/1.0', req['HTTP_VERSION']
    assert ! parser.execute(req, http << "\r")
    assert parser.execute(req, http << "\n")
    assert_equal 'HTTP/1.1', req['SERVER_PROTOCOL']
    assert_nil req['FRAGMENT']
    assert_nil req['QUERY_STRING']
  end

  def test_put_body_oneshot
    parser = HttpParser.new
    req = {}
    http = "PUT / HTTP/1.0\r\nContent-Length: 5\r\n\r\nabcde"
    assert parser.execute(req, http)
    assert_equal '/', req['REQUEST_PATH']
    assert_equal '/', req['REQUEST_URI']
    assert_equal 'PUT', req['REQUEST_METHOD']
    assert_equal 'HTTP/1.0', req['HTTP_VERSION']
    assert_equal 'HTTP/1.1', req['SERVER_PROTOCOL']
    assert_equal "abcde", req['HTTP_BODY']
  end

  def test_put_body_later
    parser = HttpParser.new
    req = {}
    http = "PUT /l HTTP/1.0\r\nContent-Length: 5\r\n\r\n"
    assert parser.execute(req, http)
    assert_equal '/l', req['REQUEST_PATH']
    assert_equal '/l', req['REQUEST_URI']
    assert_equal 'PUT', req['REQUEST_METHOD']
    assert_equal 'HTTP/1.0', req['HTTP_VERSION']
    assert_equal 'HTTP/1.1', req['SERVER_PROTOCOL']
    assert_equal "", req['HTTP_BODY']
  end

  def test_fragment_in_uri
    parser = HttpParser.new
    req = {}
    get = "GET /forums/1/topics/2375?page=1#posts-17408 HTTP/1.1\r\n\r\n"
    ok = false
    assert_nothing_raised do
      ok = parser.execute(req, get)
    end
    assert ok
    assert_equal '/forums/1/topics/2375?page=1', req['REQUEST_URI']
    assert_equal 'posts-17408', req['FRAGMENT']
    assert_equal 'page=1', req['QUERY_STRING']
  end

  # lame random garbage maker
  def rand_data(min, max, readable=true)
    count = min + ((rand(max)+1) *10).to_i
    res = count.to_s + "/"
    
    if readable
      res << Digest::SHA1.hexdigest(rand(count * 100).to_s) * (count / 40)
    else
      res << Digest::SHA1.digest(rand(count * 100).to_s) * (count / 20)
    end

    return res
  end
  

  def test_horrible_queries
    parser = HttpParser.new

    # then that large header names are caught
    10.times do |c|
      get = "GET /#{rand_data(10,120)} HTTP/1.1\r\nX-#{rand_data(1024, 1024+(c*1024))}: Test\r\n\r\n"
      assert_raises Unicorn::HttpParserError do
        parser.execute({}, get)
        parser.reset
      end
    end

    # then that large mangled field values are caught
    10.times do |c|
      get = "GET /#{rand_data(10,120)} HTTP/1.1\r\nX-Test: #{rand_data(1024, 1024+(c*1024), false)}\r\n\r\n"
      assert_raises Unicorn::HttpParserError do
        parser.execute({}, get)
        parser.reset
      end
    end

    # then large headers are rejected too
    get = "GET /#{rand_data(10,120)} HTTP/1.1\r\n"
    get << "X-Test: test\r\n" * (80 * 1024)
    assert_raises Unicorn::HttpParserError do
      parser.execute({}, get)
      parser.reset
    end

    # finally just that random garbage gets blocked all the time
    10.times do |c|
      get = "GET #{rand_data(1024, 1024+(c*1024), false)} #{rand_data(1024, 1024+(c*1024), false)}\r\n\r\n"
      assert_raises Unicorn::HttpParserError do
        parser.execute({}, get)
        parser.reset
      end
    end

  end
end

