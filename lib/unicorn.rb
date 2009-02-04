
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

# Gem conditional loader
require 'thread'
require 'rack'

require 'unicorn/tcphack'
require 'unicorn/const'
require 'unicorn/http_request'
require 'unicorn/header_out'
require 'unicorn/http_response'
require 'unicorn/semaphore'

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

  # Used to stop the HttpServer via Thread.raise.
  class StopServer < Exception; end

  # Thrown at a thread when it is timed out.
  class TimeoutError < Exception; end

  # Thrown by HttpServer#stop if the server is not started.
  class AcceptorError < StandardError; end

  #
  # This is the main driver of Unicorn, while the Unicorn::HttpParser and Unicorn::URIClassifier
  # make up the majority of how the server functions.  It's a very simple class that just
  # has a thread accepting connections and a simple HttpServer.process_client function
  # to do the heavy lifting with the IO and Ruby.  
  #
  class HttpServer
    attr_reader :acceptor, :workers, :logger, :host, :port, :timeout, :max_queued_threads, :max_concurrent_threads
    
    DEFAULTS = {
      :timeout => 60,
      :host => '0.0.0.0',
      :port => 8080,
      :logger => Logger.new(STDERR),
      :max_queued_threads => 12, 
      :max_concurrent_threads => 4
    }

    # Creates a working server on host:port (strange things happen if port isn't a Number).
    # Use HttpServer::run to start the server and HttpServer.acceptor.join to 
    # join the thread that's processing incoming requests on the socket.
    #
    # The max_queued_threads optional argument is the maximum number of concurrent
    # processors to accept, anything over this is closed immediately to maintain
    # server processing performance.  This may seem mean but it is the most efficient
    # way to deal with overload.  Other schemes involve still parsing the client's request
    # which defeats the point of an overload handling system.
    # 
    def initialize(app, options = {})
      @app = app      
      @workers = ThreadGroup.new
      
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
        reap_dead_workers('too many files')
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

    # Used internally to kill off any worker threads that have taken too long
    # to complete processing.  Only called if there are too many processors
    # currently servicing.  It returns the count of workers still active
    # after the reap is done.  It only runs if there are workers to reap.
    def reap_dead_workers(reason='unknown')
      if @workers.list.length > 0
        logger.info "Reaping #{@workers.list.length} threads for slow workers because of '#{reason}'"
        error_msg = "Unicorn timed out this thread: #{reason}"
        mark = Time.now
        @workers.list.each do |worker|
          worker[:started_on] = Time.now if not worker[:started_on]

          if mark - worker[:started_on] > @timeout
            logger.info "Thread #{worker.inspect} is too old, killing."
            worker.raise(TimeoutError.new(error_msg))
          end
        end
      end

      return @workers.list.length
    end

    # Performs a wait on all the currently running threads and kills any that take
    # too long.  It waits by @timeout seconds, which can be set in .initialize or
    # via mongrel_rails.
    def graceful_shutdown
      while reap_dead_workers("shutdown") > 0
        logger.info "Waiting for #{@workers.list.length} requests to finish, could take #{@timeout} seconds."
        sleep @timeout / 10
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
    
    # Runs the thing.  It returns the thread used so you can "join" it.  You can also
    # access the HttpServer::acceptor attribute to get the thread later.
    def start
      semaphore = Semaphore.new(@max_concurrent_threads)
      BasicSocket.do_not_reverse_lookup = true

      configure_socket_options

      if defined?($tcp_defer_accept_opts) and $tcp_defer_accept_opts
        @socket.setsockopt(*$tcp_defer_accept_opts) rescue nil
      end

      @acceptor = Thread.new do
        begin
          while true
            begin
              client = @socket.accept
  
              if defined?($tcp_cork_opts) and $tcp_cork_opts
                client.setsockopt(*$tcp_cork_opts) rescue nil
              end
  
              worker_list = @workers.list
              if worker_list.length >= @max_queued_threads
                logger.error "Server overloaded with #{worker_list.length} processors (#@max_queued_threads max). Dropping connection."
                client.close rescue nil
                reap_dead_workers("max processors")
              else
                thread = Thread.new(client) {|c| semaphore.synchronize { process_client(c) } }
                thread[:started_on] = Time.now
                @workers.add(thread)
              end
            rescue StopServer
              break
            rescue Errno::EMFILE
              reap_dead_workers("too many open files")
              sleep 0.5
            rescue Errno::ECONNABORTED
              # client closed the socket even before accept
              client.close rescue nil
            rescue Object => e
              logger.error "Unhandled listen loop exception #{e.inspect}."
              logger.error e.backtrace.join("\n")
            end
          end
          graceful_shutdown
        ensure
          @socket.close
          logger.info "Closed socket."
        end
      end

      @acceptor
    end

    # Stops the acceptor thread and then causes the worker threads to finish
    # off the request queue before finally exiting.
    def stop(synchronous = false)
      raise AcceptorError, "Server was not started." unless @acceptor
      @acceptor.raise(StopServer.new)
      (sleep(0.5) while @acceptor.alive?) if synchronous
      @acceptor = nil
    end
  end
end
