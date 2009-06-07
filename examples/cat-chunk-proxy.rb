#!/home/ew/bin/ruby
# I wish I could just use curl --no-buffer -sSfT- http://host:port/, but
# unfortunately curl will attempt to read stdin in blocking mode,
# preventing it from getting responses from the server until stdin has
# been written to.
#
# For a patch that enables using curl(1) instead of this script:
#
#   http://mid.gmane.org/20090607101700.GB19407@dcvr.yhbt.net
#
# Usage: GIT_PROXY_COMMAND=/path/to/here git clone
# git://host:port/project
#
# Where host:port is what the Unicorn server is bound to

require 'socket'
require 'unicorn'
require 'unicorn/chunked_reader'

$stdin.sync = $stdout.sync = $stderr.sync = true
$stdin.binmode
$stdout.binmode

usage = "#$0 HOST PORT"
host = ARGV.shift or abort usage
port = ARGV.shift or abort usage
s = TCPSocket.new(host, port.to_i)
s.sync = true
s.write("PUT / HTTP/1.1\r\n" \
        "Host: #{host}\r\n" \
        "Transfer-Encoding: chunked\r\n\r\n")
buf = s.readpartial(16384)
while /\r\n\r\n/ !~ buf
  buf << s.readpartial(16384)
end

head, body = buf.split(/\r\n\r\n/, 2)

input = fork {
  $0 = "input #$0"
  begin
    loop {
      $stdin.readpartial(16384, buf)
      s.write("#{'%x' % buf.size}\r\n#{buf}\r\n")
    }
  rescue EOFError,Errno::EPIPE,Errno::EBADF,Errno::EINVAL => e
  end
  s.write("0\r\n\r\n")
}

output = fork {
  $0 = "output #$0"

  c = Unicorn::ChunkedReader.new
  c.reopen(s, body)
  begin
    loop { $stdout.write(c.readpartial(16384, buf)) }
  rescue EOFError,Errno::EPIPE,Errno::EBADF,Errno::EINVAL => e
  end
}

2.times {
  pid, status = Process.waitpid2
  $stderr.write("reaped: #{status.inspect}\n") unless status.success?
}
