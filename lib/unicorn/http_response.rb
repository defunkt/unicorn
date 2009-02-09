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

    # enforce "Connection: close" usage on all our responses
    HTTP_STATUS_HEADERS = HTTP_STATUS_CODES.inject({}) do |hash, (code, text)|
      hash[code] = "HTTP/1.1 #{code} #{text}\r\nConnection: close".freeze
      hash
    end.freeze

    # headers we allow duplicates for
    ALLOWED_DUPLICATES = {
      'Set-Cookie' => true,
      'Set-Cookie2' => true,
      'Warning' => true,
      'WWW-Authenticate' => true,
    }.freeze

    # writes the rack_response to socket as an HTTP response
    def self.write(socket, rack_response)
      status, headers, body = rack_response

      # Rack does not set/require Date, but don't worry about Content-Length
      # since Rack applications that conform to Rack::Lint enforce that
      out = [ "#{Const::DATE}: #{Time.now.httpdate}\r\n" ]
      sent = { Const::CONNECTION => true, Const::DATE => true }

      headers.each_pair do |key, value|
        if ! sent[key] || ALLOWED_DUPLICATES[key]
          sent[key] = true
          out << "#{key}: #{value}\r\n"
        end
      end

      socket_write(socket, "#{HTTP_STATUS_HEADERS[status]}\r\n#{out.join}\r\n")
      body.each { |chunk| socket_write(socket, chunk) }
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
