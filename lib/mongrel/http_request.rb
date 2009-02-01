
module Mongrel
  #
  # The HttpRequest.initialize method will convert any request that is larger than
  # Const::MAX_BODY into a Tempfile and use that as the body.  Otherwise it uses 
  # a StringIO object.  To be safe, you should assume it works like a file.
  # 
  class HttpRequest
    attr_reader :body, :params, :logger

    # You don't really call this.  It's made for you.
    # Main thing it does is hook up the params, and store any remaining
    # body data into the HttpRequest.body attribute.
    def initialize(params, socket, logger)
      @params = params
      @socket = socket
      @logger = logger
      
      content_length = @params[Const::CONTENT_LENGTH].to_i
      remain = content_length - @params[Const::HTTP_BODY].length

      # Some clients (like FF1.0) report 0 for body and then send a body.  This will probably truncate them but at least the request goes through usually.
      if remain <= 0
        # we've got everything, pack it up
        @body = StringIO.new
        @body.write @params[Const::HTTP_BODY]
      elsif remain > 0
        # must read more data to complete body
        if remain > Const::MAX_BODY
          # huge body, put it in a tempfile
          @body = Tempfile.new(Const::MONGREL_TMP_BASE)
          @body.binmode
        else
          # small body, just use that
          @body = StringIO.new 
        end

        @body.write @params[Const::HTTP_BODY]
        read_body(remain, content_length)
      end

      @body.rewind if @body
    end

    # returns an environment which is rackable
    # http://rack.rubyforge.org/doc/files/SPEC.html
    # copied directly from racks mongrel handler
    def env
      env = params.clone
      env["QUERY_STRING"] ||= ''
      env.delete "HTTP_CONTENT_TYPE"
      env.delete "HTTP_CONTENT_LENGTH"
      env["SCRIPT_NAME"] = "" if env["SCRIPT_NAME"] == "/"
      env.update({"rack.version" => [0,1],
              "rack.input" => @body,
              "rack.errors" => STDERR,

              "rack.multithread" => true,
              "rack.multiprocess" => false, # ???
              "rack.run_once" => false,

              "rack.url_scheme" => "http",
            }) 
    end

    # Does the heavy lifting of properly reading the larger body requests in 
    # small chunks.  It expects @body to be an IO object, @socket to be valid,
    # and will set @body = nil if the request fails.  It also expects any initial
    # part of the body that has been read to be in the @body already.
    def read_body(remain, total)
      begin
        # Write the odd sized chunk first
        @params[Const::HTTP_BODY] = read_socket(remain % Const::CHUNK_SIZE)

        remain -= @body.write(@params[Const::HTTP_BODY])

        # Then stream out nothing but perfectly sized chunks
        until remain <= 0 or @socket.closed?
          # ASSUME: we are writing to a disk and these writes always write the requested amount
          @params[Const::HTTP_BODY] = read_socket(Const::CHUNK_SIZE)
          remain -= @body.write(@params[Const::HTTP_BODY])
        end
      rescue Object => e
        logger.error "Error reading HTTP body: #{e.inspect}"
        # Any errors means we should delete the file, including if the file is dumped
        @socket.close rescue nil
        @body.close! if @body.class == Tempfile
        @body = nil # signals that there was a problem
      end
    end
 
    def read_socket(len)
      if !@socket.closed?
        data = @socket.read(len)
        if !data
          raise "Socket read return nil"
        elsif data.length != len
          raise "Socket read returned insufficient data: #{data.length}"
        else
          data
        end
      else
        raise "Socket already closed when reading."
      end
    end
  end
end
