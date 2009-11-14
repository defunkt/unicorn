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

  class Util
    class << self

      def is_log?(fp)
        append_flags = File::WRONLY | File::APPEND

        ! fp.closed? &&
          fp.sync &&
          fp.path[0] == ?/ &&
          (fp.fcntl(Fcntl::F_GETFL) & append_flags) == append_flags
      end

      def chown_logs(uid, gid)
        ObjectSpace.each_object(File) do |fp|
          is_log?(fp) or next
          fp.chown(uid, gid)
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
        nr = 0

        ObjectSpace.each_object(File) do |fp|
          is_log?(fp) or next
          orig_st = fp.stat
          begin
            b = File.stat(fp.path)
            next if orig_st.ino == b.ino && orig_st.dev == b.dev
          rescue Errno::ENOENT
          end

          open_arg = 'a'
          if fp.respond_to?(:external_encoding) && enc = fp.external_encoding
            open_arg << ":#{enc.to_s}"
            enc = fp.internal_encoding and open_arg << ":#{enc.to_s}"
          end
          fp.reopen(fp.path, open_arg)
          fp.sync = true
          new_st = fp.stat
          if orig_st.uid != new_st.uid || orig_st.gid != new_st.gid
            fp.chown(orig_st.uid, orig_st.gid)
          end
          nr += 1
        end # each_object
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
