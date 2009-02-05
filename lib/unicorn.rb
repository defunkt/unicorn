
# Standard libraries
require 'socket'
require 'tempfile'
require 'yaml'
require 'time'
require 'etc'
require 'uri'
require 'stringio'
require 'fcntl'
require 'logger'

# Compiled extension
require 'http11'

require 'rack'

require 'unicorn/tcphack'
require 'unicorn/const'
require 'unicorn/http_request'
require 'unicorn/header_out'
require 'unicorn/http_response'

# Unicorn module containing all of the classes (include C extensions) for running
# a Unicorn web server.  It contains a minimalist HTTP server with just enough
# functionality to service web application requests fast as possible.
module Unicorn
  class << self
    # A logger instance that conforms to the API of stdlib's Logger.
    attr_accessor :logger
    
    def run(app, options = {})
      HttpServer.new(app, options).start.join
    end
  end

  # We do this to be compatible with the existing API
  class WorkerTable < Hash
    def join
      begin
        pid = Process.wait
        self.delete(pid)
      rescue Errno::ECHLD
        return
      end
    end
  end

  # This is the main driver of Unicorn, while the Unicorn::HttpParser
  # and make up the majority of how the server functions.  It forks off
  # :nr_workers and has the workers accepting connections on a shared
  # socket and a simple HttpServer.process_client function to
  # do the heavy lifting with the IO and Ruby.
  class HttpServer
    attr_reader :workers, :logger, :host, :port, :timeout, :nr_workers
    
    DEFAULTS = {
      :timeout => 60,
      :host => '0.0.0.0',
      :port => 8080,
      :logger => Logger.new(STDERR),
      :nr_workers => 1
    }

    # Creates a working server on host:port (strange things happen if
    # port isn't a Number).  Use HttpServer::run to start the server and
    # HttpServer.workers.join to join the thread that's processing
    # incoming requests on the socket.
    def initialize(app, options = {})
      @app = app      
      @workers = WorkerTable.new
      
      (DEFAULTS.to_a + options.to_a).each do |key, value|
        instance_variable_set("@#{key.to_s.downcase}", value)
      end

      @socket = TCPServer.new(@host, @port)       
      @socket.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) if defined?(Fcntl::FD_CLOEXEC)

    end

    # Does the majority of the IO processing.  It has been written in Ruby using
    # about 7 different IO processing strategies and no matter how it's done 
    # the performance just does not improve.  It is currently carefully constructed
    # to make sure that it gets the best possible performance, but anyone who
    # thinks they can make it faster is more than welcome to take a crack at it.
    def process_client(client)
      begin
        parser = HttpParser.new
        params = Hash.new
        request = nil
        data = client.readpartial(Const::CHUNK_SIZE)
        nparsed = 0

        # Assumption: nparsed will always be less since data will get filled with more
        # after each parsing.  If it doesn't get more then there was a problem
        # with the read operation on the client socket.  Effect is to stop processing when the
        # socket can't fill the buffer for further parsing.
        while nparsed < data.length
          nparsed = parser.execute(params, data, nparsed)

          if parser.finished?
            if !params[Const::REQUEST_PATH]
              # It might be a dumbass full host request header
              uri = URI.parse(params[Const::REQUEST_URI])
              params[Const::REQUEST_PATH] = uri.path
            end

            raise "No REQUEST PATH" if !params[Const::REQUEST_PATH]
 
            params[Const::PATH_INFO] = params[Const::REQUEST_PATH]
            params[Const::SCRIPT_NAME] = Const::SLASH

            # From http://www.ietf.org/rfc/rfc3875 :
            # "Script authors should be aware that the REMOTE_ADDR and REMOTE_HOST
            #  meta-variables (see sections 4.1.8 and 4.1.9) may not identify the
            #  ultimate source of the request.  They identify the client for the
            #  immediate request to the server; that client may be a proxy, gateway,
            #  or other intermediary acting on behalf of the actual source client."
            params[Const::REMOTE_ADDR] = client.peeraddr.last

            # Select handlers that want more detailed request notification
            request = HttpRequest.new(params, client, logger)

            # in the case of large file uploads the user could close the socket, so skip those requests
            break if request.body == nil  # nil signals from HttpRequest::initialize that the request was aborted
            app_response = @app.call(request.env)
            response = HttpResponse.new(client, app_response).start
          break #done
          else
            # Parser is not done, queue up more data to read and continue parsing
            chunk = client.readpartial(Const::CHUNK_SIZE)
            break if !chunk or chunk.length == 0  # read failed, stop processing

            data << chunk
            if data.length >= Const::MAX_HEADER
              raise HttpParserError.new("HEADER is longer than allowed, aborting client early.")
            end
          end
        end
      rescue EOFError,Errno::ECONNRESET,Errno::EPIPE,Errno::EINVAL,Errno::EBADF
        client.close rescue nil
      rescue HttpParserError => e
        logger.error "HTTP parse error, malformed request (#{params[Const::HTTP_X_FORWARDED_FOR] || client.peeraddr.last}): #{e.inspect}"
        logger.error "REQUEST DATA: #{data.inspect}\n---\nPARAMS: #{params.inspect}\n---\n"
      rescue Errno::EMFILE
        logger.error "too many files"
      rescue Object => e
        logger.error "Read error: #{e.inspect}"
        logger.error e.backtrace.join("\n")
      ensure
        begin
          client.close
        rescue IOError
          # Already closed
        rescue Object => e
          logger.error "Client error: #{e.inspect}"
          logger.error e.backtrace.join("\n")
        end
        request.body.close! if request and request.body.class == Tempfile
      end
    end

    def configure_socket_options
      case RUBY_PLATFORM
      when /linux/
        # 9 is currently TCP_DEFER_ACCEPT
        $tcp_defer_accept_opts = [Socket::SOL_TCP, 9, 1]
        $tcp_cork_opts = [Socket::SOL_TCP, 3, 1]
      when /freebsd(([1-4]\..{1,2})|5\.[0-4])/
        # Do nothing, just closing a bug when freebsd <= 5.4
      when /freebsd/
        # Use the HTTP accept filter if available.
        # The struct made by pack() is defined in /usr/include/sys/socket.h as accept_filter_arg
        unless `/sbin/sysctl -nq net.inet.accf.http`.empty?
          $tcp_defer_accept_opts = [Socket::SOL_SOCKET, Socket::SO_ACCEPTFILTER, ['httpready', nil].pack('a16a240')]
        end
      end
    end
    
    # Runs the thing.  Returns a hash keyed by pid with worker number values
    # for which to wait on.  Access the HttpServer.workers attribute
    # to get this hash later.
    def start
      BasicSocket.do_not_reverse_lookup = true
      configure_socket_options
      if defined?($tcp_defer_accept_opts) and $tcp_defer_accept_opts
        @socket.setsockopt(*$tcp_defer_accept_opts) rescue nil
      end

      (1..@nr_workers).each do |worker_nr|
        pid = fork do
          alive = true
          trap('TERM') { exit 0 }
          trap('QUIT') { alive = false; @socket.close rescue nil }
          while alive
            begin
              client = @socket.accept
              client.sync = true

              if defined?($tcp_cork_opts) and $tcp_cork_opts
                client.setsockopt(*$tcp_cork_opts) rescue nil
              end
              process_client(client)
            rescue Errno::EMFILE
              logger.error "too many open files"
              sleep 0.5
            rescue Errno::ECONNABORTED
              # client closed the socket even before accept
              client.close rescue nil
            rescue Object => e
              if alive
                logger.error "Unhandled listen loop exception #{e.inspect}."
                logger.error e.backtrace.join("\n")
              end
            end
          end
          exit 0
        end # fork

        @workers[pid] = worker_nr
      end

      @workers
    end

    # delivers a signal to each worker
    def kill_each_worker(signal)
      @workers.keys.each do |pid|
        begin
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          @workers.delete(pid)
        end
      end
    end

    # Terminates all workers
    def stop(graceful = true)
      old_chld_handler = trap('CHLD') do
        pid = Process.waitpid(-1, Process::WNOHANG) and @workers.delete(pid)
      end

      kill_each_worker(graceful ? 'QUIT' : 'TERM')

      timeleft = @timeout
      until @workers.empty?
        sleep(1)
        (timeleft -= 1) > 0 and next
        kill_each_worker('KILL')
      end

    ensure
      trap('CHLD', old_chld_handler)
      @socket.close rescue nil
    end

  end
end
