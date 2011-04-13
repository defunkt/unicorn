# -*- encoding: binary -*-

# This class and its members can be considered a stable interface
# and will not change in a backwards-incompatible fashion between
# releases of \Unicorn.  Knowledge of this class is generally not
# not needed for most users of \Unicorn.
#
# Some users may want to access it in the before_fork/after_fork hooks.
# See the Unicorn::Configurator RDoc for examples.
class Unicorn::Worker < Struct.new(:nr, :tmp, :switched)

  # worker objects may be compared to just plain Integers
  def ==(other_nr) # :nodoc:
    nr == other_nr
  end

  # In most cases, you should be using the Unicorn::Configurator#user
  # directive instead.  This method should only be used if you need
  # fine-grained control of exactly when you want to change permissions
  # in your after_fork hooks.
  #
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
