# Copyright (c) 2009 Eric Wong
# You can redistribute it and/or modify it under the same terms as Ruby.

require 'tempfile'

# acts like tee(1) on an input input to provide a input-like stream
# while providing rewindable semantics through a Tempfile/StringIO
# backing store.  On the first pass, the input is only read on demand
# so your Rack application can use input notification (upload progress
# and like).  This should fully conform to the Rack::InputWrapper
# specification on the public API.  This class is intended to be a
# strict interpretation of Rack::InputWrapper functionality and will
# not support any deviations from it.

module Unicorn
  class TeeInput

    def initialize(input, size = nil, buffer = nil)
      @wr = Tempfile.new(nil)
      @wr.binmode
      @rd = File.open(@wr.path, 'rb')
      @wr.unlink
      @rd.sync = @wr.sync = true

      @wr.write(buffer) if buffer
      @input = input
      @size = size # nil if chunked
    end

    def consume
      @input or return
      buf = Z.dup
      while tee(Const::CHUNK_SIZE, buf)
      end
      self
    end

    # returns the size of the input.  This is what the Content-Length
    # header value should be, and how large our input is expected to be.
    # For TE:chunked, this requires consuming all of the input stream
    # before returning since there's no other way
    def size
      @size and return @size
      @input and consume
      @size = @wr.stat.size
    end

    def read(*args)
      @input or return @rd.read(*args)

      length = args.shift
      if nil == length
        rv = @rd.read || Z.dup
        tmp = Z.dup
        while tee(Const::CHUNK_SIZE, tmp)
          rv << tmp
        end
        rv
      else
        buf = args.shift || Z.dup
        @rd.read(length, buf) || tee(length, buf)
      end
    end

    # takes zero arguments for strict Rack::Lint compatibility, unlike IO#gets
    def gets
      @input or return @rd.gets
      nil == $/ and return read

      line = nil
      if @rd.pos < @wr.stat.size
        line = @rd.gets # cannot be nil here
        $/ == line[-$/.size, $/.size] and return line

        # half the line was already read, and the rest of has not been read
        if buf = @input.gets
          @wr.write(buf)
          line << buf
        else
          @input = nil
        end
      elsif line = @input.gets
        @wr.write(line)
      end

      line
    end

    def each(&block)
      while line = gets
        yield line
      end

      self # Rack does not specify what the return value here
    end

    def rewind
      @rd.rewind # Rack does not specify what the return value here
    end

  private

    # tees off a +length+ chunk of data from the input into the IO
    # backing store as well as returning it.  +buf+ must be specified.
    # returns nil if reading from the input returns nil
    def tee(length, buf)
      begin
        if @size
          left = @size - @rd.stat.size
          0 == left and return nil
          if length >= left
            @input.readpartial(left, buf) == left and @input = nil
          elsif @input.nil?
            return nil
          else
            @input.readpartial(length, buf)
          end
        else # ChunkedReader#readpartial just raises EOFError when done
          @input.readpartial(length, buf)
        end
      rescue EOFError
        return @input = nil
      end
      @wr.write(buf)
      buf
    end

  end
end
