# -*- encoding: binary -*-
# :enddoc:
# Writes a Rack response to your client using the HTTP/1.1 specification.
# You use it by simply doing:
#
#   status, headers, body = rack_app.call(env)
#   http_response_write(socket, status, headers, body)
#
# Most header correctness (including Content-Length and Content-Type)
# is the job of Rack, with the exception of the "Date" and "Status" header.
module Unicorn::HttpResponse

  # Every standard HTTP code mapped to the appropriate message.
  CODES = Rack::Utils::HTTP_STATUS_CODES.inject({}) { |hash,(code,msg)|
    hash[code] = "#{code} #{msg}"
    hash
  }
  CRLF = "\r\n"

  def err_response(code, response_start_sent)
    "#{response_start_sent ? '' : 'HTTP/1.1 '}#{CODES[code]}\r\n\r\n"
  end

  # writes the rack_response to socket as an HTTP response
  def http_response_write(socket, status, headers, body,
                          response_start_sent=false)
    status = CODES[status.to_i] || status
    hijack = nil

    http_response_start = response_start_sent ? '' : 'HTTP/1.1 '
    if headers
      buf = "#{http_response_start}#{status}\r\n" \
            "Date: #{httpdate}\r\n" \
            "Status: #{status}\r\n" \
            "Connection: close\r\n"
      headers.each do |key, value|
        case key
        when %r{\A(?:Date\z|Connection\z)}i
          next
        when "rack.hijack"
          # this was an illegal key in Rack < 1.5, so it should be
          # OK to silently discard it for those older versions
          hijack = hijack_prepare(value)
        else
          if value =~ /\n/
            # avoiding blank, key-only cookies with /\n+/
            buf << value.split(/\n+/).map! { |v| "#{key}: #{v}\r\n" }.join
          else
            buf << "#{key}: #{value}\r\n"
          end
        end
      end
      socket.write(buf << CRLF)
    end

    if hijack
      body = nil # ensure we do not close body
      hijack.call(socket)
    else
      body.each { |chunk| socket.write(chunk) }
    end
  ensure
    body.respond_to?(:close) and body.close
  end

  # Rack 1.5.0 (protocol version 1.2) adds response hijacking support
  if ((Rack::VERSION[0] << 8) | Rack::VERSION[1]) >= 0x0102
    def hijack_prepare(value)
      value
    end
  else
    def hijack_prepare(_)
    end
  end
end
