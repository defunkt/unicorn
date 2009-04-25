
module Unicorn

  # Every standard HTTP code mapped to the appropriate message.  These are
  # used so frequently that they are placed directly in Unicorn for easy
  # access rather than Unicorn::Const itself.
  HTTP_STATUS_CODES = {
    100  => 'Continue',
    101  => 'Switching Protocols',
    200  => 'OK',
    201  => 'Created',
    202  => 'Accepted',
    203  => 'Non-Authoritative Information',
    204  => 'No Content',
    205  => 'Reset Content',
    206  => 'Partial Content',
    300  => 'Multiple Choices',
    301  => 'Moved Permanently',
    302  => 'Moved Temporarily',
    303  => 'See Other',
    304  => 'Not Modified',
    305  => 'Use Proxy',
    400  => 'Bad Request',
    401  => 'Unauthorized',
    402  => 'Payment Required',
    403  => 'Forbidden',
    404  => 'Not Found',
    405  => 'Method Not Allowed',
    406  => 'Not Acceptable',
    407  => 'Proxy Authentication Required',
    408  => 'Request Time-out',
    409  => 'Conflict',
    410  => 'Gone',
    411  => 'Length Required',
    412  => 'Precondition Failed',
    413  => 'Request Entity Too Large',
    414  => 'Request-URI Too Large',
    415  => 'Unsupported Media Type',
    500  => 'Internal Server Error',
    501  => 'Not Implemented',
    502  => 'Bad Gateway',
    503  => 'Service Unavailable',
    504  => 'Gateway Time-out',
    505  => 'HTTP Version not supported'
  }.inject({}) { |hash,(code,msg)|
      hash[code] = "#{code} #{msg}"
      hash
  }

  # Frequently used constants when constructing requests or responses.  Many times
  # the constant just refers to a string with the same contents.  Using these constants
  # gave about a 3% to 10% performance improvement over using the strings directly.
  # Symbols did not really improve things much compared to constants.
  module Const
    # This is the part of the path after the SCRIPT_NAME.
    PATH_INFO="PATH_INFO".freeze

    # The original URI requested by the client.
    REQUEST_URI='REQUEST_URI'.freeze
    REQUEST_PATH='REQUEST_PATH'.freeze

    UNICORN_VERSION="0.7.0".freeze

    DEFAULT_HOST = "0.0.0.0".freeze # default TCP listen host address
    DEFAULT_PORT = "8080".freeze    # default TCP listen port
    DEFAULT_LISTEN = "#{DEFAULT_HOST}:#{DEFAULT_PORT}".freeze

    # The basic max request size we'll try to read.
    CHUNK_SIZE=(16 * 1024)

    # This is the maximum header that is allowed before a client is booted.  The parser detects
    # this, but we'd also like to do this as well.
    MAX_HEADER=1024 * (80 + 32)

    # Maximum request body size before it is moved out of memory and into a tempfile for reading.
    MAX_BODY=MAX_HEADER

    # common errors we'll send back
    ERROR_400_RESPONSE = "HTTP/1.1 400 Bad Request\r\n\r\n".freeze
    ERROR_500_RESPONSE = "HTTP/1.1 500 Internal Server Error\r\n\r\n".freeze

    # A frozen format for this is about 15% faster
    CONTENT_LENGTH="CONTENT_LENGTH".freeze
    REMOTE_ADDR="REMOTE_ADDR".freeze
    HTTP_X_FORWARDED_FOR="HTTP_X_FORWARDED_FOR".freeze
    RACK_INPUT="rack.input".freeze
  end

end
