require 'logger'

require 'unicorn/socket'
require 'unicorn/const'
require 'unicorn/http_request'
require 'unicorn/http_response'
require 'unicorn/configurator'
require 'unicorn/util'

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
      # don't rely on Dir.pwd here since it's not symlink-aware, and
      # symlink dirs are the default with Capistrano...
      :cwd => `/bin/sh -c pwd`.chomp("\n"),
      :zero => $0.dup,
      :environ => {}.merge!(ENV),
      :umask => File.umask,
    }.freeze

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
      start_ctx = options.delete(:start_ctx)
      @start_ctx = DEFAULT_START_CTX.dup
      @start_ctx.merge!(start_ctx) if start_ctx
      @app = app
      @mode = :idle
      @master_pid = $$
      @workers = Hash.new
      @io_purgatory = [] # prevents IO objects in here from being GC-ed
      @request = @rd_sig = @wr_sig = nil
      @reexec_pid = 0
      @config = Configurator.new(options.merge(:use_defaults => true))
      @config.commit!(self, :skip => [:listeners, :pid])
      @listeners = []
    end

    # Runs the thing.  Returns self so you can run join on it
    def start
      BasicSocket.do_not_reverse_lookup = true

      # inherit sockets from parents, they need to be plain Socket objects
      # before they become UNIXServer or TCPServer
      inherited = ENV['UNICORN_FD'].to_s.split(/,/).map do |fd|
        io = Socket.for_fd(fd.to_i)
        set_server_sockopt(io)
        @io_purgatory << io
        logger.info "inherited: #{io} fd=#{fd} addr=#{sock_name(io)}"
        server_cast(io)
      end

      config_listeners = @config[:listeners].dup
      @listeners.replace(inherited)

      # we start out with generic Socket objects that get cast to either
      # TCPServer or UNIXServer objects; but since the Socket objects
      # share the same OS-level file descriptor as the higher-level *Server
      # objects; we need to prevent Socket objects from being garbage-collected
      config_listeners -= listener_names
      config_listeners.each { |addr| listen(addr) }
      listen(Const::DEFAULT_LISTENER) if @listeners.empty?
      self.pid = @config[:pid]
      build_app! if @preload_app
      spawn_missing_workers
      self
    end

    # replaces current listener set with +listeners+.  This will
    # close the socket if it will not exist in the new listener set
    def listeners=(listeners)
      cur_names = listener_names
      set_names = listener_names(listeners)
      dead_names = cur_names - set_names

      @listeners.delete_if do |io|
        if dead_names.include?(sock_name(io))
          @io_purgatory.delete_if { |pio| pio.fileno == io.fileno }
          destroy_safely(io)
          true
        else
          false
        end
      end

      (set_names - cur_names).each { |addr| listen(addr) }
    end

    # sets the path for the PID file of the master process
    def pid=(path)
      if path
        if x = valid_pid?(path)
          return path if @pid && path == @pid && x == $$
          raise ArgumentError, "Already running on PID:#{x} " \
                               "(or pid=#{path} is stale)"
        end
        File.open(path, 'wb') { |fp| fp.syswrite("#{$$}\n") }
      end
      unlink_pid_safe(@pid) if @pid && @pid != path
      @pid = path
    end

    # sets the path for running the master and worker process, useful for
    # running and reexecuting from a symlinked path like Capistrano allows
    def directory=(path)
      Dir.chdir(path) if path
      @directory = path
    end

    # add a given address to the +listeners+ set, idempotently
    # Allows workers to add a private, per-process listener via the
    # @after_fork hook.  Very useful for debugging and testing.
    def listen(address)
      return if String === address && listener_names.include?(address)

      if io = bind_listen(address, @backlog)
        if Socket == io.class
          @io_purgatory << io
          io = server_cast(io)
        end
        logger.info "#{io} listening on PID:#{$$} " \
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

      reset_master
      $0 = "unicorn master"
      logger.info "master process ready" # test relies on this message
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
            Unicorn::Util.reopen_logs
            reset_master
          when 'USR2' # exec binary, stay alive in case something went wrong
            reexec
            reset_master
          when 'HUP'
            if @config.config_file
              load_config!
              reset_master
              redo # immediate reaping since we may have QUIT workers
            else # exec binary and exit if there's no config file
              logger.info "config_file not present, reexecuting binary"
              reexec
              break
            end
          else
            logger.error "master process in unknown mode: #{@mode}, resetting"
            reset_master
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
        reset_master
        retry
      end
      stop # gracefully shutdown all workers on our way out
      logger.info "master PID:#{$$} join complete"
      unlink_pid_safe(@pid) if @pid
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
      self.listeners = []
    end

    private

    # list of signals we care about and trap in master.
    TRAP_SIGS = %w(QUIT INT TERM USR1 USR2 HUP).map { |x| x.freeze }.freeze

    # defer a signal for later processing in #join (master process)
    def trap_deferred(signal)
      trap(signal) do |sig_nr|
        # we only handle/defer one signal at a time and ignore all others
        # until we're ready again.  Queueing signals can lead to more bugs,
        # and simplicity is the most important thing
        TRAP_SIGS.each { |sig| trap(sig, 'IGNORE') }
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


    def reset_master
      @mode = :idle
      TRAP_SIGS.each { |sig| trap_deferred(sig) }
    end

    # reaps all unreaped workers
    def reap_all_workers
      begin
        loop do
          pid = waitpid(-1, WNOHANG) or break
          if @reexec_pid == pid
            logger.error "reaped exec()-ed PID:#{pid} status=#{$?.exitstatus}"
            @reexec_pid = 0
            self.pid = @pid.chomp('.oldbin') if @pid
          else
            worker = @workers.delete(pid)
            worker.tempfile.close rescue nil
            logger.info "reaped PID:#{pid} " \
                        "worker=#{worker.nr rescue 'unknown'} " \
                        "status=#{$?.exitstatus}"
          end
        end
      rescue Errno::ECHILD
      end
    end

    # reexecutes the @start_ctx with a new binary
    def reexec
      if @reexec_pid > 0
        begin
          Process.kill(0, @reexec_pid)
          logger.error "reexec-ed child already running PID:#{@reexec_pid}"
          return
        rescue Errno::ESRCH
          @reexec_pid = 0
        end
      end

      if @pid
        old_pid = "#{@pid}.oldbin"
        prev_pid = @pid.dup
        begin
          self.pid = old_pid  # clear the path for a new pid file
        rescue ArgumentError
          logger.error "old PID:#{valid_pid?(old_pid)} running with " \
                       "existing pid=#{old_pid}, refusing rexec"
          return
        rescue Object => e
          logger.error "error writing pid=#{old_pid} #{e.class} #{e.message}"
          return
        end
      end

      @reexec_pid = fork do
        @rd_sig.close if @rd_sig
        @wr_sig.close if @wr_sig
        @workers.values.each { |other| other.tempfile.close rescue nil }

        ENV.replace(@start_ctx[:environ])
        ENV['UNICORN_FD'] = @listeners.map { |sock| sock.fileno }.join(',')
        File.umask(@start_ctx[:umask])
        Dir.chdir(@directory || @start_ctx[:cwd])
        cmd = [ @start_ctx[:zero] ] + @start_ctx[:argv]
        logger.info "executing #{cmd.inspect} (in #{Dir.pwd})"
        exec(*cmd)
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
        logger.error "worker=#{worker.nr} PID:#{pid} is too old, killing"
        kill_worker('KILL', pid) # take no prisoners for @timeout violations
        worker.tempfile.close rescue nil
      end
    end

    def spawn_missing_workers
      return if @workers.size == @worker_processes
      (0...@worker_processes).each do |worker_nr|
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
      build_app! unless @preload_app
      TRAP_SIGS.each { |sig| trap(sig, 'IGNORE') }
      trap('CHLD', 'DEFAULT')
      trap('USR1') do
        @logger.info "worker=#{worker.nr} rotating logs..."
        Unicorn::Util.reopen_logs
        @logger.info "worker=#{worker.nr} done rotating logs"
      end

      $0 = "unicorn worker[#{worker.nr}]"
      @rd_sig.close if @rd_sig
      @wr_sig.close if @wr_sig
      @workers.values.each { |other| other.tempfile.close rescue nil }
      @workers.clear
      @start_ctx.clear
      @mode = @start_ctx = @workers = @rd_sig = @wr_sig = nil
      @listeners.each { |sock| set_cloexec(sock) }
      ENV.delete('UNICORN_FD')
      @after_fork.call(self, worker.nr) if @after_fork
      @request = HttpRequest.new(logger)
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
            rescue Errno::EINTR
              ready = @listeners
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
    def unlink_pid_safe(path)
      (File.read(path).to_i == $$ and File.unlink(path)) rescue nil
    end

    # returns a PID if a given path contains a non-stale PID file,
    # nil otherwise.
    def valid_pid?(path)
      if File.exist?(path) && (pid = File.read(path).to_i) > 1
        begin
          kill(0, pid)
          return pid
        rescue Errno::ESRCH
        end
      end
      nil
    end

    def load_config!
      begin
        logger.info "reloading config_file=#{@config.config_file}"
        @config.reload
        @config.commit!(self)
        kill_each_worker('QUIT')
        logger.info "done reloading config_file=#{@config.config_file}"
      rescue Object => e
        logger.error "error reloading config_file=#{@config.config_file}: " \
                     "#{e.class} #{e.message}"
      end
    end

    # returns an array of string names for the given listener array
    def listener_names(listeners = @listeners)
      listeners.map { |io| sock_name(io) }
    end

    def build_app!
      @app = @app.call if @app.respond_to?(:arity) && @app.arity == 0
    end

  end
end
