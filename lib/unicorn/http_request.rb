# coding:binary
require 'stringio'
require 'unicorn_http'

module Unicorn
  class HttpRequest

    # default parameters we merge into the request env for Rack handlers
    DEFAULTS = {
      "rack.errors" => $stderr,
      "rack.multiprocess" => true,
      "rack.multithread" => false,
      "rack.run_once" => false,
      "rack.version" => [1, 0].freeze,
      "SCRIPT_NAME" => "".freeze,

      # this is not in the Rack spec, but some apps may rely on it
      "SERVER_SOFTWARE" => "Unicorn #{Const::UNICORN_VERSION}".freeze
    }

    NULL_IO = StringIO.new(Z)
    LOCALHOST = '127.0.0.1'.freeze

    # Being explicitly single-threaded, we have certain advantages in
    # not having to worry about variables being clobbered :)
    BUF = ' ' * Const::CHUNK_SIZE # initial size, may grow
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
                    TCPSocket === socket ? socket.peeraddr.last : LOCALHOST

      # short circuit the common case with small GET requests first
      PARSER.headers(REQ, socket.readpartial(Const::CHUNK_SIZE, BUF)) and
          return handle_body(socket)

      data = BUF.dup # socket.readpartial will clobber data

      # Parser is not done, queue up more data to read and continue parsing
      # an Exception thrown from the PARSER will throw us out of the loop
      begin
        BUF << socket.readpartial(Const::CHUNK_SIZE, data)
        PARSER.headers(REQ, BUF) and return handle_body(socket)
      end while true
    end

    private

    # Handles dealing with the rest of the request
    # returns a # Rack environment if successful
    def handle_body(socket)
      REQ[Const::RACK_INPUT] = 0 == PARSER.content_length ?
                               NULL_IO : Unicorn::TeeInput.new(socket)
      REQ.update(DEFAULTS)
    end

  end
end
