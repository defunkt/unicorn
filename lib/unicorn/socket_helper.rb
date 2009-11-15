# -*- encoding: binary -*-

require 'socket'

module Unicorn
  module SocketHelper
    include Socket::Constants

    # configure platform-specific options (only tested on Linux 2.6 so far)
    case RUBY_PLATFORM
    when /linux/
      # from /usr/include/linux/tcp.h
      TCP_DEFER_ACCEPT = 9 unless defined?(TCP_DEFER_ACCEPT)

      # do not send out partial frames (Linux)
      TCP_CORK = 3 unless defined?(TCP_CORK)
    when /freebsd(([1-4]\..{1,2})|5\.[0-4])/
      # Do nothing for httpready, just closing a bug when freebsd <= 5.4
      TCP_NOPUSH = 4 unless defined?(TCP_NOPUSH) # :nodoc:
    when /freebsd/
      # do not send out partial frames (FreeBSD)
      TCP_NOPUSH = 4 unless defined?(TCP_NOPUSH)

      # Use the HTTP accept filter if available.
      # The struct made by pack() is defined in /usr/include/sys/socket.h
      # as accept_filter_arg
      unless `/sbin/sysctl -nq net.inet.accf.http`.empty?
        # set set the "httpready" accept filter in FreeBSD if available
        # if other protocols are to be supported, this may be
        # String#replace-d with "dataready" arguments instead
        FILTER_ARG = ['httpready', nil].pack('a16a240')
      end
    end

    def set_tcp_sockopt(sock, opt)

      # highly portable, but off by default because we don't do keepalive
      if defined?(TCP_NODELAY) && ! (val = opt[:tcp_nodelay]).nil?
        sock.setsockopt(IPPROTO_TCP, TCP_NODELAY, val ? 1 : 0)
      end

      unless (val = opt[:tcp_nopush]).nil?
        val = val ? 1 : 0
        if defined?(TCP_CORK) # Linux
          sock.setsockopt(IPPROTO_TCP, TCP_CORK, val)
        elsif defined?(TCP_NOPUSH) # TCP_NOPUSH is untested (FreeBSD)
          sock.setsockopt(IPPROTO_TCP, TCP_NOPUSH, val)
        end
      end

      # No good reason to ever have deferred accepts off
      if defined?(TCP_DEFER_ACCEPT)
        sock.setsockopt(SOL_TCP, TCP_DEFER_ACCEPT, 1)
      elsif defined?(SO_ACCEPTFILTER) && defined?(FILTER_ARG)
        sock.setsockopt(SOL_SOCKET, SO_ACCEPTFILTER, FILTER_ARG)
      end
    end

    def set_server_sockopt(sock, opt)
      opt ||= {}

      TCPSocket === sock and set_tcp_sockopt(sock, opt)

      if opt[:rcvbuf] || opt[:sndbuf]
        log_buffer_sizes(sock, "before: ")
        sock.setsockopt(SOL_SOCKET, SO_RCVBUF, opt[:rcvbuf]) if opt[:rcvbuf]
        sock.setsockopt(SOL_SOCKET, SO_SNDBUF, opt[:sndbuf]) if opt[:sndbuf]
        log_buffer_sizes(sock, " after: ")
      end
      sock.listen(opt[:backlog] || 1024)
      rescue => e
        if respond_to?(:logger)
          logger.error "error setting socket options: #{e.inspect}"
          logger.error e.backtrace.join("\n")
        end
    end

    def log_buffer_sizes(sock, pfx = '')
      respond_to?(:logger) or return
      rcvbuf = sock.getsockopt(SOL_SOCKET, SO_RCVBUF).unpack('i')
      sndbuf = sock.getsockopt(SOL_SOCKET, SO_SNDBUF).unpack('i')
      logger.info "#{pfx}#{sock_name(sock)} rcvbuf=#{rcvbuf} sndbuf=#{sndbuf}"
    end

    # creates a new server, socket. address may be a HOST:PORT or
    # an absolute path to a UNIX socket.  address can even be a Socket
    # object in which case it is immediately returned
    def bind_listen(address = '0.0.0.0:8080', opt = {})
      return address unless String === address

      sock = if address[0] == ?/
        if File.exist?(address)
          if File.socket?(address)
            if self.respond_to?(:logger)
              logger.info "unlinking existing socket=#{address}"
            end
            File.unlink(address)
          else
            raise ArgumentError,
                  "socket=#{address} specified but it is not a socket!"
          end
        end
        old_umask = File.umask(opt[:umask] || 0)
        begin
          UNIXServer.new(address)
        ensure
          File.umask(old_umask)
        end
      elsif address =~ /^(\d+\.\d+\.\d+\.\d+):(\d+)$/
        TCPServer.new($1, $2.to_i)
      else
        raise ArgumentError, "Don't know how to bind: #{address}"
      end
      set_server_sockopt(sock, opt)
      sock
    end

    # Returns the configuration name of a socket as a string.  sock may
    # be a string value, in which case it is returned as-is
    # Warning: TCP sockets may not always return the name given to it.
    def sock_name(sock)
      case sock
      when String then sock
      when UNIXServer
        Socket.unpack_sockaddr_un(sock.getsockname)
      when TCPServer
        Socket.unpack_sockaddr_in(sock.getsockname).reverse!.join(':')
      when Socket
        begin
          Socket.unpack_sockaddr_in(sock.getsockname).reverse!.join(':')
        rescue ArgumentError
          Socket.unpack_sockaddr_un(sock.getsockname)
        end
      else
        raise ArgumentError, "Unhandled class #{sock.class}: #{sock.inspect}"
      end
    end

    # casts a given Socket to be a TCPServer or UNIXServer
    def server_cast(sock)
      begin
        Socket.unpack_sockaddr_in(sock.getsockname)
        TCPServer.for_fd(sock.fileno)
      rescue ArgumentError
        UNIXServer.for_fd(sock.fileno)
      end
    end

  end # module SocketHelper
end # module Unicorn
