require 'fcntl'

require 'unicorn/socket_helper'
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
    include ::Unicorn::SocketHelper

    # prevents IO objects in here from being GC-ed
    IO_PURGATORY = []

    # all bound listener sockets
    LISTENERS = []

    # This hash maps PIDs to Workers
    WORKERS = {}

    # See: http://cr.yp.to/docs/selfpipe.html
    SELF_PIPE = []

    # signal queue used for self-piping
    SIG_QUEUE = []

    # We populate this at startup so we can figure out how to reexecute
    # and upgrade the currently running instance of Unicorn
    START_CTX = {
      :argv => ARGV.map { |arg| arg.dup },
      # don't rely on Dir.pwd here since it's not symlink-aware, and
      # symlink dirs are the default with Capistrano...
      :cwd => `/bin/sh -c pwd`.chomp("\n"),
      :zero => $0.dup,
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
    # HttpServer.run.join to join the thread that's processing
    # incoming requests on the socket.
    def initialize(app, options = {})
      @app = app
      @reexec_pid = 0
      @init_listeners = options[:listeners] ? options[:listeners].dup : []
      @config = Configurator.new(options.merge(:use_defaults => true))
      @listener_opts = {}
      @config.commit!(self, :skip => [:listeners, :pid])
      @request = HttpRequest.new(@logger)
    end

    # Runs the thing.  Returns self so you can run join on it
    def start
      BasicSocket.do_not_reverse_lookup = true

      # inherit sockets from parents, they need to be plain Socket objects
      # before they become UNIXServer or TCPServer
      inherited = ENV['UNICORN_FD'].to_s.split(/,/).map do |fd|
        io = Socket.for_fd(fd.to_i)
        set_server_sockopt(io, @listener_opts[sock_name(io)])
        IO_PURGATORY << io
        logger.info "inherited addr=#{sock_name(io)} fd=#{fd}"
        server_cast(io)
      end

      config_listeners = @config[:listeners].dup
      LISTENERS.replace(inherited)

      # we start out with generic Socket objects that get cast to either
      # TCPServer or UNIXServer objects; but since the Socket objects
      # share the same OS-level file descriptor as the higher-level *Server
      # objects; we need to prevent Socket objects from being garbage-collected
      config_listeners -= listener_names
      if config_listeners.empty? && LISTENERS.empty?
        config_listeners << Unicorn::Const::DEFAULT_LISTEN
      end
      config_listeners.each { |addr| listen(addr) }
      raise ArgumentError, "no listeners" if LISTENERS.empty?
      self.pid = @config[:pid]
      build_app! if @preload_app
      maintain_worker_count
      self
    end

    # replaces current listener set with +listeners+.  This will
    # close the socket if it will not exist in the new listener set
    def listeners=(listeners)
      cur_names, dead_names = [], []
      listener_names.each do |name|
        if "/" == name[0..0]
          # mark unlinked sockets as dead so we can rebind them
          (File.socket?(name) ? cur_names : dead_names) << name
        else
          cur_names << name
        end
      end
      set_names = listener_names(listeners)
      dead_names += cur_names - set_names
      dead_names.uniq!

      LISTENERS.delete_if do |io|
        if dead_names.include?(sock_name(io))
          IO_PURGATORY.delete_if do |pio|
            pio.fileno == io.fileno && (pio.close rescue nil).nil? # true
          end
          (io.close rescue nil).nil? # true
        else
          set_server_sockopt(io, @listener_opts[sock_name(io)])
          false
        end
      end

      (set_names - cur_names).each { |addr| listen(addr) }
    end

    def stdout_path=(path); redirect_io($stdout, path); end
    def stderr_path=(path); redirect_io($stderr, path); end

    # sets the path for the PID file of the master process
    def pid=(path)
      if path
        if x = valid_pid?(path)
          return path if @pid && path == @pid && x == $$
          raise ArgumentError, "Already running on PID:#{x} " \
                               "(or pid=#{path} is stale)"
        end
      end
      unlink_pid_safe(@pid) if @pid
      File.open(path, 'wb') { |fp| fp.syswrite("#$$\n") } if path
      @pid = path
    end

    # add a given address to the +listeners+ set, idempotently
    # Allows workers to add a private, per-process listener via the
    # @after_fork hook.  Very useful for debugging and testing.
    def listen(address, opt = {}.merge(@listener_opts[address] || {}))
      return if String === address && listener_names.include?(address)

      if io = bind_listen(address, opt)
        unless TCPServer === io || UNIXServer === io
          IO_PURGATORY << io
          io = server_cast(io)
        end
        logger.info "listening on addr=#{sock_name(io)} fd=#{io.fileno}"
        LISTENERS << io
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
      init_self_pipe!
      respawn = true

      QUEUE_SIGS.each { |sig| trap_deferred(sig) }
      trap(:CHLD) { |sig_nr| awaken_master }
      proc_name 'master'
      logger.info "master process ready" # test_exec.rb relies on this message
      begin
        loop do
          reap_all_workers
          case SIG_QUEUE.shift
          when nil
            murder_lazy_workers
            maintain_worker_count if respawn
            master_sleep
          when :QUIT # graceful shutdown
            break
          when :TERM, :INT # immediate shutdown
            stop(false)
            break
          when :USR1 # rotate logs
            logger.info "master reopening logs..."
            Unicorn::Util.reopen_logs
            logger.info "master done reopening logs"
            kill_each_worker(:USR1)
          when :USR2 # exec binary, stay alive in case something went wrong
            reexec
          when :WINCH
            if Process.ppid == 1 || Process.getpgrp != $$
              respawn = false
              logger.info "gracefully stopping all workers"
              kill_each_worker(:QUIT)
            else
              logger.info "SIGWINCH ignored because we're not daemonized"
            end
          when :TTIN
            @worker_processes += 1
          when :TTOU
            @worker_processes -= 1 if @worker_processes > 0
          when :HUP
            respawn = true
            if @config.config_file
              load_config!
              redo # immediate reaping since we may have QUIT workers
            else # exec binary and exit if there's no config file
              logger.info "config_file not present, reexecuting binary"
              reexec
              break
            end
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
      logger.info "master complete"
      unlink_pid_safe(@pid) if @pid
    end

    # Terminates all workers, but does not exit master process
    def stop(graceful = true)
      kill_each_worker(graceful ? :QUIT : :TERM)
      timeleft = @timeout
      step = 0.2
      reap_all_workers
      until WORKERS.empty?
        sleep(step)
        reap_all_workers
        (timeleft -= step) > 0 and next
        kill_each_worker(:KILL)
      end
    ensure
      self.listeners = []
    end

    private

    # list of signals we care about and trap in master.
    QUEUE_SIGS = [ :WINCH, :QUIT, :INT, :TERM, :USR1, :USR2, :HUP,
                   :TTIN, :TTOU ].freeze

    # defer a signal for later processing in #join (master process)
    def trap_deferred(signal)
      trap(signal) do |sig_nr|
        if SIG_QUEUE.size < 5
          SIG_QUEUE << signal
          awaken_master
        else
          logger.error "ignoring SIG#{signal}, queue=#{SIG_QUEUE.inspect}"
        end
      end
    end

    # wait for a signal hander to wake us up and then consume the pipe
    # Wake up every second anyways to run murder_lazy_workers
    def master_sleep
      begin
        ready = IO.select([SELF_PIPE.first], nil, nil, 1) or return
        ready.first && ready.first.first or return
        loop { SELF_PIPE.first.read_nonblock(Const::CHUNK_SIZE) }
      rescue Errno::EAGAIN, Errno::EINTR
      end
    end

    def awaken_master
      begin
        SELF_PIPE.last.write_nonblock('.') # wakeup master process from select
      rescue Errno::EAGAIN, Errno::EINTR
        # pipe is full, master should wake up anyways
        retry
      end
    end

    # reaps all unreaped workers
    def reap_all_workers
      begin
        loop do
          pid, status = Process.waitpid2(-1, Process::WNOHANG)
          pid or break
          if @reexec_pid == pid
            logger.error "reaped #{status.inspect} exec()-ed"
            @reexec_pid = 0
            self.pid = @pid.chomp('.oldbin') if @pid
            proc_name 'master'
          else
            worker = WORKERS.delete(pid)
            worker.tempfile.close rescue nil
            logger.info "reaped #{status.inspect} " \
                        "worker=#{worker.nr rescue 'unknown'}"
          end
        end
      rescue Errno::ECHILD
      end
    end

    # reexecutes the START_CTX with a new binary
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
        listener_fds = LISTENERS.map { |sock| sock.fileno }
        ENV['UNICORN_FD'] = listener_fds.join(',')
        Dir.chdir(START_CTX[:cwd])
        cmd = [ START_CTX[:zero] ] + START_CTX[:argv]

        # avoid leaking FDs we don't know about, but let before_exec
        # unset FD_CLOEXEC, if anything else in the app eventually
        # relies on FD inheritence.
        (3..1024).each do |io|
          next if listener_fds.include?(io)
          io = IO.for_fd(io) rescue nil
          io or next
          IO_PURGATORY << io
          io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
        end
        logger.info "executing #{cmd.inspect} (in #{Dir.pwd})"
        @before_exec.call(self)
        exec(*cmd)
      end
      proc_name 'master (old)'
    end

    # forcibly terminate all workers that haven't checked in in @timeout
    # seconds.  The timeout is implemented using an unlinked tempfile
    # shared between the parent process and each worker.  The worker
    # runs File#chmod to modify the ctime of the tempfile.  If the ctime
    # is stale for >@timeout seconds, then we'll kill the corresponding
    # worker.
    def murder_lazy_workers
      WORKERS.each_pair do |pid, worker|
        Time.now - worker.tempfile.ctime <= @timeout and next
        logger.error "worker=#{worker.nr} PID:#{pid} is too old, killing"
        kill_worker(:KILL, pid) # take no prisoners for @timeout violations
        worker.tempfile.close rescue nil
      end
    end

    def spawn_missing_workers
      (0...@worker_processes).each do |worker_nr|
        WORKERS.values.include?(worker_nr) and next
        begin
          Dir.chdir(START_CTX[:cwd])
        rescue Errno::ENOENT => err
          logger.fatal "#{err.inspect} (#{START_CTX[:cwd]})"
          SIG_QUEUE << :QUIT # forcibly emulate SIGQUIT
          return
        end
        tempfile = Tempfile.new(nil) # as short as possible to save dir space
        tempfile.unlink # don't allow other processes to find or see it
        worker = Worker.new(worker_nr, tempfile)
        @before_fork.call(self, worker)
        pid = fork { worker_loop(worker) }
        WORKERS[pid] = worker
      end
    end

    def maintain_worker_count
      (off = WORKERS.size - @worker_processes) == 0 and return
      off < 0 and return spawn_missing_workers
      WORKERS.each_pair { |pid,w|
        w.nr >= @worker_processes and kill_worker(:QUIT, pid) rescue nil
      }
    end

    # once a client is accepted, it is processed in its entirety here
    # in 3 easy steps: read request, call app, write app response
    def process_client(client)
      # one syscall less than "client.nonblock = false":
      client.fcntl(Fcntl::F_SETFL, File::RDWR)
      HttpResponse.write(client, @app.call(@request.read(client)))
    # if we get any error, try to write something back to the client
    # assuming we haven't closed the socket, but don't get hung up
    # if the socket is already closed or broken.  We'll always ensure
    # the socket is closed at the end of this function
    rescue EOFError,Errno::ECONNRESET,Errno::EPIPE,Errno::EINVAL,Errno::EBADF
      client.write_nonblock(Const::ERROR_500_RESPONSE) rescue nil
    rescue HttpParserError # try to tell the client they're bad
      client.write_nonblock(Const::ERROR_400_RESPONSE) rescue nil
    rescue Object => e
      client.write_nonblock(Const::ERROR_500_RESPONSE) rescue nil
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
      QUEUE_SIGS.each { |sig| trap(sig, 'DEFAULT') }
      trap(:CHLD, 'DEFAULT')
      SIG_QUEUE.clear
      proc_name "worker[#{worker.nr}]"
      START_CTX.clear
      init_self_pipe!
      WORKERS.values.each { |other| other.tempfile.close! rescue nil }
      WORKERS.clear
      LISTENERS.each { |sock| sock.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) }
      worker.tempfile.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
      @after_fork.call(self, worker) # can drop perms
      @timeout /= 2.0 # halve it for select()
      build_app! unless @config[:preload_app]
    end

    def reopen_worker_logs(worker_nr)
      @logger.info "worker=#{worker_nr} reopening logs..."
      Unicorn::Util.reopen_logs
      @logger.info "worker=#{worker_nr} done reopening logs"
      init_self_pipe!
    end

    # runs inside each forked worker, this sits around and waits
    # for connections and doesn't die until the parent dies (or is
    # given a INT, QUIT, or TERM signal)
    def worker_loop(worker)
      master_pid = Process.ppid # slightly racy, but less memory usage
      init_worker_process(worker)
      nr = 0 # this becomes negative if we need to reopen logs
      alive = worker.tempfile # tempfile is our lifeline to the master process
      ready = LISTENERS
      client = nil

      # closing anything we IO.select on will raise EBADF
      trap(:USR1) { nr = -65536; SELF_PIPE.first.close rescue nil }
      trap(:QUIT) { alive = nil; LISTENERS.each { |s| s.close rescue nil } }
      [:TERM, :INT].each { |sig| trap(sig) { exit(0) } } # instant shutdown
      @logger.info "worker=#{worker.nr} ready"

      while alive
        reopen_worker_logs(worker.nr) if nr < 0
        # we're a goner in @timeout seconds anyways if alive.chmod
        # breaks, so don't trap the exception.  Using fchmod() since
        # futimes() is not available in base Ruby and I very strongly
        # prefer temporary files to be unlinked for security,
        # performance and reliability reasons, so utime is out.  No-op
        # changes with chmod doesn't update ctime on all filesystems; so
        # we change our counter each and every time (after process_client
        # and before IO.select).
        alive.chmod(nr = 0)

        begin
          ready.each do |sock|
            begin
              client = begin
                sock.accept_nonblock
              rescue Errno::EAGAIN
                next
              end
              process_client(client)
            rescue Errno::ECONNABORTED
              # client closed the socket even before accept
              client.close rescue nil
            ensure
              alive.chmod(nr += 1) if client
              break if nr < 0
            end
          end
          client = nil

          # make the following bet: if we accepted clients this round,
          # we're probably reasonably busy, so avoid calling select()
          # and do a speculative accept_nonblock on every listener
          # before we sleep again in select().
          if nr != 0 # (nr < 0) => reopen logs
            ready = LISTENERS
          else
            master_pid == Process.ppid or exit(0)
            alive.chmod(nr += 1)
            begin
              # timeout used so we can detect parent death:
              ret = IO.select(LISTENERS, nil, SELF_PIPE, @timeout) or next
              ready = ret.first
            rescue Errno::EINTR
              ready = LISTENERS
            rescue Errno::EBADF => e
              nr < 0 or exit(alive ? 1 : 0)
            end
          end
        rescue SignalException, SystemExit => e
          raise e
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
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        worker = WORKERS.delete(pid) and worker.tempfile.close rescue nil
      end
    end

    # delivers a signal to each worker
    def kill_each_worker(signal)
      WORKERS.keys.each { |pid| kill_worker(signal, pid) }
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
          Process.kill(0, pid)
          return pid
        rescue Errno::ESRCH
        end
      end
      nil
    end

    def load_config!
      begin
        logger.info "reloading config_file=#{@config.config_file}"
        @config[:listeners].replace(@init_listeners)
        @config.reload
        @config.commit!(self)
        kill_each_worker(:QUIT)
        logger.info "done reloading config_file=#{@config.config_file}"
      rescue Object => e
        logger.error "error reloading config_file=#{@config.config_file}: " \
                     "#{e.class} #{e.message}"
      end
    end

    # returns an array of string names for the given listener array
    def listener_names(listeners = LISTENERS)
      listeners.map { |io| sock_name(io) }
    end

    def build_app!
      @app = @app.call if @app.respond_to?(:arity) && @app.arity == 0
    end

    def proc_name(tag)
      $0 = ([ File.basename(START_CTX[:zero]), tag ] +
              START_CTX[:argv]).join(' ')
    end

    def redirect_io(io, path)
      File.open(path, 'a') { |fp| io.reopen(fp) } if path
      io.sync = true
    end

    def init_self_pipe!
      SELF_PIPE.each { |io| io.close rescue nil }
      SELF_PIPE.replace(IO.pipe)
      SELF_PIPE.each { |io| io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) }
    end

  end
end
