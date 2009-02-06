# non-portable Socket code goes here:
class Socket

  # configure platform-specific options (only tested on Linux 2.6 so far)
  case RUBY_PLATFORM
  when /linux/
    # from /usr/include/linux/tcp.h
    TCP_DEFER_ACCEPT = 9 unless defined?(TCP_DEFER_ACCEPT)
    TCP_CORK = 3 unless defined?(TCP_CORK)

    def unicorn_server_init
      self.setsockopt(SOL_TCP, TCP_DEFER_ACCEPT, 1)
    end
  when /freebsd(([1-4]\..{1,2})|5\.[0-4])/
  when /freebsd/
    # Use the HTTP accept filter if available.
    # The struct made by pack() is defined in /usr/include/sys/socket.h as accept_filter_arg
    unless `/sbin/sysctl -nq net.inet.accf.http`.empty?
      unless defined?(SO_ACCEPTFILTER_HTTPREADY)
        SO_ACCEPTFILTER_HTTPREADY = ['httpready',nil].pack('a16a240').freeze
      end

      def unicorn_server_init
        self.setsockopt(SOL_SOCKET, SO_ACCEPTFILTER, SO_ACCEPTFILTER_HTTPREADY)
      end
    end
  end

  def unicorn_client_init
    self.sync = true
    self.setsockopt(IPPROTO_TCP, TCP_NODELAY, 1) if defined?(TCP_NODELAY)
    self.setsockopt(SOL_TCP, TCP_CORK, 1) if defined?(TCP_CORK)
  end

  def unicorn_peeraddr
    Socket.unpack_sockaddr_in(getpeername)
  end

  # returns the config-friendly name of the current listener socket, this is
  # useful for config reloads and even works across execs where the Unicorn
  # binary is replaced
  def unicorn_addr
    @unicorn_addr ||= if respond_to?(:getsockname)
      port, host = Socket.unpack_sockaddr_in(getsockname)
      "#{host}:#{port}"
    elsif respond_to?(:getsockname)
      addr = Socket.unpack_sockaddr_un(getsockname)
      # strip the pid from the temp socket path
      addr.gsub!(/\.\d+$/, '') or
        raise ArgumentError, "PID not found in path: #{addr}"
    else
      raise ArgumentError, "could not determine unicorn_addr for #{self}"
    end
  end

  class << self

    # creates a new server, address may be a HOST:PORT or
    # an absolute path to a UNIX socket.  When creating a UNIX
    # socket to listen on, we always add a PID suffix to it
    # when binding and then rename it into its intended name to
    # atomically replace and start listening for new connections.
    def unicorn_server_new(address = '0.0.0.0:8080', backlog = 1024)
      domain, bind_addr = if address[0..0] == "/"
        [ AF_UNIX, pack_sockaddr_un("#{address}.#{$$}") ]
      elsif address =~ /^(\d+\.\d+\.\d+\.\d+):(\d+)$/
        [ AF_INET, pack_sockaddr_in($2.to_i, $1) ]
      end
      s = new(domain, SOCK_STREAM, 0)
      s.setsockopt(SOL_SOCKET, SO_REUSEADDR, 1) if defined?(SO_REUSEADDR)
      s.bind(bind_addr)
      s.listen(backlog)
      s.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) if defined?(Fcntl::FD_CLOEXEC)

      # atomically replace existing domain socket
      File.rename("#{address}.#{$$}", address) if domain == AF_UNIX
      s
    end

  end

end

