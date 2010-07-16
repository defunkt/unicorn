# -*- encoding: binary -*-

require 'fcntl'
require 'etc'
require 'stringio'
require 'rack'
require 'unicorn/socket_helper'
require 'unicorn/const'
require 'unicorn/http_request'
require 'unicorn/configurator'
require 'unicorn/util'
require 'unicorn/tee_input'
require 'unicorn/http_response'

# Unicorn module containing all of the classes (include C extensions) for running
# a Unicorn web server.  It contains a minimalist HTTP server with just enough
# functionality to service web application requests fast as possible.
module Unicorn

  # raised inside TeeInput when a client closes the socket inside the
  # application dispatch.  This is always raised with an empty backtrace
  # since there is nothing in the application stack that is responsible
  # for client shutdowns/disconnects.
  class ClientShutdown < EOFError
  end

  class << self
    def run(app, options = {})
      HttpServer.new(app, options).start.join
    end

    # This returns a lambda to pass in as the app, this does not "build" the
    # app (which we defer based on the outcome of "preload_app" in the
    # Unicorn config).  The returned lambda will be called when it is
    # time to build the app.
    def builder(ru, opts)
      # allow Configurator to parse cli switches embedded in the ru file
      Unicorn::Configurator::RACKUP.update(:file => ru, :optparse => opts)

      # always called after config file parsing, may be called after forking
      lambda do ||
        inner_app = case ru
        when /\.ru$/
          raw = File.read(ru)
          raw.sub!(/^__END__\n.*/, '')
          eval("Rack::Builder.new {(#{raw}\n)}.to_app", TOPLEVEL_BINDING, ru)
        else
          require ru
          Object.const_get(File.basename(ru, '.rb').capitalize)
        end

        pp({ :inner_app => inner_app }) if $DEBUG

        # return value, matches rackup defaults based on env
        case ENV["RACK_ENV"]
        when "development"
          Rack::Builder.new do
            use Rack::CommonLogger, $stderr
            use Rack::ShowExceptions
            use Rack::Lint
            run inner_app
          end.to_app
        when "deployment"
          Rack::Builder.new do
            use Rack::CommonLogger, $stderr
            run inner_app
          end.to_app
        else
          inner_app
        end
      end
    end

    # returns an array of strings representing TCP listen socket addresses
    # and Unix domain socket paths.  This is useful for use with
    # Raindrops::Middleware under Linux: http://raindrops.bogomips.org/
    def listener_names
      HttpServer::LISTENERS.map { |io| SocketHelper.sock_name(io) }
    end
  end

  # This is the process manager of Unicorn. This manages worker
  # processes which in turn handle the I/O and application process.
  # Listener sockets are started in the master process and shared with
  # forked worker children.

  class HttpServer < Struct.new(:app, :timeout, :worker_processes,
                                :before_fork, :after_fork, :before_exec,
                                :logger, :pid, :listener_opts, :preload_app,
                                :reexec_pid, :orig_app, :init_listeners,
                                :master_pid, :config, :ready_pipe, :user)
    include ::Unicorn::SocketHelper

    # prevents IO objects in here from being GC-ed
    IO_PURGATORY = []

    # all bound listener sockets
    LISTENERS = []

    # This hash maps PIDs to Workers
    WORKERS = {}

    # We use SELF_PIPE differently in the master and worker processes:
    #
    # * The master process never closes or reinitializes this once
    # initialized.  Signal handlers in the master process will write to
    # it to wake up the master from IO.select in exactly the same manner
    # djb describes in http://cr.yp.to/docs/selfpipe.html
    #
    # * The workers immediately close the pipe they inherit from the
    # master and replace it with a new pipe after forking.  This new
    # pipe is also used to wakeup from IO.select from inside (worker)
    # signal handlers.  However, workers *close* the pipe descriptors in
    # the signal handlers to raise EBADF in IO.select instead of writing
    # like we do in the master.  We cannot easily use the reader set for
    # IO.select because LISTENERS is already that set, and it's extra
    # work (and cycles) to distinguish the pipe FD from the reader set
    # once IO.select returns.  So we're lazy and just close the pipe when
    # a (rare) signal arrives in the worker and reinitialize the pipe later.
    SELF_PIPE = []

    # signal queue used for self-piping
    SIG_QUEUE = []

    # constant lookups are faster and we're single-threaded/non-reentrant
    REQUEST = HttpRequest.new

    # We populate this at startup so we can figure out how to reexecute
    # and upgrade the currently running instance of Unicorn
    # This Hash is considered a stable interface and changing its contents
    # will allow you to switch between different installations of Unicorn
    # or even different installations of the same applications without
    # downtime.  Keys of this constant Hash are described as follows:
    #
    # * 0 - the path to the unicorn/unicorn_rails executable
    # * :argv - a deep copy of the ARGV array the executable originally saw
    # * :cwd - the working directory of the application, this is where
    # you originally started Unicorn.
    #
    # To change your unicorn executable to a different path without downtime,
    # you can set the following in your Unicorn config file, HUP and then
    # continue with the traditional USR2 + QUIT upgrade steps:
    #
    #   Unicorn::HttpServer::START_CTX[0] = "/home/bofh/1.9.2/bin/unicorn"
    START_CTX = {
      :argv => ARGV.map { |arg| arg.dup },
      :cwd => lambda {
          # favor ENV['PWD'] since it is (usually) symlink aware for
          # Capistrano and like systems
          begin
            a = File.stat(pwd = ENV['PWD'])
            b = File.stat(Dir.pwd)
            a.ino == b.ino && a.dev == b.dev ? pwd : Dir.pwd
          rescue
            Dir.pwd
          end
        }.call,
      0 => $0.dup,
    }

    # This class and its members can be considered a stable interface
    # and will not change in a backwards-incompatible fashion between
    # releases of Unicorn.  You may need to access it in the
    # before_fork/after_fork hooks.  See the Unicorn::Configurator RDoc
    # for examples.
    class Worker < Struct.new(:nr, :tmp, :switched)

      # worker objects may be compared to just plain numbers
      def ==(other_nr)
        self.nr == other_nr
      end

      # Changes the worker process to the specified +user+ and +group+
      # This is only intended to be called from within the worker
      # process from the +after_fork+ hook.  This should be called in
      # the +after_fork+ hook after any priviledged functions need to be
      # run (e.g. to set per-worker CPU affinity, niceness, etc)
      #
      # Any and all errors raised within this method will be propagated
      # directly back to the caller (usually the +after_fork+ hook.
      # These errors commonly include ArgumentError for specifying an
      # invalid user/group and Errno::EPERM for insufficient priviledges
      def user(user, group = nil)
        # we do not protect the caller, checking Process.euid == 0 is
        # insufficient because modern systems have fine-grained
        # capabilities.  Let the caller handle any and all errors.
        uid = Etc.getpwnam(user).uid
        gid = Etc.getgrnam(group).gid if group
        Unicorn::Util.chown_logs(uid, gid)
        tmp.chown(uid, gid)
        if gid && Process.egid != gid
          Process.initgroups(user, gid)
          Process::GID.change_privilege(gid)
        end
        Process.euid != uid and Process::UID.change_privilege(uid)
        self.switched = true
      end

    end

    # Creates a working server on host:port (strange things happen if
    # port isn't a Number).  Use HttpServer::run to start the server and
    # HttpServer.run.join to join the thread that's processing
    # incoming requests on the socket.
    def initialize(app, options = {})
      self.app = app
      self.reexec_pid = 0
      self.ready_pipe = options.delete(:ready_pipe)
      self.init_listeners = options[:listeners] ? options[:listeners].dup : []
      self.config = Configurator.new(options.merge(:use_defaults => true))
      self.listener_opts = {}

      # we try inheriting listeners first, so we bind them later.
      # we don't write the pid file until we've bound listeners in case
      # unicorn was started twice by mistake.  Even though our #pid= method
      # checks for stale/existing pid files, race conditions are still
      # possible (and difficult/non-portable to avoid) and can be likely
      # to clobber the pid if the second start was in quick succession
      # after the first, so we rely on the listener binding to fail in
      # that case.  Some tests (in and outside of this source tree) and
      # monitoring tools may also rely on pid files existing before we
      # attempt to connect to the listener(s)
      config.commit!(self, :skip => [:listeners, :pid])
      self.orig_app = app
    end

    # Runs the thing.  Returns self so you can run join on it
    def start
      BasicSocket.do_not_reverse_lookup = true

      # inherit sockets from parents, they need to be plain Socket objects
      # before they become UNIXServer or TCPServer
      inherited = ENV['UNICORN_FD'].to_s.split(/,/).map do |fd|
        io = Socket.for_fd(fd.to_i)
        set_server_sockopt(io, listener_opts[sock_name(io)])
        IO_PURGATORY << io
        logger.info "inherited addr=#{sock_name(io)} fd=#{fd}"
        server_cast(io)
      end

      config_listeners = config[:listeners].dup
      LISTENERS.replace(inherited)

      # we start out with generic Socket objects that get cast to either
      # TCPServer or UNIXServer objects; but since the Socket objects
      # share the same OS-level file descriptor as the higher-level *Server
      # objects; we need to prevent Socket objects from being garbage-collected
      config_listeners -= listener_names
      if config_listeners.empty? && LISTENERS.empty?
        config_listeners << Unicorn::Const::DEFAULT_LISTEN
        init_listeners << Unicorn::Const::DEFAULT_LISTEN
        START_CTX[:argv] << "-l#{Unicorn::Const::DEFAULT_LISTEN}"
      end
      config_listeners.each { |addr| listen(addr) }
      raise ArgumentError, "no listeners" if LISTENERS.empty?

      # this pipe is used to wake us up from select(2) in #join when signals
      # are trapped.  See trap_deferred.
      init_self_pipe!

      # setup signal handlers before writing pid file in case people get
      # trigger happy and send signals as soon as the pid file exists.
      # Note that signals don't actually get handled until the #join method
      QUEUE_SIGS.each { |sig| trap_deferred(sig) }
      trap(:CHLD) { |_| awaken_master }
      self.pid = config[:pid]

      self.master_pid = $$
      build_app! if preload_app
      maintain_worker_count
      self
    end

    # replaces current listener set with +listeners+.  This will
    # close the socket if it will not exist in the new listener set
    def listeners=(listeners)
      cur_names, dead_names = [], []
      listener_names.each do |name|
        if ?/ == name[0]
          # mark unlinked sockets as dead so we can rebind them
          (File.socket?(name) ? cur_names : dead_names) << name
        else
          cur_names << name
        end
      end
      set_names = listener_names(listeners)
      dead_names.concat(cur_names - set_names).uniq!

      LISTENERS.delete_if do |io|
        if dead_names.include?(sock_name(io))
          IO_PURGATORY.delete_if do |pio|
            pio.fileno == io.fileno && (pio.close rescue nil).nil? # true
          end
          (io.close rescue nil).nil? # true
        else
          set_server_sockopt(io, listener_opts[sock_name(io)])
          false
        end
      end

      (set_names - cur_names).each { |addr| listen(addr) }
    end

    def stdout_path=(path); redirect_io($stdout, path); end
    def stderr_path=(path); redirect_io($stderr, path); end

    def logger=(obj)
      HttpRequest::DEFAULTS["rack.logger"] = super
    end

    # sets the path for the PID file of the master process
    def pid=(path)
      if path
        if x = valid_pid?(path)
          return path if pid && path == pid && x == $$
          if x == reexec_pid && pid =~ /\.oldbin\z/
            logger.warn("will not set pid=#{path} while reexec-ed "\
                        "child is running PID:#{x}")
            return
          end
          raise ArgumentError, "Already running on PID:#{x} " \
                               "(or pid=#{path} is stale)"
        end
      end
      unlink_pid_safe(pid) if pid

      if path
        fp = begin
          tmp = "#{File.dirname(path)}/#{rand}.#$$"
          File.open(tmp, File::RDWR|File::CREAT|File::EXCL, 0644)
        rescue Errno::EEXIST
          retry
        end
        fp.syswrite("#$$\n")
        File.rename(fp.path, path)
        fp.close
      end
      super(path)
    end

    # add a given address to the +listeners+ set, idempotently
    # Allows workers to add a private, per-process listener via the
    # after_fork hook.  Very useful for debugging and testing.
    # +:tries+ may be specified as an option for the number of times
    # to retry, and +:delay+ may be specified as the time in seconds
    # to delay between retries.
    # A negative value for +:tries+ indicates the listen will be
    # retried indefinitely, this is useful when workers belonging to
    # different masters are spawned during a transparent upgrade.
    def listen(address, opt = {}.merge(listener_opts[address] || {}))
      address = config.expand_addr(address)
      return if String === address && listener_names.include?(address)

      delay = opt[:delay] || 0.5
      tries = opt[:tries] || 5
      begin
        io = bind_listen(address, opt)
        unless TCPServer === io || UNIXServer === io
          IO_PURGATORY << io
          io = server_cast(io)
        end
        logger.info "listening on addr=#{sock_name(io)} fd=#{io.fileno}"
        LISTENERS << io
        io
      rescue Errno::EADDRINUSE => err
        logger.error "adding listener failed addr=#{address} (in use)"
        raise err if tries == 0
        tries -= 1
        logger.error "retrying in #{delay} seconds " \
                     "(#{tries < 0 ? 'infinite' : tries} tries left)"
        sleep(delay)
        retry
      rescue => err
        logger.fatal "error adding listener addr=#{address}"
        raise err
      end
    end

    # monitors children and receives signals forever
    # (or until a termination signal is sent).  This handles signals
    # one-at-a-time time and we'll happily drop signals in case somebody
    # is signalling us too often.
    def join
      respawn = true
      last_check = Time.now

      proc_name 'master'
      logger.info "master process ready" # test_exec.rb relies on this message
      if ready_pipe
        ready_pipe.syswrite($$.to_s)
        ready_pipe.close rescue nil
        self.ready_pipe = nil
      end
      begin
        loop do
          reap_all_workers
          case SIG_QUEUE.shift
          when nil
            # avoid murdering workers after our master process (or the
            # machine) comes out of suspend/hibernation
            if (last_check + timeout) >= (last_check = Time.now)
              murder_lazy_workers
            else
              # wait for workers to wakeup on suspend
              master_sleep(timeout/2.0 + 1)
            end
            maintain_worker_count if respawn
            master_sleep(1)
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
              self.worker_processes = 0
            else
              logger.info "SIGWINCH ignored because we're not daemonized"
            end
          when :TTIN
            respawn = true
            self.worker_processes += 1
          when :TTOU
            self.worker_processes -= 1 if self.worker_processes > 0
          when :HUP
            respawn = true
            if config.config_file
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
      rescue => e
        logger.error "Unhandled master loop exception #{e.inspect}."
        logger.error e.backtrace.join("\n")
        retry
      end
      stop # gracefully shutdown all workers on our way out
      logger.info "master complete"
      unlink_pid_safe(pid) if pid
    end

    # Terminates all workers, but does not exit master process
    def stop(graceful = true)
      self.listeners = []
      limit = Time.now + timeout
      until WORKERS.empty? || Time.now > limit
        kill_each_worker(graceful ? :QUIT : :TERM)
        sleep(0.1)
        reap_all_workers
      end
      kill_each_worker(:KILL)
    end

    private

    # list of signals we care about and trap in master.
    QUEUE_SIGS = [ :WINCH, :QUIT, :INT, :TERM, :USR1, :USR2, :HUP,
                   :TTIN, :TTOU ]

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
    def master_sleep(sec)
      begin
        IO.select([ SELF_PIPE[0] ], nil, nil, sec) or return
        SELF_PIPE[0].read_nonblock(Const::CHUNK_SIZE, HttpRequest::BUF)
      rescue Errno::EAGAIN, Errno::EINTR
        break
      end while true
    end

    def awaken_master
      begin
        SELF_PIPE[1].write_nonblock('.') # wakeup master process from select
      rescue Errno::EAGAIN, Errno::EINTR
        # pipe is full, master should wake up anyways
        retry
      end
    end

    # reaps all unreaped workers
    def reap_all_workers
      begin
        loop do
          wpid, status = Process.waitpid2(-1, Process::WNOHANG)
          wpid or break
          if reexec_pid == wpid
            logger.error "reaped #{status.inspect} exec()-ed"
            self.reexec_pid = 0
            self.pid = pid.chomp('.oldbin') if pid
            proc_name 'master'
          else
            worker = WORKERS.delete(wpid) and worker.tmp.close rescue nil
            logger.info "reaped #{status.inspect} " \
                        "worker=#{worker.nr rescue 'unknown'}"
          end
        end
      rescue Errno::ECHILD
      end
    end

    # reexecutes the START_CTX with a new binary
    def reexec
      if reexec_pid > 0
        begin
          Process.kill(0, reexec_pid)
          logger.error "reexec-ed child already running PID:#{reexec_pid}"
          return
        rescue Errno::ESRCH
          self.reexec_pid = 0
        end
      end

      if pid
        old_pid = "#{pid}.oldbin"
        prev_pid = pid.dup
        begin
          self.pid = old_pid  # clear the path for a new pid file
        rescue ArgumentError
          logger.error "old PID:#{valid_pid?(old_pid)} running with " \
                       "existing pid=#{old_pid}, refusing rexec"
          return
        rescue => e
          logger.error "error writing pid=#{old_pid} #{e.class} #{e.message}"
          return
        end
      end

      self.reexec_pid = fork do
        listener_fds = LISTENERS.map { |sock| sock.fileno }
        ENV['UNICORN_FD'] = listener_fds.join(',')
        Dir.chdir(START_CTX[:cwd])
        cmd = [ START_CTX[0] ].concat(START_CTX[:argv])

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
        before_exec.call(self)
        exec(*cmd)
      end
      proc_name 'master (old)'
    end

    # forcibly terminate all workers that haven't checked in in timeout
    # seconds.  The timeout is implemented using an unlinked File
    # shared between the parent process and each worker.  The worker
    # runs File#chmod to modify the ctime of the File.  If the ctime
    # is stale for >timeout seconds, then we'll kill the corresponding
    # worker.
    def murder_lazy_workers
      WORKERS.dup.each_pair do |wpid, worker|
        stat = worker.tmp.stat
        # skip workers that disable fchmod or have never fchmod-ed
        stat.mode == 0100600 and next
        (diff = (Time.now - stat.ctime)) <= timeout and next
        logger.error "worker=#{worker.nr} PID:#{wpid} timeout " \
                     "(#{diff}s > #{timeout}s), killing"
        kill_worker(:KILL, wpid) # take no prisoners for timeout violations
      end
    end

    def spawn_missing_workers
      (0...worker_processes).each do |worker_nr|
        WORKERS.values.include?(worker_nr) and next
        worker = Worker.new(worker_nr, Unicorn::Util.tmpio)
        before_fork.call(self, worker)
        WORKERS[fork {
          ready_pipe.close if ready_pipe
          self.ready_pipe = nil
          worker_loop(worker)
        }] = worker
      end
    end

    def maintain_worker_count
      (off = WORKERS.size - worker_processes) == 0 and return
      off < 0 and return spawn_missing_workers
      WORKERS.dup.each_pair { |wpid,w|
        w.nr >= worker_processes and kill_worker(:QUIT, wpid) rescue nil
      }
    end

    # if we get any error, try to write something back to the client
    # assuming we haven't closed the socket, but don't get hung up
    # if the socket is already closed or broken.  We'll always ensure
    # the socket is closed at the end of this function
    def handle_error(client, e)
      msg = case e
      when EOFError,Errno::ECONNRESET,Errno::EPIPE,Errno::EINVAL,Errno::EBADF
        Const::ERROR_500_RESPONSE
      when HttpParserError # try to tell the client they're bad
        Const::ERROR_400_RESPONSE
      else
        logger.error "Read error: #{e.inspect}"
        logger.error e.backtrace.join("\n")
        Const::ERROR_500_RESPONSE
      end
      client.write_nonblock(msg)
      client.close
      rescue
        nil
    end

    # once a client is accepted, it is processed in its entirety here
    # in 3 easy steps: read request, call app, write app response
    def process_client(client)
      client.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
      response = app.call(env = REQUEST.read(client))

      if 100 == response[0].to_i
        client.write(Const::EXPECT_100_RESPONSE)
        env.delete(Const::HTTP_EXPECT)
        response = app.call(env)
      end
      HttpResponse.write(client, response, HttpRequest::PARSER.headers?)
    rescue => e
      handle_error(client, e)
    end

    # gets rid of stuff the worker has no business keeping track of
    # to free some resources and drops all sig handlers.
    # traps for USR1, USR2, and HUP may be set in the after_fork Proc
    # by the user.
    def init_worker_process(worker)
      QUEUE_SIGS.each { |sig| trap(sig, nil) }
      trap(:CHLD, 'DEFAULT')
      SIG_QUEUE.clear
      proc_name "worker[#{worker.nr}]"
      START_CTX.clear
      init_self_pipe!
      WORKERS.values.each { |other| other.tmp.close rescue nil }
      WORKERS.clear
      LISTENERS.each { |sock| sock.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) }
      worker.tmp.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
      after_fork.call(self, worker) # can drop perms
      worker.user(*user) if user.kind_of?(Array) && ! worker.switched
      self.timeout /= 2.0 # halve it for select()
      build_app! unless preload_app
    end

    def reopen_worker_logs(worker_nr)
      logger.info "worker=#{worker_nr} reopening logs..."
      Unicorn::Util.reopen_logs
      logger.info "worker=#{worker_nr} done reopening logs"
      init_self_pipe!
    end

    # runs inside each forked worker, this sits around and waits
    # for connections and doesn't die until the parent dies (or is
    # given a INT, QUIT, or TERM signal)
    def worker_loop(worker)
      ppid = master_pid
      init_worker_process(worker)
      nr = 0 # this becomes negative if we need to reopen logs
      alive = worker.tmp # tmp is our lifeline to the master process
      ready = LISTENERS

      # closing anything we IO.select on will raise EBADF
      trap(:USR1) { nr = -65536; SELF_PIPE[0].close rescue nil }
      trap(:QUIT) { alive = nil; LISTENERS.each { |s| s.close rescue nil } }
      [:TERM, :INT].each { |sig| trap(sig) { exit!(0) } } # instant shutdown
      logger.info "worker=#{worker.nr} ready"
      m = 0

      begin
        nr < 0 and reopen_worker_logs(worker.nr)
        nr = 0

        # we're a goner in timeout seconds anyways if alive.chmod
        # breaks, so don't trap the exception.  Using fchmod() since
        # futimes() is not available in base Ruby and I very strongly
        # prefer temporary files to be unlinked for security,
        # performance and reliability reasons, so utime is out.  No-op
        # changes with chmod doesn't update ctime on all filesystems; so
        # we change our counter each and every time (after process_client
        # and before IO.select).
        alive.chmod(m = 0 == m ? 1 : 0)

        ready.each do |sock|
          begin
            process_client(sock.accept_nonblock)
            nr += 1
            alive.chmod(m = 0 == m ? 1 : 0)
          rescue Errno::EAGAIN, Errno::ECONNABORTED
          end
          break if nr < 0
        end

        # make the following bet: if we accepted clients this round,
        # we're probably reasonably busy, so avoid calling select()
        # and do a speculative accept_nonblock on ready listeners
        # before we sleep again in select().
        redo unless nr == 0 # (nr < 0) => reopen logs

        ppid == Process.ppid or return
        alive.chmod(m = 0 == m ? 1 : 0)
        begin
          # timeout used so we can detect parent death:
          ret = IO.select(LISTENERS, nil, SELF_PIPE, timeout) or redo
          ready = ret[0]
        rescue Errno::EINTR
          ready = LISTENERS
        rescue Errno::EBADF
          nr < 0 or return
        end
      rescue => e
        if alive
          logger.error "Unhandled listen loop exception #{e.inspect}."
          logger.error e.backtrace.join("\n")
        end
      end while alive
    end

    # delivers a signal to a worker and fails gracefully if the worker
    # is no longer running.
    def kill_worker(signal, wpid)
      begin
        Process.kill(signal, wpid)
      rescue Errno::ESRCH
        worker = WORKERS.delete(wpid) and worker.tmp.close rescue nil
      end
    end

    # delivers a signal to each worker
    def kill_each_worker(signal)
      WORKERS.keys.each { |wpid| kill_worker(signal, wpid) }
    end

    # unlinks a PID file at given +path+ if it contains the current PID
    # still potentially racy without locking the directory (which is
    # non-portable and may interact badly with other programs), but the
    # window for hitting the race condition is small
    def unlink_pid_safe(path)
      (File.read(path).to_i == $$ and File.unlink(path)) rescue nil
    end

    # returns a PID if a given path contains a non-stale PID file,
    # nil otherwise.
    def valid_pid?(path)
      wpid = File.read(path).to_i
      wpid <= 0 and return nil
      begin
        Process.kill(0, wpid)
        wpid
      rescue Errno::ESRCH
        # don't unlink stale pid files, racy without non-portable locking...
      end
      rescue Errno::ENOENT
    end

    def load_config!
      loaded_app = app
      begin
        logger.info "reloading config_file=#{config.config_file}"
        config[:listeners].replace(init_listeners)
        config.reload
        config.commit!(self)
        kill_each_worker(:QUIT)
        Unicorn::Util.reopen_logs
        self.app = orig_app
        build_app! if preload_app
        logger.info "done reloading config_file=#{config.config_file}"
      rescue StandardError, LoadError, SyntaxError => e
        logger.error "error reloading config_file=#{config.config_file}: " \
                     "#{e.class} #{e.message} #{e.backtrace}"
        self.app = loaded_app
      end
    end

    # returns an array of string names for the given listener array
    def listener_names(listeners = LISTENERS)
      listeners.map { |io| sock_name(io) }
    end

    def build_app!
      if app.respond_to?(:arity) && app.arity == 0
        if defined?(Gem) && Gem.respond_to?(:refresh)
          logger.info "Refreshing Gem list"
          Gem.refresh
        end
        self.app = app.call
      end
    end

    def proc_name(tag)
      $0 = ([ File.basename(START_CTX[0]), tag
            ]).concat(START_CTX[:argv]).join(' ')
    end

    def redirect_io(io, path)
      File.open(path, 'ab') { |fp| io.reopen(fp) } if path
      io.sync = true
    end

    def init_self_pipe!
      SELF_PIPE.each { |io| io.close rescue nil }
      SELF_PIPE.replace(IO.pipe)
      SELF_PIPE.each { |io| io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) }
    end

  end
end
