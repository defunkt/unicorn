
module Unicorn
  #
  # The HttpRequest.initialize method will convert any request that is larger than
  # Const::MAX_BODY into a Tempfile and use that as the body.  Otherwise it uses 
  # a StringIO object.  To be safe, you should assume it works like a file.
  # 
  class HttpRequest
    attr_reader :logger, :buffer

    def initialize(logger)
      @logger = logger
      @tempfile = @body = nil
      @buffer = ' ' * Const::CHUNK_SIZE # initial size, may grow
    end

    def reset
      @body.truncate(0) rescue nil
      @body.close rescue nil
      @body = nil
    end

    # returns an environment hash suitable for Rack if successful
    # returns nil if the socket closed prematurely (e.g. user aborted upload)
    def consume(params, socket)
      http_body = params[Const::HTTP_BODY]
      content_length = params[Const::CONTENT_LENGTH].to_i
      remain = content_length - http_body.length

      # must read more data to complete body
      if remain < Const::MAX_BODY
        # small body, just use that
        @body = StringIO.new(http_body)
      else # huge body, put it in a tempfile
        @tempfile ||= Tempfile.new(Const::UNICORN_TMP_BASE)
        @body = File.open(@tempfile.path, "wb+")
        @body.sync = true
        @body.syswrite(http_body)
        @body
      end

      # Some clients (like FF1.0) report 0 for body and then send a body.
      # This will probably truncate them but at least the request goes through
      # usually.
      if remain > 0
        read_body(socket, remain) or return nil # fail!
      end
      @body.rewind
      @body.sysseek(0) if @body.respond_to?(:sysseek)
      rack_env(params)
    end

    # Returns an environment which is rackable:
    # http://rack.rubyforge.org/doc/files/SPEC.html
    # Copied directly from Rack's old Mongrel handler.
    def rack_env(params)
      params["QUERY_STRING"] ||= ''
      params.delete "HTTP_CONTENT_TYPE"
      params.delete "HTTP_CONTENT_LENGTH"
      params.update({ "rack.version" => [0,1],
                      "rack.input" => @body,
                      "rack.errors" => STDERR,
                      "rack.multithread" => false,
                      "rack.multiprocess" => true,
                      "rack.run_once" => false,
                      "rack.url_scheme" => "http",
                    })
    end

    # Does the heavy lifting of properly reading the larger body requests in
    # small chunks.  It expects @body to be an IO object, socket to be valid,
    # It also expects any initial part of the body that has been read to be in
    # the @body already.  It will return true if successful and false if not.
    def read_body(socket, remain)
      buf = @buffer
      while remain > 0
        begin
          socket.sysread(remain, buf) # short read if it's a socket
        rescue Errno::EINTR, Errno::EAGAIN
          retry
        end

        # ASSUME: we are writing to a disk and these writes always write the
        # requested amount.  This is true on Linux.
        remain -= @body.syswrite(buf)
      end
      true # success!
    rescue Object => e
      logger.error "Error reading HTTP body: #{e.inspect}"
      socket.close rescue nil

      # Any errors means we should delete the file, including if the file
      # is dumped.  Truncate it ASAP to help avoid page flushes to disk.
      reset
      false
    end
  end
end
