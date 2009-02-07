# Standard libraries
require 'socket'
require 'tempfile'
require 'time'
require 'uri'
require 'stringio'
require 'fcntl'
require 'logger'
require 'io/nonblock'

# Compiled extension
require 'http11'

require 'unicorn/socket'
require 'unicorn/const'
require 'unicorn/http_request'
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
    attr_reader :workers, :logger, :listeners, :timeout, :nr_workers
    
    DEFAULTS = {
      :timeout => 60,
      :listeners => %w(0.0.0.0:8080),
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

      @listeners.map! { |address| Socket.unicorn_server_new(address, 1024) }
    end

    def process_client(client)
      env = @request.read(client) or return
      app_response = @app.call(env)
      HttpResponse.write(client, app_response)
    rescue EOFError,Errno::ECONNRESET,Errno::EPIPE,Errno::EINVAL,Errno::EBADF
      client.close rescue nil
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
      @request.reset
    end

    # Runs the thing.  Returns a hash keyed by pid with worker number values
    # for which to wait on.  Access the HttpServer.workers attribute
    # to get this hash later.
    def start
      BasicSocket.do_not_reverse_lookup = true
      @listeners.each do |sock|
        sock.unicorn_server_init if sock.respond_to?(:unicorn_server_init)
      end

      (1..@nr_workers).each do |worker_nr|
        pid = fork do
          nr = 0
          alive = true
          listeners = @listeners
          @request = HttpRequest.new(logger)
          trap('TERM') { exit 0 }
          trap('QUIT') do
            alive = false
            @listeners.each { |sock| sock.close rescue nil }
          end

          while alive
            begin
              nr_before = nr
              listeners.each do |sock|
                begin
                  client, addr = begin
                    sock.accept_nonblock
                  rescue Errno::EAGAIN
                    next
                  end
                  nr += 1
                  client.unicorn_client_init
                  process_client(client)
                rescue Errno::ECONNABORTED
                  # client closed the socket even before accept
                  client.close rescue nil
                end
                alive or exit(0)
              end

              # make the following bet: if we accepted clients this round,
              # we're probably reasonably busy, so avoid calling select(2)
              # and try to do a blind non-blocking accept(2) on everything
              # before we sleep again in select
              if nr > nr_before
                listeners = @listeners
              else
                begin
                  ret = IO.select(@listeners, nil, nil, nil) or next
                  listeners = ret[0]
                rescue Errno::EBADF
                  exit(alive ? 1 : 0)
                end
              end
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
      @listeners.each { |sock| sock.close rescue nil }
    end

  end
end
