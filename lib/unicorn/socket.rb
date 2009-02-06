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

  class << self

    def unicorn_tcp_server(host, port, backlog = 5)
      s = new(AF_INET, SOCK_STREAM, 0)
      s.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) if defined?(Fcntl::FD_CLOEXEC)
      s.setsockopt(SOL_SOCKET, SO_REUSEADDR, 1) if defined?(SO_REUSEADDR)
      s.bind(pack_sockaddr_in(port, host))
      s.listen(backlog)
      s
    end

  end

end

