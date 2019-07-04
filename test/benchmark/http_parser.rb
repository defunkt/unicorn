# encoding: binary
# benchmark for HTTP parser hackers:
#   make http && ruby -I lib:ext/unicorn_http test/benchmark/http_parser.rb
require 'unicorn'
require 'optparse'
require 'benchmark'
$stdout.sync = true
extra = []
nr = 100000
op = OptionParser.new("", 24, '  ') do |opts|
  opts.banner = "Usage: #$0"
  opts.separator "#$0 options:"
  # some of these switches exist for rackup command-line compatibility,

  opts.on('-n NUM', Integer, 'number of iterations') { |i| nr = i }
  opts.on('-H HEADER:VALUE', String) { |h| extra << h }
  opts.parse! ARGV
end
extra << '' if extra[0]

payload = <<"".freeze
GET /nowhere HTTP/1.0\r
Host: example.com\r
Accept-Encoding: gzip\r
Accept-Language: en-US\r
User-Agent: curl/7.52.1\r
Accept: */*\r
Referer: https://example.com/eye-kant-spel\r
Cache-Control: max-age=0\r
X-Forwarded-For: 0.6.6.6\r
#{extra.join("\r\n")}\r

hp = Unicorn::HttpParser.new
puts payload.gsub(/^/, '> ')
puts "#{nr} iterations"
res = Benchmark.measure do
  nr.times do
    hp.buf << payload
    hp.parse or abort
    hp.clear
  end
end
puts Benchmark::CAPTION, res
