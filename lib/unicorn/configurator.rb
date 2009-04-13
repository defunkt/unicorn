require 'unicorn/socket'
require 'unicorn/const'
require 'logger'

module Unicorn

  # Implements a simple DSL for configuring a unicorn server.
  #
  # Example (when used with the unicorn config file):
  #   worker_processes 4
  #   listen '/tmp/my_app.sock', :backlog => 1
  #   listen '0.0.0.0:9292'
  #   timeout 10
  #   pid "/tmp/my_app.pid"
  #   after_fork do |server,worker|
  #     server.listen("127.0.0.1:#{9293 + worker.nr}") rescue nil
  #   end
  class Configurator
    # The default logger writes its output to $stderr
    DEFAULT_LOGGER = Logger.new($stderr) unless defined?(DEFAULT_LOGGER)

    # Default settings for Unicorn
    DEFAULTS = {
      :timeout => 60,
      :listeners => [],
      :logger => DEFAULT_LOGGER,
      :worker_processes => 1,
      :after_fork => lambda { |server, worker|
          server.logger.info("worker=#{worker.nr} spawned pid=#{$$}")

          # per-process listener ports for debugging/admin:
          # "rescue nil" statement is needed because USR2 will
          # cause the master process to reexecute itself and the
          # per-worker ports can be taken, necessitating another
          # HUP after QUIT-ing the original master:
          # server.listen("127.0.0.1:#{8081 + worker.nr}") rescue nil
        },
      :before_fork => lambda { |server, worker|
          server.logger.info("worker=#{worker.nr} spawning...")
        },
      :before_exec => lambda { |server|
          server.logger.info("forked child re-executing...")
        },
      :pid => nil,
      :preload_app => false,
      :stderr_path => nil,
      :stdout_path => nil,
    }

    attr_reader :config_file #:nodoc:

    def initialize(defaults = {}) #:nodoc:
      @set = Hash.new(:unset)
      use_defaults = defaults.delete(:use_defaults)
      @config_file = defaults.delete(:config_file)
      @config_file.freeze
      @set.merge!(DEFAULTS) if use_defaults
      defaults.each { |key, value| self.send(key, value) }
      reload
    end

    def reload #:nodoc:
      instance_eval(File.read(@config_file)) if @config_file
    end

    def commit!(server, options = {}) #:nodoc:
      skip = options[:skip] || []
      @set.each do |key, value|
        (Symbol === value && value == :unset) and next
        skip.include?(key) and next
        setter = "#{key}="
        if server.respond_to?(setter)
          server.send(setter, value)
        else
          server.instance_variable_set("@#{key}", value)
        end
      end
    end

    def [](key) # :nodoc:
      @set[key]
    end

    # sets object to the +new+ Logger-like object.  The new logger-like
    # object must respond to the following methods:
    #  +debug+, +info+, +warn+, +error+, +fatal+, +close+
    def logger(new)
      %w(debug info warn error fatal close).each do |m|
        new.respond_to?(m) and next
        raise ArgumentError, "logger=#{new} does not respond to method=#{m}"
      end

      @set[:logger] = new
    end

    # sets after_fork hook to a given block.  This block will be called by
    # the worker after forking.  The following is an example hook which adds
    # a per-process listener to every worker:
    #
    #  after_fork do |server,worker|
    #    # per-process listener ports for debugging/admin:
    #    # "rescue nil" statement is needed because USR2 will
    #    # cause the master process to reexecute itself and the
    #    # per-worker ports can be taken, necessitating another
    #    # HUP after QUIT-ing the original master:
    #    server.listen("127.0.0.1:#{9293 + worker.nr}") rescue nil
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
    # to the scheduling limitations by the worker process.
    def timeout(seconds)
      Numeric === seconds or raise ArgumentError,
                                  "not numeric: timeout=#{seconds.inspect}"
      seconds > 0 or raise ArgumentError,
                                  "not positive: timeout=#{seconds.inspect}"
      @set[:timeout] = seconds
    end

    # sets the current number of worker_processes to +nr+.  Each worker
    # process will serve exactly one client at a time.
    def worker_processes(nr)
      Integer === nr or raise ArgumentError,
                             "not an integer: worker_processes=#{nr.inspect}"
      nr >= 0 or raise ArgumentError,
                             "not non-negative: worker_processes=#{nr.inspect}"
      @set[:worker_processes] = nr
    end

    # sets listeners to the given +addresses+, replacing or augmenting the
    # current set.  This is for the global listener pool shared by all
    # worker processes.  For per-worker listeners, see the after_fork example
    # This is for internal API use only, do not use it in your Unicorn
    # config file.  Use listen instead.
    def listeners(addresses) # :nodoc:
      Array === addresses or addresses = Array(addresses)
      addresses.map! { |addr| expand_addr(addr) }
      @set[:listeners] = addresses
    end

    # adds an +address+ to the existing listener set.
    #
    # The following options may be specified (but are generally not needed):
    #
    # +backlog+: this is the backlog of the listen() syscall.
    #
    #   Some operating systems allow negative values here to specify the
    #   maximum allowable value.  In most cases, this number is only
    #   recommendation and there are other OS-specific tunables and
    #   variables that can affect this number.  See the listen(2)
    #   syscall documentation of your OS for the exact semantics of
    #   this.
    #
    #   If you are running unicorn on multiple machines, lowering this number
    #   can help your load balancer detect when a machine is overloaded
    #   and give requests to a different machine.
    #
    #   Default: 1024
    #
    # +rcvbuf+, +sndbuf+: maximum send and receive buffer sizes of sockets
    #
    #   These correspond to the SO_RCVBUF and SO_SNDBUF settings which
    #   can be set via the setsockopt(2) syscall.  Some kernels
    #   (e.g. Linux 2.4+) have intelligent auto-tuning mechanisms and
    #   there is no need (and it is sometimes detrimental) to specify them.
    #
    #   See the socket API documentation of your operating system
    #   to determine the exact semantics of these settings and
    #   other operating system-specific knobs where they can be
    #   specified.
    #
    #   Defaults: operating system defaults
    def listen(address, opt = { :backlog => 1024 })
      address = expand_addr(address)
      if String === address
        Hash === @set[:listener_opts] or
          @set[:listener_opts] = Hash.new { |hash,key| hash[key] = {} }
        [ :backlog, :sndbuf, :rcvbuf ].each do |key|
          value = opt[key] or next
          Integer === value or
            raise ArgumentError, "not an integer: #{key}=#{value.inspect}"
        end
        @set[:listener_opts][address].merge!(opt)
      end

      @set[:listeners] = [] unless Array === @set[:listeners]
      @set[:listeners] << address
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
        @set[:preload_app] = bool
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

    private

    def set_path(var, path) #:nodoc:
      case path
      when NilClass
      when String
        path = File.expand_path(path)
        File.writable?(File.dirname(path)) or \
               raise ArgumentError, "directory for #{var}=#{path} not writable"
      else
        raise ArgumentError
      end
      @set[var] = path
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
      @set[var] = my_proc
    end

    # expands "unix:path/to/foo" to a socket relative to the current path
    # expands pathnames of sockets if relative to "~" or "~username"
    # expands "*:port and ":port" to "0.0.0.0:port"
    def expand_addr(address) #:nodoc
      return address unless String === address

      case address
      when %r{\Aunix:(.*)\z}
        File.expand_path($1)
      when %r{\A~}
        File.expand_path(address)
      when %r{\A\*:(\d+)\z}
        "0.0.0.0:#$1"
      when %r{\A(.*):(\d+)\z}
        # canonicalize the name
        packed = Socket.pack_sockaddr_in($2.to_i, $1)
        Socket.unpack_sockaddr_in(packed).reverse!.join(':')
      else
        address
      end
    end

  end
end
