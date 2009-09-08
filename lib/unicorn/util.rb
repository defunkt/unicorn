# -*- encoding: binary -*-

require 'fcntl'
require 'tmpdir'

module Unicorn
  class Util
    class << self

      APPEND_FLAGS = File::WRONLY | File::APPEND

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
          next if fp.closed?
          next unless (fp.sync && fp.path[0..0] == "/")
          next unless (fp.fcntl(Fcntl::F_GETFL) & APPEND_FLAGS) == APPEND_FLAGS

          begin
            a, b = fp.stat, File.stat(fp.path)
            next if a.ino == b.ino && a.dev == b.dev
          rescue Errno::ENOENT
          end

          open_arg = 'a'
          if fp.respond_to?(:external_encoding) && enc = fp.external_encoding
            open_arg << ":#{enc.to_s}"
            enc = fp.internal_encoding and open_arg << ":#{enc.to_s}"
          end
          fp.reopen(fp.path, open_arg)
          fp.sync = true
          nr += 1
        end # each_object
        nr
      end

      # creates and returns a new File object.  The File is unlinked
      # immediately, switched to binary mode, and userspace output
      # buffering is disabled
      def tmpio
        fp = begin
          File.open("#{Dir::tmpdir}/#{rand}",
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
