# -*- encoding: binary -*-

require 'fcntl'
require 'tmpdir'

module Unicorn

  class TmpIO < ::File

    # for easier env["rack.input"] compatibility
    def size
      # flush if sync
      stat.size
    end
  end

  module Util
    class << self

      def is_log?(fp)
        append_flags = File::WRONLY | File::APPEND

        ! fp.closed? &&
          fp.sync &&
          fp.path[0] == ?/ &&
          (fp.fcntl(Fcntl::F_GETFL) & append_flags) == append_flags
        rescue IOError, Errno::EBADF
          false
      end

      def chown_logs(uid, gid)
        ObjectSpace.each_object(File) do |fp|
          fp.chown(uid, gid) if is_log?(fp)
        end
      end

      # This reopens ALL logfiles in the process that have been rotated
      # using logrotate(8) (without copytruncate) or similar tools.
      # A +File+ object is considered for reopening if it is:
      #   1) opened with the O_APPEND and O_WRONLY flags
      #   2) opened with an absolute path (starts with "/")
      #   3) the current open file handle does not match its original open path
      #   4) unbuffered (as far as userspace buffering goes, not O_SYNC)
      # Returns the number of files reopened
      def reopen_logs
        to_reopen = []
        nr = 0
        ObjectSpace.each_object(File) { |fp| is_log?(fp) and to_reopen << fp }

        to_reopen.each do |fp|
          orig_st = begin
            fp.stat
          rescue IOError, Errno::EBADF
            next
          end

          begin
            b = File.stat(fp.path)
            next if orig_st.ino == b.ino && orig_st.dev == b.dev
          rescue Errno::ENOENT
          end

          begin
            File.open(fp.path, 'a') { |tmpfp| fp.reopen(tmpfp) }
            fp.sync = true
            new_st = fp.stat

            # this should only happen in the master:
            if orig_st.uid != new_st.uid || orig_st.gid != new_st.gid
              fp.chown(orig_st.uid, orig_st.gid)
            end

            nr += 1
          rescue IOError, Errno::EBADF
            # not much we can do...
          end
        end

        nr
      end

      # creates and returns a new File object.  The File is unlinked
      # immediately, switched to binary mode, and userspace output
      # buffering is disabled
      def tmpio
        fp = begin
          TmpIO.open("#{Dir::tmpdir}/#{rand}",
                     File::RDWR|File::CREAT|File::EXCL, 0600)
        rescue Errno::EEXIST
          retry
        end
        File.unlink(fp.path)
        fp.binmode
        fp.sync = true
        fp
      end

    end

  end
end
