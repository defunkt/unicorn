# Copyright (c) 2009 Eric Wong
# You can redistribute it and/or modify it under the same terms as Ruby.
require 'unicorn'
require 'unicorn_http'

# Eventually I should integrate this into HttpParser...
module Unicorn
  class TrailerParser

    TR_FR = 'a-z-'.freeze
    TR_TO = 'A-Z_'.freeze

    # initializes HTTP trailer parser with acceptable +trailer+
    def initialize(http_trailer)
      @trailers = http_trailer.split(/\s*,\s*/).inject({}) { |hash, key|
        hash[key.tr(TR_FR, TR_TO)] = true
        hash
      }
    end

    # Executes our TrailerParser on +data+ and modifies +env+  This will
    # shrink +data+ as it is being consumed.  Returns true if it has
    # parsed all trailers, false if not.  It raises HttpParserError on
    # parse failure or unknown headers.  It has slightly smaller limits
    # than the C-based HTTP parser but should not be an issue in practice
    # since Content-MD5 is probably the only legitimate use for it.
    def execute!(env, data)
      data.size > 0xffff and
        raise HttpParserError, "trailer buffer too large: #{data.size} bytes"

      begin
        data.sub!(/\A([^\r]+)\r\n/, Z) or return false # need more data

        key, val = $1.split(/:\s*/, 2)

        key.size > 256 and
          raise HttpParserError, "trailer key #{key.inspect} is too long"
        val.size > 8192 and
          raise HttpParserError, "trailer value #{val.inspect} is too long"

        key.tr!(TR_FR, TR_TO)

        @trailers.delete(key) or
          raise HttpParserError, "unknown trailer: #{key.inspect}"
        env["HTTP_#{key}"] = val

        @trailers.empty? and return true
      end while true
    end

  end
end
