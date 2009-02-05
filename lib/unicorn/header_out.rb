module Unicorn
  # This class implements a simple way of constructing the HTTP headers dynamically
  # via a Hash syntax.  Think of it as a write-only Hash.  Refer to HttpResponse for
  # information on how this is used.
  #
  # One consequence of this write-only nature is that you can write multiple headers
  # by just doing them twice (which is sometimes needed in HTTP), but that the normal
  # semantics for Hash (where doing an insert replaces) is not there.
  class HeaderOut
    ALLOWED_DUPLICATES = {
      'Set-Cookie' => true,
      'Set-Cookie2' => true,
      'Warning' => true,
      'WWW-Authenticate' => true,
    }.freeze

    def initialize
      @sent = {}
      @out = []
    end

    def reset!
      @sent.clear
      @out.clear
    end

    def merge!(hash)
      hash.each do |key, value|
        self[key] = value
      end
    end

    # Simply writes "#{key}: #{value}" to an output buffer.
    def[]=(key,value)
      if not @sent.has_key?(key) or ALLOWED_DUPLICATES.has_key?(key)
        @sent[key] = true
        @out << "#{key}: #{value}\r\n"
      end
    end

    def to_s
      @out.join
    end

  end
end
