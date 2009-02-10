require 'logger'

require 'unicorn/socket'
require 'unicorn/const'
require 'unicorn/http_request'
require 'unicorn/http_response'

# Unicorn module containing all of the classes (include C extensions) for running
# a Unicorn web server.  It contains a minimalist HTTP server with just enough
# functionality to service web application requests fast as possible.
module Unicorn
  class << self
    def run(app, options = {})
      HttpServer.new(app, options).start.join
    end
  end

  # This is the process manager of Unicorn. This manages worker
  # processes which in turn handle the I/O and application process.
  # Listener sockets are started in the master process and shared with
  # forked worker children.
  class HttpServer
    attr_reader :logger
    include Process
    include ::Unicorn::SocketHelper

    DEFAULT_START_CTX = {
      :argv => ARGV.map { |arg| arg.dup },
      :cwd => (ENV['PWD'] || Dir.pwd),
      :zero => $0.dup,
      :environ => {}.merge!(ENV),
      :umask => File.umask,
    }.freeze

    DEFAULTS = {
      :timeout => 60,
      :listeners => %w(0.0.0.0:8080),
      :logger => Logger.new(STDERR),
      :nr_workers => 1,
      :after_fork => lambda { |server, worker_nr|
          server.logger.info("worker=#{worker_nr} spawned pid=#{$$}")
        },
      :before_fork => lambda { |server, worker_nr|
          server.logger.info("worker=#{worker_nr} spawning...")
        },
    }
    # Creates a working server on host:port (strange things happen if
    # port isn't a Number).  Use HttpServer::run to start the server and
    # HttpServer.workers.join to join the thread that's processing
    # incoming requests on the socket.
    def initialize(app, options = {})
      (DEFAULTS.to_a + options.to_a).each do |key, value|
        instance_variable_set("@#{key.to_s.downcase}", value)
      end

      @app = app
      @mode = :idle
      @master_pid = $$
      @workers = Hash.new
      @request = HttpRequest.new(logger) # shared between all worker processes
      @start_ctx = DEFAULT_START_CTX.dup
      @start_ctx.merge!(options[:start_ctx]) if options[:start_ctx]
      @purgatory = [] # prevents objects in here from being GC-ed

      # this pipe is used to wake us up from select(2) in #join when signals
      # are trapped.  See trap_deferred
      @rd_sig, @wr_sig = IO.pipe.map do |io|
        set_cloexec(io)
        io.nonblock = true
        io
      end
    end

    # Runs the thing.  Returns self so you can run join on it
    def start
      BasicSocket.do_not_reverse_lookup = true

      # inherit sockets from parents, they need to be plain Socket objects
      # before they become UNIXServer or TCPServer
      inherited = ENV['UNICORN_FD'].to_s.split(/,/).map do |fd|
        io = Socket.for_fd(fd.to_i)
        set_server_sockopt(io)
        logger.info "inherited: #{io} fd=#{fd} addr=#{sock_name(io)}"
        io
      end

      # avoid binding inherited sockets, probably not perfect for TCPSockets
      # but it works for UNIXSockets
      @listeners -= inherited.map { |io| sock_name(io) }

      # try binding new listeners
      @listeners.map! do |addr|
        if sock = bind_listen(addr, 1024)
          sock
        elsif inherited.empty? || addr[0..0] == "/"
          raise Errno::EADDRINUSE, "couldn't bind #{addr}"
        else
          logger.info "couldn't bind #{addr}, inherited?"
          nil
        end
      end
      @listeners += inherited
      @listeners.compact!
      @listeners.empty? and raise ArgumentError, 'No listener sockets'

      # we start out with generic Socket objects that get cast to either
      # TCPServer or UNIXServer objects; but since the Socket objects
      # share the same OS-level file descriptor as the higher-level *Server
      # objects; we need to prevent Socket objects from being garbage-collected
      @purgatory += @listeners
      @listeners.map! { |io| server_cast(io) }
      @listeners.each do |io|
        logger.info "#{io} listening on fd=#{io.fileno} addr=#{sock_name(io)}"
      end
      spawn_missing_workers
      self
    end

    # monitors children and receives signals forever
    # (or until a termination signal is sent)
    def join
      %w(QUIT INT TERM USR1 USR2 HUP).each { |sig| trap_deferred(sig) }
      begin
        loop do
          reap_all_workers
          case @mode
          when :idle
            kill_each_worker(0) # ensure they're running
            spawn_missing_workers
          when 'QUIT' # graceful shutdown
            break
          when 'TERM', 'INT' # immediate shutdown
            stop(false)
            break
          when 'USR1' # user-defined (probably something like log reopening)
            kill_each_worker('USR1')
            @mode = :idle
            trap_deferred('USR1')
          when 'USR2' # exec binary, stay alive in case something went wrong
            reexec
            @mode = :idle
            trap_deferred('USR2')
          when 'HUP' # exec binary and exit
            reexec
            break
          else
            logger.error "master process in unknown mode: #{@mode}, resetting"
            @mode = :idle
          end
          reap_all_workers
          ready = IO.select([@rd_sig], nil, nil, 1) or next
          ready[0] && ready[0][0] or next
          begin # just consume the pipe when we're awakened, @mode is set
            loop { @rd_sig.sysread(Const::CHUNK_SIZE) }
          rescue Errno::EAGAIN
          end
        end
      rescue Errno::EINTR
        retry
      rescue Object => e
        logger.error "Unhandled master loop exception #{e.inspect}."
        logger.error e.backtrace.join("\n")
        sleep 1 rescue nil
        retry
      end
      stop # gracefully shutdown all workers on our way out
      logger.info "master pid=#{$$} exit"
    end

    # Terminates all workers, but does not exit master process
    def stop(graceful = true)
      kill_each_worker(graceful ? 'QUIT' : 'TERM')
      timeleft = @timeout
      step = 0.2
      reap_all_workers
      until @workers.empty?
        sleep(step)
        reap_all_workers
        (timeleft -= step) > 0 and next
        kill_each_worker('KILL')
      end
    ensure
      @listeners.each { |sock| sock.close rescue nil }
      @listeners.clear
    end

    private

    # defer a signal for later processing in #join (master process)
    def trap_deferred(signal)
      trap(signal) do |sig_nr|
        trap(signal, 'IGNORE') # prevent double signalling
        if Symbol === @mode
          @mode = signal
          begin
            @wr_sig.syswrite('.') # wakeup master process from IO.select
          rescue Errno::EAGAIN
          rescue Errno::EINTR
            retry
          end
        end
      end
    end

    # reaps all unreaped workers
    def reap_all_workers
      begin
        loop do
          pid = waitpid(-1, WNOHANG) or break
          worker_nr = @workers.delete(pid)
          logger.info "reaped pid=#{pid} worker=#{worker_nr || 'unknown'} " \
                      "status=#{$?.exitstatus}"
        end
      rescue Errno::ECHILD
      end
    end

    # Forks, sets current environment, sets the umask, chdirs to the desired
    # start directory, and execs the command line originally passed to us to
    # start Unicorn.
    # Returns the pid of the forked process
    def spawn_start_ctx(check = nil)
      fork do
        ENV.replace(@start_ctx[:environ])
        ENV['UNICORN_FD'] = @listeners.map { |sock| sock.fileno }.join(',')
        File.umask(@start_ctx[:umask])
        Dir.chdir(@start_ctx[:cwd])
        cmd = [ @start_ctx[:zero] ] + @start_ctx[:argv]
        cmd << 'check' if check
        logger.info "executing #{cmd.inspect}"
        exec *cmd
      end
    end

    # ensures @start_ctx is reusable for re-execution
    def check_reexec
      pid = waitpid(spawn_start_ctx(:check))
      $?.success? and return true
      logger.error "exec check failed with #{$?.exitstatus}"
    end

    # reexecutes the @start_ctx with a new binary
    def reexec
      check_reexec or return false
      pid = spawn_start_ctx
      if waitpid(pid, WNOHANG)
        logger.error "rexec pid=#{pid} died with #{$?.exitstatus}"
      end
    end

    def spawn_missing_workers
      return if @workers.size == @nr_workers
      (0...@nr_workers).each do |worker_nr|
        @workers.values.include?(worker_nr) and next
        @before_fork.call(self, worker_nr)
        pid = fork { worker_loop(worker_nr) }
        @workers[pid] = worker_nr
      end
    end

    # once a client is accepted, it is processed in its entirety here
    # in 3 easy steps: read request, call app, write app response
    def process_client(client, client_nr)
      env = @request.read(client) or return
      app_response = @app.call(env)
      HttpResponse.write(client, app_response)
    rescue EOFError,Errno::ECONNRESET,Errno::EPIPE,Errno::EINVAL,Errno::EBADF
      client.closed? or client.close rescue nil
    rescue Object => e
      logger.error "Read error: #{e.inspect}"
      logger.error e.backtrace.join("\n")
    ensure
      begin
        client.closed? or client.close
      rescue Object => e
        logger.error "Client error: #{e.inspect}"
        logger.error e.backtrace.join("\n")
      end
      @request.reset
    end

    # runs inside each forked worker, this sits around and waits
    # for connections and doesn't die until the parent dies
    def worker_loop(worker_nr)
      @rd_sig.close
      @wr_sig.close
      # allow @after_fork to override these signals:
      %w(USR1 USR2 HUP).each { |sig| trap(sig, 'IGNORE') }
      @after_fork.call(self, worker_nr) if @after_fork

      @listeners.each { |sock| set_cloexec(sock) }
      nr_before = nr = 0
      client = nil
      alive = true
      ready = @listeners
      %w(TERM INT).each { |sig| trap(sig) { exit(0) } } # instant shutdown
      trap('QUIT') do
        alive = false
        @listeners.each { |sock| sock.close rescue nil } # break IO.select
      end

      while alive && @master_pid == ppid
        begin
          nr_before = nr
          ready.each do |sock|
            begin
              client = begin
                sock.accept_nonblock
              rescue Errno::EAGAIN
                next
              end
              client.sync = true
              client.nonblock = false
              set_client_sockopt(client) if client.class == TCPSocket
              nr += 1
              process_client(client, nr)
            rescue Errno::ECONNABORTED
              # client closed the socket even before accept
              if client && !client.closed?
                client.close rescue nil
              end
            end
          end

          # make the following bet: if we accepted clients this round,
          # we're probably reasonably busy, so avoid calling select(2)
          # and try to do a blind non-blocking accept(2) on everything
          # before we sleep again in select
          if nr != nr_before
            ready = @listeners
          else
            begin
              # timeout used so we can detect parent death:
              ret = IO.select(@listeners, nil, nil, @timeout) or next
              ready = ret[0]
            rescue Errno::EBADF => e
              exit(alive ? 1 : 0)
            end
          end
        rescue SystemExit => e
          exit(e.status)
        rescue Object => e
          if alive
            logger.error "Unhandled listen loop exception #{e.inspect}."
            logger.error e.backtrace.join("\n")
          end
        end
      end
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

  end
end
