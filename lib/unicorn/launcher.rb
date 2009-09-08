# -*- encoding: binary -*-

$stdin.sync = $stdout.sync = $stderr.sync = true
$stdin.binmode
$stdout.binmode
$stderr.binmode

require 'unicorn'

class Unicorn::Launcher

  # We don't do a lot of standard daemonization stuff:
  #   * umask is whatever was set by the parent process at startup
  #     and can be set in config.ru and config_file, so making it
  #     0000 and potentially exposing sensitive log data can be bad
  #     policy.
  #   * don't bother to chdir("/") here since unicorn is designed to
  #     run inside APP_ROOT.  Unicorn will also re-chdir() to
  #     the directory it was started in when being re-executed
  #     to pickup code changes if the original deployment directory
  #     is a symlink or otherwise got replaced.
  def self.daemonize!
    $stdin.reopen("/dev/null")

    # We only start a new process group if we're not being reexecuted
    # and inheriting file descriptors from our parent
    unless ENV['UNICORN_FD']
      exit if fork
      Process.setsid
      exit if fork

      # $stderr/$stderr can/will be redirected separately in the Unicorn config
      Unicorn::Configurator::DEFAULTS[:stderr_path] = "/dev/null"
      Unicorn::Configurator::DEFAULTS[:stdout_path] = "/dev/null"
    end
    $stdin.sync = $stdout.sync = $stderr.sync = true
  end

end
