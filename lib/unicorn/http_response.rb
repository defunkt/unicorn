require 'time'

module Unicorn
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

  class HttpResponse

    # Rack does not set/require a Date: header.  We always override the
    # Connection: and Date: headers no matter what (if anything) our
    # Rack application sent us.
    SKIP = { 'connection' => true, 'date' => true }.freeze

    # writes the rack_response to socket as an HTTP response
    def self.write(socket, rack_response)
      status, headers, body = rack_response
      out = [ "Date: #{Time.now.httpdate}" ]

      # Don't bother enforcing duplicate supression, it's a Hash most of
      # the time anyways so just hope our app knows what it's doing
      headers.each do |key, value|
        next if SKIP.include?(key.downcase)
        if value =~ /\n/
          value.split(/\n/).each { |v| out << "#{key}: #{v}" }
        else
          out << "#{key}: #{value}"
        end
      end

      # Rack should enforce Content-Length or chunked transfer encoding,
      # so don't worry or care about them.
      socket_write(socket,
                   "HTTP/1.1 #{status} #{HTTP_STATUS_CODES[status]}\r\n" \
                   "Connection: close\r\n" \
                   "#{out.join("\r\n")}\r\n\r\n")
      body.each { |chunk| socket_write(socket, chunk) }
      socket.close # uncorks the socket immediately
      ensure
        body.respond_to?(:close) and body.close rescue nil
    end

    private

      # write(2) can return short on slow devices like sockets as well
      # as fail with EINTR if a signal was caught.
      def self.socket_write(socket, buffer)
        loop do
          begin
            written = socket.syswrite(buffer)
            return written if written == buffer.length
            buffer = buffer[written..-1]
          rescue Errno::EINTR
            retry
          end
        end
      end

  end
end
