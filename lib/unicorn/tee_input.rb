# -*- encoding: binary -*-

# acts like tee(1) on an input input to provide a input-like stream
# while providing rewindable semantics through a File/StringIO backing
# store.  On the first pass, the input is only read on demand so your
# Rack application can use input notification (upload progress and
# like).  This should fully conform to the Rack::Lint::InputWrapper
# specification on the public API.  This class is intended to be a
# strict interpretation of Rack::Lint::InputWrapper functionality and
# will not support any deviations from it.
#
# When processing uploads, Unicorn exposes a TeeInput object under
# "rack.input" of the Rack environment.
class Unicorn::TeeInput < Struct.new(:socket, :req, :parser,
                                     :buf, :len, :tmp, :buf2)

  # The maximum size (in +bytes+) to buffer in memory before
  # resorting to a temporary file.  Default is 112 kilobytes.
  @@client_body_buffer_size = Unicorn::Const::MAX_BODY

  # The I/O chunk size (in +bytes+) for I/O operations where
  # the size cannot be user-specified when a method is called.
  # The default is 16 kilobytes.
  @@io_chunk_size = Unicorn::Const::CHUNK_SIZE

  # Initializes a new TeeInput object.  You normally do not have to call
  # this unless you are writing an HTTP server.
  def initialize(*args)
    super(*args)
    self.len = parser.content_length
    self.tmp = len && len < @@client_body_buffer_size ?
               StringIO.new("") : Unicorn::Util.tmpio
    self.buf2 = ""
    if buf.size > 0
      parser.filter_body(buf2, buf) and finalize_input
      tmp.write(buf2)
      tmp.rewind
    end
  end

  # :call-seq:
  #   ios.size  => Integer
  #
  # Returns the size of the input.  For requests with a Content-Length
  # header value, this will not read data off the socket and just return
  # the value of the Content-Length header as an Integer.
  #
  # For Transfer-Encoding:chunked requests, this requires consuming
  # all of the input stream before returning since there's no other
  # way to determine the size of the request body beforehand.
  #
  # This method is no longer part of the Rack specification as of
  # Rack 1.2, so its use is not recommended.  This method only exists
  # for compatibility with Rack applications designed for Rack 1.1 and
  # earlier.  Most applications should only need to call +read+ with a
  # specified +length+ in a loop until it returns +nil+.
  def size
    len and return len

    if socket
      pos = tmp.pos
      while tee(@@io_chunk_size, buf2)
      end
      tmp.seek(pos)
    end

    self.len = tmp.size
  end

  # :call-seq:
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
    socket or return tmp.read(*args)

    length = args.shift
    if nil == length
      rv = tmp.read || ""
      while tee(@@io_chunk_size, buf2)
        rv << buf2
      end
      rv
    else
      rv = args.shift || ""
      diff = tmp.size - tmp.pos
      if 0 == diff
        ensure_length(tee(length, rv), length)
      else
        ensure_length(tmp.read(diff > length ? length : diff, rv), length)
      end
    end
  end

  # :call-seq:
  #   ios.gets   => string or nil
  #
  # Reads the next ``line'' from the I/O stream; lines are separated
  # by the global record separator ($/, typically "\n"). A global
  # record separator of nil reads the entire unread contents of ios.
  # Returns nil if called at the end of file.
  # This takes zero arguments for strict Rack::Lint compatibility,
  # unlike IO#gets.
  def gets
    socket or return tmp.gets
    sep = $/ or return read

    orig_size = tmp.size
    if tmp.pos == orig_size
      tee(@@io_chunk_size, buf2) or return nil
      tmp.seek(orig_size)
    end

    sep_size = Rack::Utils.bytesize(sep)
    line = tmp.gets # cannot be nil here since size > pos
    sep == line[-sep_size, sep_size] and return line

    # unlikely, if we got here, then tmp is at EOF
    begin
      orig_size = tmp.pos
      tee(@@io_chunk_size, buf2) or break
      tmp.seek(orig_size)
      line << tmp.gets
      sep == line[-sep_size, sep_size] and return line
      # tmp is at EOF again here, retry the loop
    end while true

    line
  end

  # :call-seq:
  #   ios.each { |line| block }  => ios
  #
  # Executes the block for every ``line'' in *ios*, where lines are
  # separated by the global record separator ($/, typically "\n").
  def each(&block)
    while line = gets
      yield line
    end

    self # Rack does not specify what the return value is here
  end

  # :call-seq:
  #   ios.rewind    => 0
  #
  # Positions the *ios* pointer to the beginning of input, returns
  # the offset (zero) of the +ios+ pointer.  Subsequent reads will
  # start from the beginning of the previously-buffered input.
  def rewind
    tmp.rewind # Rack does not specify what the return value is here
  end

private

  def client_error(e)
    case e
    when EOFError
      # in case client only did a premature shutdown(SHUT_WR)
      # we do support clients that shutdown(SHUT_WR) after the
      # _entire_ request has been sent, and those will not have
      # raised EOFError on us.
      socket.close if socket
      raise Unicorn::ClientShutdown, "bytes_read=#{tmp.size}", []
    when Unicorn::HttpParserError
      e.set_backtrace([])
    end
    raise e
  end

  # tees off a +length+ chunk of data from the input into the IO
  # backing store as well as returning it.  +dst+ must be specified.
  # returns nil if reading from the input returns nil
  def tee(length, dst)
    unless parser.body_eof?
      if parser.filter_body(dst, socket.readpartial(length, buf)).nil?
        tmp.write(dst)
        tmp.seek(0, IO::SEEK_END) # workaround FreeBSD/OSX + MRI 1.8.x bug
        return dst
      end
    end
    finalize_input
    rescue => e
      client_error(e)
  end

  def finalize_input
    while parser.trailers(req, buf).nil?
      # Don't worry about raising ClientShutdown here on EOFError, tee()
      # will catch EOFError when app is processing it, otherwise in
      # initialize we never get any chance to enter the app so the
      # EOFError will just get trapped by Unicorn and not the Rack app
      buf << socket.readpartial(@@io_chunk_size)
    end
    self.socket = nil
  end

  # tee()s into +dst+ until it is of +length+ bytes (or until
  # we've reached the Content-Length of the request body).
  # Returns +dst+ (the exact object, not a duplicate)
  # To continue supporting applications that need near-real-time
  # streaming input bodies, this is a no-op for
  # "Transfer-Encoding: chunked" requests.
  def ensure_length(dst, length)
    # len is nil for chunked bodies, so we can't ensure length for those
    # since they could be streaming bidirectionally and we don't want to
    # block the caller in that case.
    return dst if dst.nil? || len.nil?

    while dst.size < length && tee(length - dst.size, buf2)
      dst << buf2
    end

    dst
  end

end
