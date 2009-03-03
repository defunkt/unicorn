require 'fcntl'

module Unicorn
  class Util
    class << self

      # this reopens logs that have been rotated (using logrotate(8) or
      # similar).  It is recommended that you install
      # A +File+ object is considered for reopening if it is:
      #   1) opened with the O_APPEND and O_WRONLY flags
      #   2) opened with an absolute path (starts with "/")
      #   3) the current open file handle does not match its original open path
      #   4) unbuffered (as far as userspace buffering goes)
      # Returns the number of files reopened
      def reopen_logs
        nr = 0
        ObjectSpace.each_object(File) do |fp|
          next if fp.closed?
          next unless (fp.sync && fp.path[0..0] == "/")

          flags = fp.fcntl(Fcntl::F_GETFL)
          open_flags = File::WRONLY | File::APPEND
          next unless (flags & open_flags) == open_flags

          begin
            a, b = fp.stat, File.stat(fp.path)
            next if a.ino == b.ino && a.dev == b.dev
          rescue Errno::ENOENT
          end
          fp.reopen(fp.path, "a")
          fp.sync = true
          nr += 1
        end # each_object
        nr
      end

    end

  end
end
