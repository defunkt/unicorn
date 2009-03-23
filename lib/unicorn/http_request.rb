require 'tempfile'
require 'uri'
require 'stringio'

# compiled extension
require 'unicorn/http11'

module Unicorn
  #
  # The HttpRequest.initialize method will convert any request that is larger than
  # Const::MAX_BODY into a Tempfile and use that as the body.  Otherwise it uses 
  # a StringIO object.  To be safe, you should assume it works like a file.
  # 
  class HttpRequest

     # default parameters we merge into the request env for Rack handlers
     DEF_PARAMS = {
       "rack.errors" => $stderr,
       "rack.multiprocess" => true,
       "rack.multithread" => false,
       "rack.run_once" => false,
       "rack.url_scheme" => "http",
       "rack.version" => [0, 1],
       "SCRIPT_NAME" => "",

       # this is not in the Rack spec, but some apps may rely on it
       "SERVER_SOFTWARE" => "Unicorn #{Const::UNICORN_VERSION}"
     }.freeze

    def initialize(logger)
      @logger = logger
      @body = nil
      @buffer = ' ' * Const::CHUNK_SIZE # initial size, may grow
      @parser = HttpParser.new
      @params = Hash.new
    end

    def reset
      @parser.reset
      @params.clear
      @body.close rescue nil
      @body = nil
    end

    #
    # Does the majority of the IO processing.  It has been written in
    # Ruby using about 7 different IO processing strategies and no
    # matter how it's done the performance just does not improve.  It is
    # currently carefully constructed to make sure that it gets the best
    # possible performance, but anyone who thinks they can make it
    # faster is more than welcome to take a crack at it.
    #
    # returns an environment hash suitable for Rack if successful
    # This does minimal exception trapping and it is up to the caller
    # to handle any socket errors (e.g. user aborted upload).
    def read(socket)
      data = String.new(read_socket(socket))
      nparsed = 0

      # Assumption: nparsed will always be less since data will get
      # filled with more after each parsing.  If it doesn't get more
      # then there was a problem with the read operation on the client
      # socket.  Effect is to stop processing when the socket can't
      # fill the buffer for further parsing.
      while nparsed < data.length
        nparsed = @parser.execute(@params, data, nparsed)

        if @parser.finished?
          return handle_body(socket) ? rack_env(socket) : nil
        else
          # Parser is not done, queue up more data to read and continue
          # parsing
          data << read_socket(socket)
          if data.length >= Const::MAX_HEADER
            raise HttpParserError.new("HEADER is longer than allowed, " \
                                      "aborting client early.")
          end
        end
      end
      nil # XXX bug?
      rescue HttpParserError => e
        @logger.error "HTTP parse error, malformed request " \
                      "(#{@params[Const::HTTP_X_FORWARDED_FOR] ||
                          socket.unicorn_peeraddr}): #{e.inspect}"
        @logger.error "REQUEST DATA: #{data.inspect}\n---\n" \
                      "PARAMS: #{@params.inspect}\n---\n"
        socket.closed? or socket.close rescue nil
        nil
    end

    private

    # Handles dealing with the rest of the request
    # returns true if successful, false if not
    def handle_body(socket)
      http_body = @params[Const::HTTP_BODY]
      content_length = @params[Const::CONTENT_LENGTH].to_i
      remain = content_length - http_body.length

      # must read more data to complete body
      if remain < Const::MAX_BODY
        # small body, just use that
        @body = StringIO.new(http_body)
      else # huge body, put it in a tempfile
        @body = Tempfile.new(Const::UNICORN_TMP_BASE)
        @body.binmode
        @body.sync = true
        @body.syswrite(http_body)
      end

      # Some clients (like FF1.0) report 0 for body and then send a body.
      # This will probably truncate them but at least the request goes through
      # usually.
      if remain > 0
        read_body(socket, remain) or return false # fail!
      end
      @body.rewind
      @body.sysseek(0) if @body.respond_to?(:sysseek)

      # in case read_body overread because the client tried to pipeline
      # another request, we'll truncate it.  Again, we don't do pipelining
      # or keepalive
      @body.truncate(content_length)
      true
    end

    # Returns an environment which is rackable:
    # http://rack.rubyforge.org/doc/files/SPEC.html
    # Based on Rack's old Mongrel handler.
    def rack_env(socket)
      # I'm considering enabling "unicorn.client".  It gives
      # applications some rope to do some "interesting" things like
      # replacing a worker with another process that has full control
      # over the HTTP response.
      # @params["unicorn.client"] = socket

      # From http://www.ietf.org/rfc/rfc3875:
      # "Script authors should be aware that the REMOTE_ADDR and
      #  REMOTE_HOST meta-variables (see sections 4.1.8 and 4.1.9)
      #  may not identify the ultimate source of the request.  They
      #  identify the client for the immediate request to the server;
      #  that client may be a proxy, gateway, or other intermediary
      #  acting on behalf of the actual source client."
      @params[Const::REMOTE_ADDR] = socket.unicorn_peeraddr

      # It might be a dumbass full host request header
      @params[Const::PATH_INFO] = (
          @params[Const::REQUEST_PATH] ||=
              URI.parse(@params[Const::REQUEST_URI]).path) or
         raise "No REQUEST_PATH"

      @params[Const::QUERY_STRING] ||= ''
      @params[Const::RACK_INPUT] = @body
      @params.update(DEF_PARAMS)
    end

    # Does the heavy lifting of properly reading the larger body requests in
    # small chunks.  It expects @body to be an IO object, socket to be valid,
    # It also expects any initial part of the body that has been read to be in
    # the @body already.  It will return true if successful and false if not.
    def read_body(socket, remain)
      while remain > 0
        # writes always write the requested amount on a POSIX filesystem
        remain -= @body.syswrite(read_socket(socket))
      end
      true # success!
    rescue Object => e
      @logger.error "Error reading HTTP body: #{e.inspect}"
      socket.closed? or socket.close rescue nil

      # Any errors means we should delete the file, including if the file
      # is dumped.  Truncate it ASAP to help avoid page flushes to disk.
      @body.truncate(0) rescue nil
      reset
      false
    end

    # read(2) on "slow" devices like sockets can be interrupted by signals
    def read_socket(socket)
      begin
        socket.sysread(Const::CHUNK_SIZE, @buffer)
      rescue Errno::EINTR
        retry
      end
    end

  end
end
