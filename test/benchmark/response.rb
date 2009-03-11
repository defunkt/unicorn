require 'benchmark'
require 'unicorn'

class NullWriter
  def syswrite(buf); buf.size; end
  def close; end
end

include Unicorn

socket = NullWriter.new
bs = ENV['bs'] ? ENV['bs'].to_i : 4096
count = ENV['count'] ? ENV['count'].to_i : 1
slice = (' ' * bs).freeze
body = (1..count).map { slice }.freeze
hdr = {
  'Content-Length' => bs * count,
  'Content-Type' => 'text/plain'.freeze
}.freeze
response = [ 200, hdr, body ].freeze

nr = ENV['nr'] ? ENV['nr'].to_i : 100000
Benchmark.bmbm do |x|
  x.report do
    for i in 1..nr
      HttpResponse.write(socket.dup, response)
    end
  end
end
