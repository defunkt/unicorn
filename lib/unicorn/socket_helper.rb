# -*- encoding: binary -*-
# :enddoc:
require 'socket'

module Unicorn
  module SocketHelper
    include Socket::Constants

    # :stopdoc:
    # internal interface, only used by Rainbows!/Zbatery
    DEFAULTS = {
      # The semantics for TCP_DEFER_ACCEPT changed in Linux 2.6.32+
      # with commit d1b99ba41d6c5aa1ed2fc634323449dd656899e9
      # This change shouldn't affect Unicorn users behind nginx (a
      # value of 1 remains an optimization), but Rainbows! users may
      # want to use a higher value on Linux 2.6.32+ to protect against
      # denial-of-service attacks
      :tcp_defer_accept => 1,

      # FreeBSD, we need to override this to 'dataready' when we
      # eventually get HTTPS support
      :accept_filter => 'httpready',
    }
    #:startdoc:

    # configure platform-specific options (only tested on Linux 2.6 so far)
    case RUBY_PLATFORM
    when /linux/
      # from /usr/include/linux/tcp.h
      TCP_DEFER_ACCEPT = 9 unless defined?(TCP_DEFER_ACCEPT)

      # do not send out partial frames (Linux)
      TCP_CORK = 3 unless defined?(TCP_CORK)
    when /freebsd/
      # do not send out partial frames (FreeBSD)
      TCP_NOPUSH = 4 unless defined?(TCP_NOPUSH)

      def accf_arg(af_name)
        [ af_name, nil ].pack('a16a240')
      end if defined?(SO_ACCEPTFILTER)
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
      # (except maybe benchmarking)
      if defined?(TCP_DEFER_ACCEPT)
        # this differs from nginx, since nginx doesn't allow us to
        # configure the the timeout...
        tmp = DEFAULTS.merge(opt)
        seconds = tmp[:tcp_defer_accept]
        seconds = DEFAULTS[:tcp_defer_accept] if seconds == true
        seconds = 0 unless seconds # nil/false means disable this
        sock.setsockopt(SOL_TCP, TCP_DEFER_ACCEPT, seconds)
      elsif respond_to?(:accf_arg)
        tmp = DEFAULTS.merge(opt)
        if name = tmp[:accept_filter]
          begin
            sock.setsockopt(SOL_SOCKET, SO_ACCEPTFILTER, accf_arg(name))
          rescue => e
            logger.error("#{sock_name(sock)} " \
                         "failed to set accept_filter=#{name} (#{e.inspect})")
          end
        end
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
        logger.error "error setting socket options: #{e.inspect}"
        logger.error e.backtrace.join("\n")
    end

    def log_buffer_sizes(sock, pfx = '')
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
            begin
              UNIXSocket.new(address).close
              # fall through, try to bind(2) and fail with EADDRINUSE
              # (or succeed from a small race condition we can't sanely avoid).
            rescue Errno::ECONNREFUSED
              logger.info "unlinking existing socket=#{address}"
              File.unlink(address)
            end
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

    module_function :sock_name

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
