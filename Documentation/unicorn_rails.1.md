% UNICORN_RAILS(1) Unicorn User Manual
% The Unicorn Community <mongrel-unicorn@rubyforge.org>
% September 17, 2009

# NAME

unicorn_rails - a script/server-like command to launch the Unicorn HTTP server

# SYNOPSIS

unicorn_rails [-c CONFIG_FILE] [-E RAILS_ENV] [-D] [RACKUP_FILE]

# DESCRIPTION

A rackup(1)-like command to launch Rails applications using Unicorn.  It
is expected to be started in your Rails application root (RAILS_ROOT),
but the "working_directory" directive may be used in the CONFIG_FILE.

It is designed to help Rails 1.x and 2.y users transition to Rack, but
it is NOT needed for Rails 3 applications.  Rails 3 users are encouraged
to use unicorn(1) instead of unicorn_rails(1).  Users of Rails 1.x/2.y
may also use unicorn(1) instead of unicorn_rails(1).

The outward interface resembles rackup(1), the internals and default
middleware loading is designed like the `script/server` command
distributed with Rails.

While Unicorn takes a myriad of command-line options for compatibility
with ruby(1) and rackup(1), it is recommended to stick to the few
command-line options specified in the SYNOPSIS and use the CONFIG_FILE
as much as possible.

# UNICORN OPTIONS
-c, \--config-file CONFIG_FILE
:   Path to the Unicorn-specific config file.  The config file is
    implemented as a Ruby DSL, so Ruby code may executed.
    See the RDoc/ri for the *Unicorn::Configurator* class for the full
    list of directives available from the DSL.
    Using an absolute path for for CONFIG_FILE is recommended as it
    makes multiple instances of Unicorn easily distinguishable when
    viewing ps(1) output.

-D, \--daemonize
:   Run daemonized in the background.  The process is detached from
    the controlling terminal and stdin is redirected to "/dev/null".
    Unlike many common UNIX daemons, we do not chdir to \"/\"
    upon daemonization to allow more control over the startup/upgrade
    process.
    Unless specified in the CONFIG_FILE, stderr and stdout will
    also be redirected to "/dev/null".
    Daemonization will _skip_ loading of the *Rails::Rack::LogTailer*
    middleware under Rails \>\= 2.3.x.
    By default, unicorn\_rails(1) will create a PID file in
    _\"RAILS\_ROOT/tmp/pids/unicorn.pid\"_.  You may override this
    by specifying the "pid" directive to override this Unicorn config file.

-E, \--env RAILS_ENV
:   Run under the given RAILS_ENV.  This sets the RAILS_ENV environment
    variable.  Acceptable values are exactly those you expect in your Rails
    application, typically "development" or "production".

-l, \--listen ADDRESS
:   Listens on a given ADDRESS.  ADDRESS may be in the form of
    HOST:PORT or PATH, HOST:PORT is taken to mean a TCP socket
    and PATH is meant to be a path to a UNIX domain socket.
    Defaults to "0.0.0.0:8080" (all addresses on TCP port 8080).
    For production deployments, specifying the "listen" directive in
    CONFIG_FILE is recommended as it allows fine-tuning of socket
    options.

# RACKUP COMPATIBILITY OPTIONS
-o, \--host HOST
:   Listen on a TCP socket belonging to HOST, default is
    "0.0.0.0" (all addresses).
    If specified multiple times on the command-line, only the
    last-specified value takes effect.
    This option only exists for compatibility with the rackup(1) command,
    use of "-l"/"\--listen" switch is recommended instead.

-p, \--port PORT
:   Listen on the specified TCP PORT, default is 8080.
    If specified multiple times on the command-line, only the last-specified
    value takes effect.
    This option only exists for compatibility with the rackup(1) command,
    use of "-l"/"\--listen" switch is recommended instead.

\--path PATH
:   Mounts the Rails application at the given PATH (instead of "/").
    This is equivalent to setting the RAILS_RELATIVE_URL_ROOT
    environment variable.  This is only supported under Rails 2.3
    or later at the moment.

# RUBY OPTIONS
-e, \--eval LINE
:   Evaluate a LINE of Ruby code.  This evaluation happens
    immediately as the command-line is being parsed.

-d, \--debug
:   Turn on debug mode, the $DEBUG variable is set to true.
    For Rails \>\= 2.3.x, this loads the *Rails::Rack::Debugger*
    middleware.

-w, \--warn
:   Turn on verbose warnings, the $VERBOSE variable is set to true.

-I, \--include PATH
:   specify $LOAD_PATH.  PATH will be prepended to $LOAD_PATH.
    The \':\' character may be used to delimit multiple directories.
    This directive may be used more than once.  Modifications to
    $LOAD_PATH take place immediately and in the order they were
    specified on the command-line.

-r, \--require LIBRARY
:   require a specified LIBRARY before executing the application.  The
    \"require\" statement will be executed immediately and in the order
    they were specified on the command-line.

# RACKUP FILE

This defaults to \"config.ru\" in RAILS_ROOT.  It should be the same
file used by rackup(1) and other Rack launchers, it uses the
*Rack::Builder* DSL.  Unlike many other Rack applications, RACKUP_FILE
is completely _optional_ for Rails, but may be used to disable some
of the default middleware for performance.

Embedded command-line options are mostly parsed for compatibility
with rackup(1) but strongly discouraged.

# ENVIRONMENT VARIABLES

The RAILS_ENV variable is set by the aforementioned \-E switch.  The
RAILS_RELATIVE_URL_ROOT is set by the aforementioned \--path switch.
Either of these variables may also be set in the shell or the Unicorn
CONFIG_FILE.  All application or library-specific environment variables
(e.g. TMPDIR, RAILS_ASSET_ID) may always be set in the Unicorn
CONFIG_FILE in addition to the spawning shell.  When transparently
upgrading Unicorn, all environment variables set in the old master
process are inherited by the new master process.  Unicorn only uses (and
will overwrite) the UNICORN_FD environment variable internally when
doing transparent upgrades.

# SIGNALS

The following UNIX signals may be sent to the master process:

* HUP - reload config file, app, and gracefully restart all workers
* INT/TERM - quick shutdown, kills all workers immediately
* QUIT - graceful shutdown, waits for workers to finish their
  current request before finishing.
* USR1 - reopen all logs owned by the master and all workers
  See Unicorn::Util.reopen_logs for what is considered a log.
* USR2 - reexecute the running binary.  A separate QUIT
  should be sent to the original process once the child is verified to
  be up and running.
* WINCH - gracefully stops workers but keep the master running.
  This will only work for daemonized processes.
* TTIN - increment the number of worker processes by one
* TTOU - decrement the number of worker processes by one

See the [SIGNALS][4] document for full description of all signals
used by Unicorn.

# SEE ALSO

* unicorn(1)
* *Rack::Builder* ri/RDoc
* *Unicorn::Configurator* ri/RDoc
* [Unicorn RDoc][1]
* [Rack RDoc][2]
* [Rackup HowTo][3]

[1]: http://unicorn.bogomips.org/
[2]: http://rack.rubyforge.org/doc/
[3]: http://wiki.github.com/rack/rack/tutorial-rackup-howto
[4]: http://unicorn.bogomips.org/SIGNALS.html
