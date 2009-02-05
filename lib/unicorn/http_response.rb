module Unicorn

  # Writes a Rack response to your client using the HTTP/1.1 specification.
  # You use it by simply doing:
  #
  #   status, headers, body = rack_app.call(env)
  #   HttpResponse.send(socket, [ status, headers, body ])
  #
  # Most header correctness (including Content-Length) is the job of
  # Rack, with the exception of the "Connection: close" and "Date"
  # headers.
  #
  # A design decision was made to force the client to not pipeline or
  # keepalive requests.  HTTP/1.1 pipelining really kills the
  # performance due to how it has to be handled and how unclear the
  # standard is.  To fix this the HttpResponse always gives a
  # "Connection: close" header which forces the client to close right
  # away.  The bonus for this is that it gives a pretty nice speed boost
  # to most clients since they can close their connection immediately.

  class HttpResponse

    # we'll have one of these per-process
    HEADERS = HeaderOut.new unless defined?(HEADERS)

    def self.send(socket, rack_response)
      status, headers, body = rack_response
      HEADERS.reset!

      # Rack does not set Date, but don't worry about Content-Length,
      # since Rack enforces that in Rack::Lint
      HEADERS[Const::DATE] = Time.now.httpdate
      HEADERS.merge!(headers)

      socket.write("#{HTTP_STATUS_HEADERS[status]}#{HEADERS.to_s}\r\n")
      body.each { |chunk| socket.write(chunk) }
    end

  end
end
