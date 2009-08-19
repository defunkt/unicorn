require 'time'

module Unicorn
  # Writes a Rack response to your client using the HTTP/1.1 specification.
  # You use it by simply doing:
  #
  #   status, headers, body = rack_app.call(env)
  #   HttpResponse.write(socket, [ status, headers, body ], keepalive)
  #
  # Most header correctness (including Content-Length and Content-Type)
  # is the job of Rack, with the exception of the "Connection"
  # and "Date" headers.
  class HttpResponse

    # Every standard HTTP code mapped to the appropriate message.
    CODES = Rack::Utils::HTTP_STATUS_CODES.inject({}) { |hash,(code,msg)|
      hash[code] = "#{code} #{msg}"
      hash
    }

    CONN_CLOSE = "Connection: close\r\n"
    CONN_ALIVE = "Connection: keep-alive\r\n"

    # Rack does not set/require a Date: header.  We always override the
    # Connection: and Date: headers no matter what (if anything) our
    # Rack application sent us.
    SKIP = { 'connection' => true, 'date' => true, 'status' => true }.freeze

    # writes the rack_response to socket as an HTTP response
    def self.write(socket, rack_response, keepalive = false)
      status, headers, body = rack_response
      status = CODES[status.to_i] || status
      tmp = [ keepalive ? CONN_ALIVE : CONN_CLOSE ]

      # Don't bother enforcing duplicate supression, it's a Hash most of
      # the time anyways so just hope our app knows what it's doing
      headers.each do |key, value|
        next if SKIP.include?(key.downcase)
        if value =~ /\n/
          value.split(/\n/).each { |v| tmp << "#{key}: #{v}\r\n" }
        else
          tmp << "#{key}: #{value}\r\n"
        end
      end

      # Rack should enforce Content-Length or chunked transfer encoding,
      # so don't worry or care about them.
      # Date is required by HTTP/1.1 as long as our clock can be trusted.
      # Some broken clients require a "Status" header so we accomodate them
      socket.write("HTTP/1.1 #{status}\r\n" \
                   "Date: #{Time.now.httpdate}\r\n" \
                   "Status: #{status}\r\n" \
                   "#{tmp.join(Z)}\r\n")
      body.each { |chunk| socket.write(chunk) }
      keepalive or socket.close # flushes and uncorks the socket immediately
      ensure
        body.respond_to?(:close) and body.close rescue nil
    end

  end
end
