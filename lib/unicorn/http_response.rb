# -*- encoding: binary -*-
require 'time'

# Writes a Rack response to your client using the HTTP/1.1 specification.
# You use it by simply doing:
#
#   status, headers, body = rack_app.call(env)
#   HttpResponse.write(socket, [ status, headers, body ])
#
# Most header correctness (including Content-Length and Content-Type)
# is the job of Rack, with the exception of the "Connection: close"
# and "Date" headers.
#
# A design decision was made to force the client to not pipeline or
# keepalive requests.  HTTP/1.1 pipelining really kills the
# performance due to how it has to be handled and how unclear the
# standard is.  To fix this the HttpResponse always gives a
# "Connection: close" header which forces the client to close right
# away.  The bonus for this is that it gives a pretty nice speed boost
# to most clients since they can close their connection immediately.
module Unicorn::HttpResponse

  # Every standard HTTP code mapped to the appropriate message.
  CODES = Rack::Utils::HTTP_STATUS_CODES.inject({}) { |hash,(code,msg)|
    hash[code] = "#{code} #{msg}"
    hash
  }

  # Rack does not set/require a Date: header.  We always override the
  # Connection: and Date: headers no matter what (if anything) our
  # Rack application sent us.
  SKIP = { 'connection' => true, 'date' => true, 'status' => true }

  # writes the rack_response to socket as an HTTP response
  def self.write(socket, rack_response, have_header = true)
    status, headers, body = rack_response

    if have_header
      status = CODES[status.to_i] || status
      out = []

      # Don't bother enforcing duplicate supression, it's a Hash most of
      # the time anyways so just hope our app knows what it's doing
      headers.each do |key, value|
        next if SKIP.include?(key.downcase)
        if value =~ /\n/
          # avoiding blank, key-only cookies with /\n+/
          out.concat(value.split(/\n+/).map! { |v| "#{key}: #{v}\r\n" })
        else
          out << "#{key}: #{value}\r\n"
        end
      end

      # Rack should enforce Content-Length or chunked transfer encoding,
      # so don't worry or care about them.
      # Date is required by HTTP/1.1 as long as our clock can be trusted.
      # Some broken clients require a "Status" header so we accomodate them
      socket.write("HTTP/1.1 #{status}\r\n" \
                   "Date: #{Time.now.httpdate}\r\n" \
                   "Status: #{status}\r\n" \
                   "Connection: close\r\n" \
                   "#{out.join('')}\r\n")
    end

    body.each { |chunk| socket.write(chunk) }
    socket.close # flushes and uncorks the socket immediately
    ensure
      body.respond_to?(:close) and body.close
  end
end
