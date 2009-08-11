# Copyright (c) 2009 Eric Wong
# You can redistribute it and/or modify it under the same terms as Ruby.

# acts like tee(1) on an input input to provide a input-like stream
# while providing rewindable semantics through a File/StringIO
# backing store.  On the first pass, the input is only read on demand
# so your Rack application can use input notification (upload progress
# and like).  This should fully conform to the Rack::InputWrapper
# specification on the public API.  This class is intended to be a
# strict interpretation of Rack::InputWrapper functionality and will
# not support any deviations from it.

module Unicorn
  class TeeInput

    # it's so awesome to not have to care for thread safety...

    RAW = HttpRequest::BUF # :nodoc:
    DST = RAW.dup # :nodoc:
    PARSER = HttpRequest::PARSER # :nodoc:
    REQ = HttpRequest::REQ # :nodoc:

    def initialize(socket)
      @tmp = Util.tmpio
      @size = PARSER.content_length
      return(@input = nil) if 0 == @size
      @input = socket
      if RAW.size > 0
        PARSER.filter_body(DST, RAW) and finalize_input
        @tmp.write(DST)
        @tmp.seek(0)
      end
    end

    # returns the size of the input.  This is what the Content-Length
    # header value should be, and how large our input is expected to be.
    # For TE:chunked, this requires consuming all of the input stream
    # before returning since there's no other way
    def size
      @size and return @size

      if @input
        pos = @tmp.tell
        while tee(Const::CHUNK_SIZE, DST)
        end
        @tmp.seek(pos)
      end

      @size = @tmp.stat.size
    end

    def read(*args)
      @input or return @tmp.read(*args)

      length = args.shift
      if nil == length
        rv = @tmp.read || Z.dup
        while tee(Const::CHUNK_SIZE, DST)
          rv << DST
        end
        rv
      else
        buf = args.shift || DST.dup
        diff = @tmp.stat.size - @tmp.pos
        if 0 == diff
          tee(length, buf)
        else
          @tmp.read(diff > length ? length : diff, buf)
        end
      end
    end

    # takes zero arguments for strict Rack::Lint compatibility, unlike IO#gets
    def gets
      @input or return @tmp.gets
      nil == $/ and return read

      orig_size = @tmp.stat.size
      if @tmp.pos == orig_size
        tee(Const::CHUNK_SIZE, DST) or return nil
        @tmp.seek(orig_size)
      end

      line = @tmp.gets # cannot be nil here since size > pos
      $/ == line[-$/.size, $/.size] and return line

      # unlikely, if we got here, then @tmp is at EOF
      begin
        orig_size = @tmp.pos
        tee(Const::CHUNK_SIZE, DST) or break
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

      self # Rack does not specify what the return value here
    end

    def rewind
      @tmp.rewind # Rack does not specify what the return value here
    end

  private

    # tees off a +length+ chunk of data from the input into the IO
    # backing store as well as returning it.  +buf+ must be specified.
    # returns nil if reading from the input returns nil
    def tee(length, buf)
      unless PARSER.body_eof?
        begin
          if PARSER.filter_body(buf, @input.readpartial(length, RAW)).nil?
            @tmp.write(buf)
            return buf
          end
        rescue EOFError
        end
      end
      finalize_input
    end

    def finalize_input
      while PARSER.trailers(REQ, RAW).nil?
        RAW << @input.readpartial(Const::CHUNK_SIZE, DST)
      end
      @input = nil
    end

  end
end
