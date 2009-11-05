# -*- encoding: binary -*-

module Unicorn

  # acts like tee(1) on an input input to provide a input-like stream
  # while providing rewindable semantics through a File/StringIO
  # backing store.  On the first pass, the input is only read on demand
  # so your Rack application can use input notification (upload progress
  # and like).  This should fully conform to the Rack::InputWrapper
  # specification on the public API.  This class is intended to be a
  # strict interpretation of Rack::InputWrapper functionality and will
  # not support any deviations from it.
  class TeeInput < Struct.new(:socket, :req, :parser, :buf)

    def initialize(*args)
      super(*args)
      @size = parser.content_length
      @tmp = @size && @size < Const::MAX_BODY ? StringIO.new("") : Util.tmpio
      @buf2 = buf.dup
      if buf.size > 0
        parser.filter_body(@buf2, buf) and finalize_input
        @tmp.write(@buf2)
        @tmp.seek(0)
      end
    end

    # returns the size of the input.  This is what the Content-Length
    # header value should be, and how large our input is expected to be.
    # For TE:chunked, this requires consuming all of the input stream
    # before returning since there's no other way
    def size
      @size and return @size

      if socket
        pos = @tmp.pos
        while tee(Const::CHUNK_SIZE, @buf2)
        end
        @tmp.seek(pos)
      end

      @size = tmp_size
    end

    # call-seq:
    #   ios = env['rack.input']
    #   ios.read([length [, buffer ]]) => string, buffer, or nil
    #
    # Reads at most length bytes from the I/O stream, or to the end of
    # file if length is omitted or is nil. length must be a non-negative
    # integer or nil. If the optional buffer argument is present, it
    # must reference a String, which will receive the data.
    #
    # At end of file, it returns nil or "" depend on length.
    # ios.read() and ios.read(nil) returns "".
    # ios.read(length [, buffer]) returns nil.
    #
    # If the Content-Length of the HTTP request is known (as is the common
    # case for POST requests), then ios.read(length [, buffer]) will block
    # until the specified length is read (or it is the last chunk).
    # Otherwise, for uncommon "Transfer-Encoding: chunked" requests,
    # ios.read(length [, buffer]) will return immediately if there is
    # any data and only block when nothing is available (providing
    # IO#readpartial semantics).
    def read(*args)
      socket or return @tmp.read(*args)

      length = args.shift
      if nil == length
        rv = @tmp.read || ""
        while tee(Const::CHUNK_SIZE, @buf2)
          rv << @buf2
        end
        rv
      else
        rv = args.shift || @buf2.dup
        diff = tmp_size - @tmp.pos
        if 0 == diff
          ensure_length(tee(length, rv), length)
        else
          ensure_length(@tmp.read(diff > length ? length : diff, rv), length)
        end
      end
    end

    # takes zero arguments for strict Rack::Lint compatibility, unlike IO#gets
    def gets
      socket or return @tmp.gets
      nil == $/ and return read

      orig_size = tmp_size
      if @tmp.pos == orig_size
        tee(Const::CHUNK_SIZE, @buf2) or return nil
        @tmp.seek(orig_size)
      end

      line = @tmp.gets # cannot be nil here since size > pos
      $/ == line[-$/.size, $/.size] and return line

      # unlikely, if we got here, then @tmp is at EOF
      begin
        orig_size = @tmp.pos
        tee(Const::CHUNK_SIZE, @buf2) or break
        @tmp.seek(orig_size)
        line << @tmp.gets
        $/ == line[-$/.size, $/.size] and return line
        # @tmp is at EOF again here, retry the loop
      end while true

      line
    end

    def each(&block)
      while line = gets
        yield line
      end

      self # Rack does not specify what the return value is here
    end

    def rewind
      @tmp.rewind # Rack does not specify what the return value is here
    end

  private

    # tees off a +length+ chunk of data from the input into the IO
    # backing store as well as returning it.  +buf+ must be specified.
    # returns nil if reading from the input returns nil
    def tee(length, dst)
      unless parser.body_eof?
        begin
          if parser.filter_body(dst, socket.readpartial(length, buf)).nil?
            @tmp.write(dst)
            @tmp.seek(0, IO::SEEK_END) # workaround FreeBSD/OSX + MRI 1.8.x bug
            return dst
          end
        rescue EOFError
        end
      end
      finalize_input
    end

    def finalize_input
      while parser.trailers(req, buf).nil?
        buf << socket.readpartial(Const::CHUNK_SIZE)
      end
      self.socket = nil
    end

    def tmp_size
      StringIO === @tmp ? @tmp.size : @tmp.stat.size
    end

    # tee()s into +buf+ until it is of +length+ bytes (or until
    # we've reached the Content-Length of the request body).
    # Returns +buf+ (the exact object, not a duplicate)
    # To continue supporting applications that need near-real-time
    # streaming input bodies, this is a no-op for
    # "Transfer-Encoding: chunked" requests.
    def ensure_length(buf, length)
      # @size is nil for chunked bodies, so we can't ensure length for those
      # since they could be streaming bidirectionally and we don't want to
      # block the caller in that case.
      return buf if buf.nil? || @size.nil?

      while buf.size < length && @size != @tmp.pos
        buf << tee(length - buf.size, @buf2)
      end

      buf
    end

  end
end
