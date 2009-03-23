require 'benchmark'
require 'tempfile'
require 'unicorn'
nr = ENV['nr'] ? ENV['nr'].to_i : 100
bs = ENV['bs'] ? ENV['bs'].to_i : (1024 * 1024)
count = ENV['count'] ? ENV['count'].to_i : 4
length = bs * count
slice = (' ' * bs).freeze

big = Tempfile.new('')
def big.unicorn_peeraddr; '127.0.0.1'; end
big.syswrite(
"PUT /hello/world/puturl?abcd=efg&hi#anchor HTTP/1.0\r\n" \
"Host: localhost\r\n" \
"Accept: */*\r\n" \
"Content-Length: #{length}\r\n" \
"User-Agent: test-user-agent 0.1.0 (Mozilla compatible) 5.0 asdfadfasda\r\n" \
"\r\n")
count.times { big.syswrite(slice) }
big.sysseek(0)
big.fsync

include Unicorn
request = HttpRequest.new(Logger.new($stderr))

Benchmark.bmbm do |x|
  x.report("big") do
    for i in 1..nr
      request.read(big)
      request.reset
      big.sysseek(0)
    end
  end
end

