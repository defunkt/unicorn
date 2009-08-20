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
      @tmp = @size && @size < Const::MAX_BODY ? StringIO.new(Z.dup) : Util.tmpio
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

    def read(*args)
      socket or return @tmp.read(*args)

      length = args.shift
      if nil == length
        rv = @tmp.read || Z.dup
        while tee(Const::CHUNK_SIZE, @buf2)
          rv << @buf2
        end
        rv
      else
        rv = args.shift || @buf2.dup
        diff = tmp_size - @tmp.pos
        if 0 == diff
          tee(length, rv)
        else
          @tmp.read(diff > length ? length : diff, rv)
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
            return dst
          end
        rescue EOFError
        end
      end
      finalize_input
    end

    def finalize_input
      while parser.trailers(req, buf).nil?
        buf << socket.readpartial(Const::CHUNK_SIZE, @buf2)
      end
      self.socket = nil
    end

    def tmp_size
      StringIO === @tmp ? @tmp.size : @tmp.stat.size
    end

  end
end
