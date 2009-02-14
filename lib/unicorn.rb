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
      :hot_config_file => nil,
      :after_fork => lambda { |server, worker_nr|
          server.logger.info("worker=#{worker_nr} spawned pid=#{$$}")

          # per-process listener ports for debugging/admin:
          # server.add_listener("127.0.0.1:#{8081 + worker_nr}")
        },
      :before_fork => lambda { |server, worker_nr|
          server.logger.info("worker=#{worker_nr} spawning...")
        },
      :pid_file => nil,
      :listen_backlog => 1024,
    }

    Worker = Struct.new(:nr, :tempfile) unless defined?(Worker)
    class Worker
      # worker objects may be compared to just plain numbers
      def ==(other_nr)
        self.nr == other_nr
      end
    end

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
      @rd_sig = @wr_sig = nil
      load_hot_config! if @hot_config_file
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

      if @pid_file
        if pid = pid_file_valid?(@pid_file)
          raise ArgumentError, "Already running on pid=#{pid} ",
                               "(or pid_file=#{@pid_file} is stale)"
        end
        File.open(@pid_file, 'wb') { |fp| fp.syswrite("#{$$}\n") }
        at_exit { unlink_pid_file_safe(@pid_file) }
      end

      # avoid binding inherited sockets, probably not perfect for TCPSockets
      # but it works for UNIXSockets
      @listeners -= inherited.map { |io| sock_name(io) }

      # try binding new listeners
      @listeners.map! do |addr|
        if sock = bind_listen(addr, @listen_backlog)
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

    # Allows workers to add a private, per-process listener via the
    # @after_fork hook.  Very useful for debugging and testing.
    def add_listener(address)
      if io = bind_listen(address, @listen_backlog)
        @purgatory << io
        io = server_cast(io)
        logger.info "#{io} listening on pid=#{$$} " \
                    "fd=#{io.fileno} addr=#{sock_name(io)}"
        @listeners << io
      else
        logger.error "adding listener failed addr=#{address} (in use)"
        raise Errno::EADDRINUSE, address
      end
    end

    # monitors children and receives signals forever
    # (or until a termination signal is sent).  This handles signals
    # one-at-a-time time and we'll happily drop signals in case somebody
    # is signalling us too often.
    def join
      # this pipe is used to wake us up from select(2) in #join when signals
      # are trapped.  See trap_deferred
      @rd_sig, @wr_sig = IO.pipe unless (@rd_sig && @wr_sig)
      @rd_sig.nonblock = @wr_sig.nonblock = true

      %w(CHLD QUIT INT TERM USR1 USR2 HUP).each { |sig| trap_deferred(sig) }
      $0 = "unicorn master"
      begin
        loop do
          reap_all_workers
          case @mode
          when :idle
            murder_lazy_workers
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
          when 'HUP'
            if @hot_config_file
              load_hot_config!
              @mode = :idle
              trap_deferred('HUP')
              redo # immediate reaping since we may have QUIT workers
            else # exec binary and exit
              reexec
              break
            end
          else
            logger.error "master process in unknown mode: #{@mode}, resetting"
            @mode = :idle
          end
          reap_all_workers

          ready = begin
            IO.select([@rd_sig], nil, nil, 1) or next
          rescue Errno::EINTR # next
          end
          ready[0] && ready[0][0] or next
          begin # just consume the pipe when we're awakened, @mode is set
            loop { @rd_sig.sysread(Const::CHUNK_SIZE) }
          rescue Errno::EAGAIN, Errno::EINTR # next
          end
        end
      rescue Errno::EINTR
        retry
      rescue Object => e
        logger.error "Unhandled master loop exception #{e.inspect}."
        logger.error e.backtrace.join("\n")
        retry
      end
      stop # gracefully shutdown all workers on our way out
      logger.info "master pid=#{$$} join complete"
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
          worker = @workers.delete(pid)
          worker.tempfile.close rescue nil
          logger.info "reaped pid=#{pid} " \
                      "worker=#{worker && worker.nr || 'unknown'} " \
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
        @rd_sig.close if @rd_sig
        @wr_sig.close if @wr_sig
        @workers.values.each { |other| other.tempfile.close rescue nil }

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

      if @pid_file # clear the path for a new pid file
        old_pid_file = "#{@pid_file}.oldbin"
        if old_pid = pid_file_valid?(old_pid_file)
          logger.error "old pid=#{old_pid} running with " \
                       "existing pid_file=#{old_pid_file}, refusing rexec"
          return
        end
        File.open(old_pid_file, 'wb') { |fp| fp.syswrite("#{$$}\n") }
        at_exit { unlink_pid_file_safe(old_pid_file) }
        File.unlink(@pid_file) if File.exist?(@pid_file)
      end

      pid = spawn_start_ctx
      if waitpid(pid, WNOHANG)
        logger.error "rexec pid=#{pid} died with #{$?.exitstatus}"
      end
    end

    # forcibly terminate all workers that haven't checked in in @timeout
    # seconds.  The timeout is implemented using an unlinked tempfile
    # shared between the parent process and each worker.  The worker
    # runs File#chmod to modify the ctime of the tempfile.  If the ctime
    # is stale for >@timeout seconds, then we'll kill the corresponding
    # worker.
    def murder_lazy_workers
      now = Time.now
      @workers.each_pair do |pid, worker|
        (now - worker.tempfile.ctime) <= @timeout and next
        logger.error "worker=#{worker.nr} pid=#{pid} is too old, killing"
        kill_worker('KILL', pid) # take no prisoners for @timeout violations
        worker.tempfile.close rescue nil
      end
    end

    def spawn_missing_workers
      return if @workers.size == @nr_workers
      (0...@nr_workers).each do |worker_nr|
        @workers.values.include?(worker_nr) and next
        tempfile = Tempfile.new('') # as short as possible to save dir space
        tempfile.unlink # don't allow other processes to find or see it
        tempfile.sync = true
        worker = Worker.new(worker_nr, tempfile)
        @before_fork.call(self, worker.nr)
        pid = fork { worker_loop(worker) }
        @workers[pid] = worker
      end
    end

    # once a client is accepted, it is processed in its entirety here
    # in 3 easy steps: read request, call app, write app response
    def process_client(client)
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

    # gets rid of stuff the worker has no business keeping track of
    # to free some resources and drops all sig handlers.
    # traps for USR1, USR2, and HUP may be set in the @after_fork Proc
    # by the user.
    def init_worker_process(worker)
      %w(TERM INT QUIT USR1 USR2 HUP).each { |sig| trap(sig, 'IGNORE') }
      trap('CHLD', 'DEFAULT')
      $0 = "unicorn worker[#{worker.nr}]"
      @rd_sig.close if @rd_sig
      @wr_sig.close if @wr_sig
      @workers.values.each { |other| other.tempfile.close rescue nil }
      @workers.clear
      @start_ctx.clear
      @mode = @start_ctx = @workers = @rd_sig = @wr_sig = nil
      @listeners.each { |sock| set_cloexec(sock) }
      ENV.delete('UNICORN_DAEMONIZE')
      ENV.delete('UNICORN_FD')
      @after_fork.call(self, worker.nr) if @after_fork
    end

    # runs inside each forked worker, this sits around and waits
    # for connections and doesn't die until the parent dies (or is
    # given a INT, QUIT, or TERM signal)
    def worker_loop(worker)
      init_worker_process(worker)
      nr = 0
      tempfile = worker.tempfile
      alive = true
      ready = @listeners
      client = nil
      %w(TERM INT).each { |sig| trap(sig) { exit(0) } } # instant shutdown
      trap('QUIT') do
        alive = false
        @listeners.each { |sock| sock.close rescue nil } # break IO.select
      end

      while alive && @master_pid == ppid
        # we're a goner in @timeout seconds anyways if tempfile.chmod
        # breaks, so don't trap the exception.  Using fchmod() since
        # futimes() is not available in base Ruby and I very strongly
        # prefer temporary files to be unlinked for security,
        # performance and reliability reasons, so utime is out.  No-op
        # changes with chmod doesn't update ctime on all filesystems; so
        # we increment our counter each and every time.
        tempfile.chmod(nr += 1)

        begin
          accepted = false
          ready.each do |sock|
            begin
              client = begin
                sock.accept_nonblock
              rescue Errno::EAGAIN
                next
              end
              accepted = client.sync = true
              client.nonblock = false
              set_client_sockopt(client) if TCPSocket === client
              process_client(client)
            rescue Errno::ECONNABORTED
              # client closed the socket even before accept
              if client && !client.closed?
                client.close rescue nil
              end
            end
            tempfile.chmod(nr += 1)
          end
          client = nil

          # make the following bet: if we accepted clients this round,
          # we're probably reasonably busy, so avoid calling select(2)
          # and try to do a blind non-blocking accept(2) on everything
          # before we sleep again in select
          if accepted
            ready = @listeners
          else
            begin
              tempfile.chmod(nr += 1)
              # timeout used so we can detect parent death:
              ret = IO.select(@listeners, nil, nil, @timeout/2.0) or next
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

    # delivers a signal to a worker and fails gracefully if the worker
    # is no longer running.
    def kill_worker(signal, pid)
      begin
        kill(signal, pid)
      rescue Errno::ESRCH
        worker = @workers.delete(pid) and worker.tempfile.close rescue nil
      end
    end

    # delivers a signal to each worker
    def kill_each_worker(signal)
      @workers.keys.each { |pid| kill_worker(signal, pid) }
    end

    # unlinks a PID file at given +path+ if it contains the current PID
    # useful as an at_exit handler.
    def unlink_pid_file_safe(path)
      (File.read(path).to_i == $$ and File.unlink(path)) rescue nil
    end

    # returns a PID if a given path contains a non-stale PID file,
    # nil otherwise.
    def pid_file_valid?(path)
      if File.exist?(path) && (pid = File.read(path).to_i) > 1
        begin
          kill(0, pid)
          return pid
        rescue Errno::ESRCH
        end
      end
      nil
    end

    # only do minimal validation, assume the user knows what they're doing
    def load_hot_config!
      log_pfx = "hot_config_file=#{@hot_config_file}"
      begin
        unless File.readable?(@hot_config_file)
          logger.error "#{log_pfx} not readable"
          return
        end
        hot_config = File.read(@hot_config_file)
        nr_workers, timeout = @nr_workers, @timeout
        eval(hot_config)
        if Numeric === @timeout
          if timeout != @timeout
            logger.info "#{log_pfx} set: timeout=#{@timeout}"
            if timeout > @timeout # we don't want to have to KILL them later
              logger.info "restarting all workers because timeout got lowered"
              kill_each_worker('QUIT')
            end
          end
        else
          logger.info "#{log_pfx} invalid: timeout=#{@timeout.inspect}"
          @timeout = timeout
        end
        if Integer === @nr_workers
          to_kill = nr_workers - @nr_workers
          if to_kill != 0
            logger.info "#{log_pfx} set: nr_workers=#{@nr_workers}"
            if to_kill > 0
              @workers.keys[0...to_kill].each { |pid| kill_worker('QUIT', pid) }
            end
          end
        else
          logger.info "#{log_pfx} invalid: nr_workers=#{@nr_workers.inspect}"
          @nr_workers = nr_workers
        end
      rescue Object => e
        logger.error "#{log_pfx} error: #{e.message}"
      end
    end

  end
end
