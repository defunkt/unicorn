# Note: Logger concepts are from a combination of:
#       AlogR: http://alogr.rubyforge.org
#       Merb:  http://merbivore.com
module Mongrel

  #class << self
  #  attr_accessor :logger
  #end

  class Log
    attr_accessor :logger
    attr_accessor :log_level

    Levels = { 
      :name => { :emergency => 0, :alert => 1, :critical => 2, :error => 3, :warning => 4, :notice => 5, :info => 6, :debug => 7 },
      :id => { 0 => :emergency, 1 => :alert, 2 => :critical, 3 => :error, 4 => :warning, 5 => :notice, 6 => :info, 7 => :debug }
    }
    
    def initialize(log, log_level = :debug)
      @logger    = initialize_io(log)
      @log_level = Levels[:name][log_level]

      if !RUBY_PLATFORM.match(/java|mswin/) && 
         !(@log == STDOUT) && 
        @log.respond_to?(:write_nonblock)
        
        @aio = true
      end
    end
    
    # Writes a string to the logger. Writing of the string is skipped if the string's log level is
    # higher than the logger's log level. If the logger responds to write_nonblock and is not on 
    # the java or windows platforms then the logger will use non-blocking asynchronous writes.
    def log(level, string)
      return if (Levels[:name][level] > @log_level)
      if @aio
        @log.write_nonblock("#{Time.now.httpdate}: #{string}\n")
      else
        @log.write("#{Time.now.httpdate}: #{string}\n")
      end
    end
    
    private

    def initialize_io(log)
      if log.respond_to?(:write)
        @log = log
        @log.sync if log.respond_to?(:sync)
      elsif File.exist?(log)
        @log = open(log, (File::WRONLY | File::APPEND))
        @log.sync = true
      else
        @log = open(log, (File::WRONLY | File::APPEND | File::CREAT))
        @log.sync = true
        @log.write("#{Time.now.httpdate} Logfile created")
      end
    end

  end
  
  # Convenience wrapper for logging, allows us to use Mongrel.log
  def self.log(level, string)
    logger.log(level,string)
  end
  
end
