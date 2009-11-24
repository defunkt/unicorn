# -*- encoding: binary -*-

require 'socket'
require 'logger'

module Unicorn

  # Implements a simple DSL for configuring a Unicorn server.
  #
  # See http://unicorn.bogomips.org/examples/unicorn.conf.rb for an
  # example config file.  An example config file for use with nginx is
  # also available at http://unicorn.bogomips.org/examples/nginx.conf
  class Configurator < Struct.new(:set, :config_file)

    # Default settings for Unicorn
    DEFAULTS = {
      :timeout => 60,
      :logger => Logger.new($stderr),
      :worker_processes => 1,
      :after_fork => lambda { |server, worker|
          server.logger.info("worker=#{worker.nr} spawned pid=#{$$}")
        },
      :before_fork => lambda { |server, worker|
          server.logger.info("worker=#{worker.nr} spawning...")
        },
      :before_exec => lambda { |server|
          server.logger.info("forked child re-executing...")
        },
      :pid => nil,
      :preload_app => false,
    }

    def initialize(defaults = {}) #:nodoc:
      self.set = Hash.new(:unset)
      use_defaults = defaults.delete(:use_defaults)
      self.config_file = defaults.delete(:config_file)
      set.merge!(DEFAULTS) if use_defaults
      defaults.each { |key, value| self.send(key, value) }
      Hash === set[:listener_opts] or
          set[:listener_opts] = Hash.new { |hash,key| hash[key] = {} }
      Array === set[:listeners] or set[:listeners] = []
      reload
    end

    def reload #:nodoc:
      instance_eval(File.read(config_file), config_file) if config_file

      # working_directory binds immediately (easier error checking that way),
      # now ensure any paths we changed are correctly set.
      [ :pid, :stderr_path, :stdout_path ].each do |var|
        String === (path = set[var]) or next
        path = File.expand_path(path)
        test(?w, path) || test(?w, File.dirname(path)) or \
              raise ArgumentError, "directory for #{var}=#{path} not writable"
      end
    end

    def commit!(server, options = {}) #:nodoc:
      skip = options[:skip] || []
      set.each do |key, value|
        value == :unset and next
        skip.include?(key) and next
        server.__send__("#{key}=", value)
      end
    end

    def [](key) # :nodoc:
      set[key]
    end

    # sets object to the +new+ Logger-like object.  The new logger-like
    # object must respond to the following methods:
    #  +debug+, +info+, +warn+, +error+, +fatal+, +close+
    def logger(new)
      %w(debug info warn error fatal close).each do |m|
        new.respond_to?(m) and next
        raise ArgumentError, "logger=#{new} does not respond to method=#{m}"
      end

      set[:logger] = new
    end

    # sets after_fork hook to a given block.  This block will be called by
    # the worker after forking.  The following is an example hook which adds
    # a per-process listener to every worker:
    #
    #  after_fork do |server,worker|
    #    # per-process listener ports for debugging/admin:
    #    addr = "127.0.0.1:#{9293 + worker.nr}"
    #
    #    # the negative :tries parameter indicates we will retry forever
    #    # waiting on the existing process to exit with a 5 second :delay
    #    # Existing options for Unicorn::Configurator#listen such as
    #    # :backlog, :rcvbuf, :sndbuf are available here as well.
    #    server.listen(addr, :tries => -1, :delay => 5, :backlog => 128)
    #
    #    # drop permissions to "www-data" in the worker
    #    # generally there's no reason to start Unicorn as a priviledged user
    #    # as it is not recommended to expose Unicorn to public clients.
    #    worker.user('www-data', 'www-data') if Process.euid == 0
    #  end
    def after_fork(*args, &block)
      set_hook(:after_fork, block_given? ? block : args[0])
    end

    # sets before_fork got be a given Proc object.  This Proc
    # object will be called by the master process before forking
    # each worker.
    def before_fork(*args, &block)
      set_hook(:before_fork, block_given? ? block : args[0])
    end

    # sets the before_exec hook to a given Proc object.  This
    # Proc object will be called by the master process right
    # before exec()-ing the new unicorn binary.  This is useful
    # for freeing certain OS resources that you do NOT wish to
    # share with the reexeced child process.
    # There is no corresponding after_exec hook (for obvious reasons).
    def before_exec(*args, &block)
      set_hook(:before_exec, block_given? ? block : args[0], 1)
    end

    # sets the timeout of worker processes to +seconds+.  Workers
    # handling the request/app.call/response cycle taking longer than
    # this time period will be forcibly killed (via SIGKILL).  This
    # timeout is enforced by the master process itself and not subject
    # to the scheduling limitations by the worker process.  Due the
    # low-complexity, low-overhead implementation, timeouts of less
    # than 3.0 seconds can be considered inaccurate and unsafe.
    #
    # For running Unicorn behind nginx, it is recommended to set
    # "fail_timeout=0" for in your nginx configuration like this
    # to have nginx always retry backends that may have had workers
    # SIGKILL-ed due to timeouts.
    #
    #    # See http://wiki.nginx.org/NginxHttpUpstreamModule for more details
    #    # on nginx upstream configuration:
    #    upstream unicorn_backend {
    #      # for UNIX domain socket setups:
    #      server unix:/path/to/unicorn.sock fail_timeout=0;
    #
    #      # for TCP setups
    #      server 192.168.0.7:8080 fail_timeout=0;
    #      server 192.168.0.8:8080 fail_timeout=0;
    #      server 192.168.0.9:8080 fail_timeout=0;
    #    }
    def timeout(seconds)
      Numeric === seconds or raise ArgumentError,
                                  "not numeric: timeout=#{seconds.inspect}"
      seconds >= 3 or raise ArgumentError,
                                  "too low: timeout=#{seconds.inspect}"
      set[:timeout] = seconds
    end

    # sets the current number of worker_processes to +nr+.  Each worker
    # process will serve exactly one client at a time.  You can
    # increment or decrement this value at runtime by sending SIGTTIN
    # or SIGTTOU respectively to the master process without reloading
    # the rest of your Unicorn configuration.  See the SIGNALS document
    # for more information.
    def worker_processes(nr)
      Integer === nr or raise ArgumentError,
                             "not an integer: worker_processes=#{nr.inspect}"
      nr >= 0 or raise ArgumentError,
                             "not non-negative: worker_processes=#{nr.inspect}"
      set[:worker_processes] = nr
    end

    # sets listeners to the given +addresses+, replacing or augmenting the
    # current set.  This is for the global listener pool shared by all
    # worker processes.  For per-worker listeners, see the after_fork example
    # This is for internal API use only, do not use it in your Unicorn
    # config file.  Use listen instead.
    def listeners(addresses) # :nodoc:
      Array === addresses or addresses = Array(addresses)
      addresses.map! { |addr| expand_addr(addr) }
      set[:listeners] = addresses
    end

    # adds an +address+ to the existing listener set.
    #
    # The following options may be specified (but are generally not needed):
    #
    # +:backlog+: this is the backlog of the listen() syscall.
    #
    # Some operating systems allow negative values here to specify the
    # maximum allowable value.  In most cases, this number is only
    # recommendation and there are other OS-specific tunables and
    # variables that can affect this number.  See the listen(2)
    # syscall documentation of your OS for the exact semantics of
    # this.
    #
    # If you are running unicorn on multiple machines, lowering this number
    # can help your load balancer detect when a machine is overloaded
    # and give requests to a different machine.
    #
    # Default: 1024
    #
    # +:rcvbuf+, +:sndbuf+: maximum receive and send buffer sizes of sockets
    #
    # These correspond to the SO_RCVBUF and SO_SNDBUF settings which
    # can be set via the setsockopt(2) syscall.  Some kernels
    # (e.g. Linux 2.4+) have intelligent auto-tuning mechanisms and
    # there is no need (and it is sometimes detrimental) to specify them.
    #
    # See the socket API documentation of your operating system
    # to determine the exact semantics of these settings and
    # other operating system-specific knobs where they can be
    # specified.
    #
    # Defaults: operating system defaults
    #
    # +:tcp_nodelay+: disables Nagle's algorithm on TCP sockets
    #
    # This has no effect on UNIX sockets.
    #
    # Default: operating system defaults (usually Nagle's algorithm enabled)
    #
    # +:tcp_nopush+: enables TCP_CORK in Linux or TCP_NOPUSH in FreeBSD
    #
    # This will prevent partial TCP frames from being sent out.
    # Enabling +tcp_nopush+ is generally not needed or recommended as
    # controlling +tcp_nodelay+ already provides sufficient latency
    # reduction whereas Unicorn does not know when the best times are
    # for flushing corked sockets.
    #
    # This has no effect on UNIX sockets.
    #
    # +:tries+: times to retry binding a socket if it is already in use
    #
    # A negative number indicates we will retry indefinitely, this is
    # useful for migrations and upgrades when individual workers
    # are binding to different ports.
    #
    # Default: 5
    #
    # +:delay+: seconds to wait between successive +tries+
    #
    # Default: 0.5 seconds
    #
    # +:umask+: sets the file mode creation mask for UNIX sockets
    #
    # Typically UNIX domain sockets are created with more liberal
    # file permissions than the rest of the application.  By default,
    # we create UNIX domain sockets to be readable and writable by
    # all local users to give them the same accessibility as
    # locally-bound TCP listeners.
    #
    # This has no effect on TCP listeners.
    #
    # Default: 0 (world read/writable)
    def listen(address, opt = {})
      address = expand_addr(address)
      if String === address
        [ :umask, :backlog, :sndbuf, :rcvbuf, :tries ].each do |key|
          value = opt[key] or next
          Integer === value or
            raise ArgumentError, "not an integer: #{key}=#{value.inspect}"
        end
        [ :tcp_nodelay, :tcp_nopush ].each do |key|
          (value = opt[key]).nil? and next
          TrueClass === value || FalseClass === value or
            raise ArgumentError, "not boolean: #{key}=#{value.inspect}"
        end
        unless (value = opt[:delay]).nil?
          Numeric === value or
            raise ArgumentError, "not numeric: delay=#{value.inspect}"
        end
        set[:listener_opts][address].merge!(opt)
      end

      set[:listeners] << address
    end

    # sets the +path+ for the PID file of the unicorn master process
    def pid(path); set_path(:pid, path); end

    # Enabling this preloads an application before forking worker
    # processes.  This allows memory savings when using a
    # copy-on-write-friendly GC but can cause bad things to happen when
    # resources like sockets are opened at load time by the master
    # process and shared by multiple children.  People enabling this are
    # highly encouraged to look at the before_fork/after_fork hooks to
    # properly close/reopen sockets.  Files opened for logging do not
    # have to be reopened as (unbuffered-in-userspace) files opened with
    # the File::APPEND flag are written to atomically on UNIX.
    #
    # In addition to reloading the unicorn-specific config settings,
    # SIGHUP will reload application code in the working
    # directory/symlink when workers are gracefully restarted.
    def preload_app(bool)
      case bool
      when TrueClass, FalseClass
        set[:preload_app] = bool
      else
        raise ArgumentError, "preload_app=#{bool.inspect} not a boolean"
      end
    end

    # Allow redirecting $stderr to a given path.  Unlike doing this from
    # the shell, this allows the unicorn process to know the path its
    # writing to and rotate the file if it is used for logging.  The
    # file will be opened with the File::APPEND flag and writes
    # synchronized to the kernel (but not necessarily to _disk_) so
    # multiple processes can safely append to it.
    def stderr_path(path)
      set_path(:stderr_path, path)
    end

    # Same as stderr_path, except for $stdout
    def stdout_path(path)
      set_path(:stdout_path, path)
    end

    # sets the working directory for Unicorn.  This ensures USR2 will
    # start a new instance of Unicorn in this directory.  This may be
    # a symlink.
    def working_directory(path)
      # just let chdir raise errors
      path = File.expand_path(path)
      if config_file &&
         config_file[0] != ?/ &&
         ! test(?r, "#{path}/#{config_file}")
        raise ArgumentError,
              "config_file=#{config_file} would not be accessible in" \
              " working_directory=#{path}"
      end
      Dir.chdir(path)
      HttpServer::START_CTX[:cwd] = ENV["PWD"] = path
    end

    # expands "unix:path/to/foo" to a socket relative to the current path
    # expands pathnames of sockets if relative to "~" or "~username"
    # expands "*:port and ":port" to "0.0.0.0:port"
    def expand_addr(address) #:nodoc
      return "0.0.0.0:#{address}" if Integer === address
      return address unless String === address

      case address
      when %r{\Aunix:(.*)\z}
        File.expand_path($1)
      when %r{\A~}
        File.expand_path(address)
      when %r{\A(?:\*:)?(\d+)\z}
        "0.0.0.0:#$1"
      when %r{\A(.*):(\d+)\z}
        # canonicalize the name
        packed = Socket.pack_sockaddr_in($2.to_i, $1)
        Socket.unpack_sockaddr_in(packed).reverse!.join(':')
      else
        address
      end
    end

  private

    def set_path(var, path) #:nodoc:
      case path
      when NilClass, String
        set[var] = path
      else
        raise ArgumentError
      end
    end

    def set_hook(var, my_proc, req_arity = 2) #:nodoc:
      case my_proc
      when Proc
        arity = my_proc.arity
        (arity == req_arity) or \
          raise ArgumentError,
                "#{var}=#{my_proc.inspect} has invalid arity: " \
                "#{arity} (need #{req_arity})"
      when NilClass
        my_proc = DEFAULTS[var]
      else
        raise ArgumentError, "invalid type: #{var}=#{my_proc.inspect}"
      end
      set[var] = my_proc
    end

  end
end
