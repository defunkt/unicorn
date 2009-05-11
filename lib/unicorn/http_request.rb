require 'tempfile'
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
       "rack.version" => [1, 0].freeze,
       "SCRIPT_NAME" => "".freeze,

       # this is not in the Rack spec, but some apps may rely on it
       "SERVER_SOFTWARE" => "Unicorn #{Const::UNICORN_VERSION}".freeze
     }.freeze

    # Optimize for the common case where there's no request body
    # (GET/HEAD) requests.
    NULL_IO = StringIO.new
    LOCALHOST = '127.0.0.1'.freeze

    # Being explicitly single-threaded, we have certain advantages in
    # not having to worry about variables being clobbered :)
    BUFFER = ' ' * Const::CHUNK_SIZE # initial size, may grow
    PARSER = HttpParser.new
    PARAMS = Hash.new

    def initialize(logger)
      @logger = logger
    end

    # Does the majority of the IO processing.  It has been written in
    # Ruby using about 8 different IO processing strategies.
    #
    # It is currently carefully constructed to make sure that it gets
    # the best possible performance for the common case: GET requests
    # that are fully complete after a single read(2)
    #
    # Anyone who thinks they can make it faster is more than welcome to
    # take a crack at it.
    #
    # returns an environment hash suitable for Rack if successful
    # This does minimal exception trapping and it is up to the caller
    # to handle any socket errors (e.g. user aborted upload).
    def read(socket)
      # reset the parser
      unless NULL_IO == (input = PARAMS[Const::RACK_INPUT]) # unlikely
        input.close rescue nil
        input.close! rescue nil
      end
      PARAMS.clear
      PARSER.reset

      # From http://www.ietf.org/rfc/rfc3875:
      # "Script authors should be aware that the REMOTE_ADDR and
      #  REMOTE_HOST meta-variables (see sections 4.1.8 and 4.1.9)
      #  may not identify the ultimate source of the request.  They
      #  identify the client for the immediate request to the server;
      #  that client may be a proxy, gateway, or other intermediary
      #  acting on behalf of the actual source client."
      PARAMS[Const::REMOTE_ADDR] =
                    TCPSocket === socket ? socket.peeraddr.last : LOCALHOST

      # short circuit the common case with small GET requests first
      PARSER.execute(PARAMS, socket.readpartial(Const::CHUNK_SIZE, BUFFER)) and
          return handle_body(socket)

      data = BUFFER.dup # socket.readpartial will clobber BUFFER

      # Parser is not done, queue up more data to read and continue parsing
      # an Exception thrown from the PARSER will throw us out of the loop
      begin
        data << socket.readpartial(Const::CHUNK_SIZE, BUFFER)
        PARSER.execute(PARAMS, data) and return handle_body(socket)
      end while true
      rescue HttpParserError => e
        @logger.error "HTTP parse error, malformed request " \
                      "(#{PARAMS[Const::HTTP_X_FORWARDED_FOR] ||
                          PARAMS[Const::REMOTE_ADDR]}): #{e.inspect}"
        @logger.error "REQUEST DATA: #{data.inspect}\n---\n" \
                      "PARAMS: #{PARAMS.inspect}\n---\n"
        raise e
    end

    private

    # Handles dealing with the rest of the request
    # returns a Rack environment if successful, raises an exception if not
    def handle_body(socket)
      http_body = PARAMS.delete(:http_body)
      content_length = PARAMS[Const::CONTENT_LENGTH].to_i

      if content_length == 0 # short circuit the common case
        PARAMS[Const::RACK_INPUT] = NULL_IO.closed? ? NULL_IO.reopen : NULL_IO
        return PARAMS.update(DEF_PARAMS)
      end

      # must read more data to complete body
      remain = content_length - http_body.length

      body = PARAMS[Const::RACK_INPUT] = (remain < Const::MAX_BODY) ?
          StringIO.new : Tempfile.new('unicorn')

      body.binmode
      body.write(http_body)

      # Some clients (like FF1.0) report 0 for body and then send a body.
      # This will probably truncate them but at least the request goes through
      # usually.
      read_body(socket, remain, body) if remain > 0
      body.rewind

      # in case read_body overread because the client tried to pipeline
      # another request, we'll truncate it.  Again, we don't do pipelining
      # or keepalive
      body.truncate(content_length)
      PARAMS.update(DEF_PARAMS)
    end

    # Does the heavy lifting of properly reading the larger body
    # requests in small chunks.  It expects PARAMS['rack.input'] to be
    # an IO object, socket to be valid, It also expects any initial part
    # of the body that has been read to be in the PARAMS['rack.input']
    # already.  It will return true if successful and false if not.
    def read_body(socket, remain, body)
      begin
        # write always writes the requested amount on a POSIX filesystem
        remain -= body.write(socket.readpartial(Const::CHUNK_SIZE, BUFFER))
      end while remain > 0
    rescue Object => e
      @logger.error "Error reading HTTP body: #{e.inspect}"

      # Any errors means we should delete the file, including if the file
      # is dumped.  Truncate it ASAP to help avoid page flushes to disk.
      body.truncate(0) rescue nil
      reset
      raise e
    end

  end
end
