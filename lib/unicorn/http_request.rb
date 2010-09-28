# -*- encoding: binary -*-

require 'unicorn_http'

module Unicorn
  class HttpRequest

    # default parameters we merge into the request env for Rack handlers
    DEFAULTS = {
      "rack.errors" => $stderr,
      "rack.multiprocess" => true,
      "rack.multithread" => false,
      "rack.run_once" => false,
      "rack.version" => [1, 1],
      "SCRIPT_NAME" => "",

      # this is not in the Rack spec, but some apps may rely on it
      "SERVER_SOFTWARE" => "Unicorn #{Const::UNICORN_VERSION}"
    }

    NULL_IO = StringIO.new("")
    LOCALHOST = '127.0.0.1'

    def initialize
      @parser = Unicorn::HttpParser.new
      @buf = ""
      @env = {}
    end

    def response_headers?
      @parser.headers?
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
      @env.clear
      @parser.reset

      # From http://www.ietf.org/rfc/rfc3875:
      # "Script authors should be aware that the REMOTE_ADDR and
      #  REMOTE_HOST meta-variables (see sections 4.1.8 and 4.1.9)
      #  may not identify the ultimate source of the request.  They
      #  identify the client for the immediate request to the server;
      #  that client may be a proxy, gateway, or other intermediary
      #  acting on behalf of the actual source client."
      @env[Const::REMOTE_ADDR] =
                    TCPSocket === socket ? socket.peeraddr[-1] : LOCALHOST

      # short circuit the common case with small GET requests first
      if @parser.headers(@env, socket.readpartial(Const::CHUNK_SIZE, @buf)).nil?
        # Parser is not done, queue up more data to read and continue parsing
        # an Exception thrown from the PARSER will throw us out of the loop
        begin
          @buf << socket.readpartial(Const::CHUNK_SIZE)
        end while @parser.headers(@env, @buf).nil?
      end
      @env[Const::RACK_INPUT] = 0 == @parser.content_length ?
                   NULL_IO : Unicorn::TeeInput.new(socket, @env, @parser, @buf)
      @env.merge!(DEFAULTS)
    end
  end
end
