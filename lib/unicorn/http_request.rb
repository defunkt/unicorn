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

    # Being explicitly single-threaded, we have certain advantages in
    # not having to worry about variables being clobbered :)
    BUF = ""
    PARSER = HttpParser.new
    REQ = {}

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
      REQ.clear
      PARSER.reset

      # From http://www.ietf.org/rfc/rfc3875:
      # "Script authors should be aware that the REMOTE_ADDR and
      #  REMOTE_HOST meta-variables (see sections 4.1.8 and 4.1.9)
      #  may not identify the ultimate source of the request.  They
      #  identify the client for the immediate request to the server;
      #  that client may be a proxy, gateway, or other intermediary
      #  acting on behalf of the actual source client."
      REQ[Const::REMOTE_ADDR] =
                    TCPSocket === socket ? socket.peeraddr[-1] : LOCALHOST

      # short circuit the common case with small GET requests first
      if PARSER.headers(REQ, socket.readpartial(Const::CHUNK_SIZE, BUF)).nil?
        # Parser is not done, queue up more data to read and continue parsing
        # an Exception thrown from the PARSER will throw us out of the loop
        begin
          BUF << socket.readpartial(Const::CHUNK_SIZE)
        end while PARSER.headers(REQ, BUF).nil?
      end
      REQ[Const::RACK_INPUT] = 0 == PARSER.content_length ?
                   NULL_IO : Unicorn::TeeInput.new(socket, REQ, PARSER, BUF)
      REQ.update(DEFAULTS)
    end

  end
end
