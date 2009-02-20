# Copyright (c) 2005 Zed A. Shaw 
# You can redistribute it and/or modify it under the same terms as Ruby.
#
# Additional work donated by contributors.  See http://mongrel.rubyforge.org/attributions.html 
# for more information.


HERE = File.dirname(__FILE__) unless defined?(HERE)
%w(lib ext bin test).each do |dir| 
  $LOAD_PATH.unshift "#{HERE}/../#{dir}"
end

require 'test/unit'
require 'net/http'
require 'digest/sha1'
require 'uri'
require 'stringio'
require 'unicorn'
require 'tmpdir'

if ENV['DEBUG']
  require 'ruby-debug'
  Debugger.start
end

def redirect_test_io
  orig_err = STDERR.dup
  orig_out = STDOUT.dup
  STDERR.reopen("test_stderr.#{$$}.log")
  STDOUT.reopen("test_stdout.#{$$}.log")

  at_exit do
    File.unlink("test_stderr.#{$$}.log") rescue nil
    File.unlink("test_stdout.#{$$}.log") rescue nil
  end

  begin
    yield
  ensure
    STDERR.reopen(orig_err)
    STDOUT.reopen(orig_out)
  end
end
    
# Either takes a string to do a get request against, or a tuple of [URI, HTTP] where
# HTTP is some kind of Net::HTTP request object (POST, HEAD, etc.)
def hit(uris)
  results = []
  uris.each do |u|
    res = nil

    if u.kind_of? String
      res = Net::HTTP.get(URI.parse(u))
    else
      url = URI.parse(u[0])
      res = Net::HTTP.new(url.host, url.port).start {|h| h.request(u[1]) }
    end

    assert res != nil, "Didn't get a response: #{u}"
    results << res
  end

  return results
end

# unused_port provides an unused port on +addr+ usable for TCP that is
# guaranteed to be unused across all unicorn builds on that system.  It
# prevents race conditions by using a lock file other unicorn builds
# will see.  This is required if you perform several builds in parallel
# with a continuous integration system or run tests in parallel via
# gmake.  This is NOT guaranteed to be race-free if you run other
# processes that bind to random ports for testing (but the window
# for a race condition is very small).  You may also set UNICORN_TEST_ADDR
# to override the default test address (127.0.0.1).
def unused_port(addr = '127.0.0.1')
  retries = 100
  base = 5000
  port = sock = nil
  begin
    begin
      port = base + rand(32768 - base)
      sock = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
      sock.bind(Socket.pack_sockaddr_in(port, addr))
      sock.listen(5)
    rescue Errno::EADDRINUSE, Errno::EACCES
      sock.close rescue nil
      retry if (retries -= 1) >= 0
    end

    # since we'll end up closing the random port we just got, there's a race
    # condition could allow the random port we just chose to reselect itself
    # when running tests in parallel with gmake.  Create a lock file while
    # we have the port here to ensure that does not happen .
    lock_path = "#{Dir::tmpdir}/unicorn_test.#{addr}:#{port}.lock"
    lock = File.open(lock_path, File::WRONLY|File::CREAT|File::EXCL, 0600)
    at_exit { File.unlink(lock_path) rescue nil }
  rescue Errno::EEXIST
    sock.close rescue nil
    retry
  end
  sock.close rescue nil
  port
end
