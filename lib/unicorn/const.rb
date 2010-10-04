# -*- encoding: binary -*-

module Unicorn

  # Frequently used constants when constructing requests or responses.  Many times
  # the constant just refers to a string with the same contents.  Using these constants
  # gave about a 3% to 10% performance improvement over using the strings directly.
  # Symbols did not really improve things much compared to constants.
  module Const

    # The current version of Unicorn, currently 1.1.4
    UNICORN_VERSION="1.1.4"

    DEFAULT_HOST = "0.0.0.0" # default TCP listen host address
    DEFAULT_PORT = 8080      # default TCP listen port
    DEFAULT_LISTEN = "#{DEFAULT_HOST}:#{DEFAULT_PORT}"

    # The basic max request size we'll try to read.
    CHUNK_SIZE=(16 * 1024)

    # Maximum request body size before it is moved out of memory and into a
    # temporary file for reading (112 kilobytes).
    MAX_BODY=1024 * 112

    # common errors we'll send back
    ERROR_400_RESPONSE = "HTTP/1.1 400 Bad Request\r\n\r\n"
    ERROR_500_RESPONSE = "HTTP/1.1 500 Internal Server Error\r\n\r\n"
    EXPECT_100_RESPONSE = "HTTP/1.1 100 Continue\r\n\r\n"

    # A frozen format for this is about 15% faster
    REMOTE_ADDR="REMOTE_ADDR".freeze
    RACK_INPUT="rack.input".freeze
    HTTP_EXPECT="HTTP_EXPECT"
  end

end
