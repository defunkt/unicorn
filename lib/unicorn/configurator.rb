module Unicorn

  # Implements a simple DSL for configuring a Unicorn server.
  class Configurator
    include ::Unicorn::SocketHelper

    DEFAULT_LOGGER = Logger.new(STDERR) unless defined?(DEFAULT_LOGGER)

    DEFAULTS = {
      :timeout => 60,
      :listeners => [ Const::DEFAULT_LISTEN ],
      :logger => DEFAULT_LOGGER,
      :worker_processes => 1,
      :after_fork => lambda { |server, worker_nr|
          server.logger.info("worker=#{worker_nr} spawned pid=#{$$}")

          # per-process listener ports for debugging/admin:
          # server.add_listener("127.0.0.1:#{8081 + worker_nr}")
        },
      :before_fork => lambda { |server, worker_nr|
          server.logger.info("worker=#{worker_nr} spawning...")
        },
      :pid => nil,
      :backlog => 1024,
    }

    attr_reader :config_file

    def initialize(defaults = {})
      @set = Hash.new(:unset)
      use_defaults = defaults.delete(:use_defaults)
      @config_file = defaults.delete(:config_file)
      @config_file.freeze
      @set.merge!(DEFAULTS) if use_defaults
      defaults.each { |key, value| self.send(key, value) }
      reload
    end

    def reload
      instance_eval(File.read(@config_file)) if @config_file
    end

    def commit!(server, options = {})
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

    def [](key)
      @set[key]
    end

    # Changes the listen() syscall backlog to +nr+ for yet-to-be-created
    # sockets.  Due to limitations of the OS, this cannot affect
    # existing listener sockets in any way, sockets must be completely
    # closed and rebound (inherited sockets preserve their existing
    # backlog setting).  Some operating systems allow negative values
    # here to specify the maximum allowable value.
    def backlog(nr)
      Integer === nr or raise ArgumentError,
         "not an integer: backlog=#{nr.inspect}"
      @set[:backlog] = nr
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

    # sets after_fork hook to a given block.  This block
    # will be called by the worker after forking
    def after_fork(&block)
      set_hook(:after_fork, block)
    end

    # sets before_fork got be a given Proc object.  This Proc
    # object will be called by the master process before forking
    # each worker.
    def before_fork(&block)
      set_hook(:before_fork, block)
    end

    # sets the timeout of worker processes to +seconds+
    # This will gracefully restart all workers if the value is lowered
    # to prevent them from being timed out according to new timeout rules
    def timeout(seconds)
      Numeric === seconds or raise ArgumentError,
                                  "not numeric: timeout=#{seconds.inspect}"
      seconds > 0 or raise ArgumentError,
                                  "not positive: timeout=#{seconds.inspect}"
      @set[:timeout] = seconds
    end

    # sets the current number of worker_processes to +nr+
    def worker_processes(nr)
      Integer === nr or raise ArgumentError,
                             "not an integer: worker_processes=#{nr.inspect}"
      nr >= 0 or raise ArgumentError,
                             "not non-negative: worker_processes=#{nr.inspect}"
      @set[:worker_processes] = nr
    end

    # sets listeners to the given +addresses+, replacing the current set
    def listeners(addresses)
      Array === addresses or addresses = Array(addresses)
      @set[:listeners] = addresses
    end

    # adds an +address+ to the existing listener set
    def listen(address)
      @set[:listeners] = [] unless Array === @set[:listeners]
      @set[:listeners] << address
    end

    # sets the +path+ for the PID file of the unicorn master process
    def pid(path)
      if path
        path = File.expand_path(path)
        File.writable?(File.dirname(path)) or raise ArgumentError,
                                     "directory for pid=#{path} not writable"
      end
      @set[:pid] = path
    end

    private

    def set_hook(var, my_proc) #:nodoc:
      case my_proc
      when Proc
        arity = my_proc.arity
        (arity == 2 || arity < 0) or raise ArgumentError,
                        "#{var}=#{my_proc.inspect} has invalid arity: #{arity}"
      when NilClass
        my_proc = DEFAULTS[var]
      else
        raise ArgumentError, "invalid type: #{var}=#{my_proc.inspect}"
      end
      @set[var] = my_proc
    end

  end
end
