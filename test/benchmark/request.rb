require 'benchmark'
require 'unicorn'
nr = ENV['nr'] ? ENV['nr'].to_i : 100000

class TestClient
  def initialize(response)
    @response = (response.join("\r\n") << "\r\n\r\n").freeze
  end
  def sysread(len, buf)
    buf.replace(@response)
  end

  alias readpartial sysread

  # old versions of Unicorn used this
  def unicorn_peeraddr
    '127.0.0.1'
  end
end

small = TestClient.new([
  'GET / HTTP/1.0',
  'Host: localhost',
  'Accept: */*',
  'User-Agent: test-user-agent 0.1.0'
])

medium = TestClient.new([
  'GET /hello/world/geturl?abcd=efg&hi#anchor HTTP/1.0',
  'Host: localhost',
  'Accept: */*',
  'User-Agent: test-user-agent 0.1.0 (Mozilla compatible) 5.0 asdfadfasda'
])

include Unicorn
request = HttpRequest.new(Logger.new($stderr))
Benchmark.bmbm do |x|
  x.report("small") do
    for i in 1..nr
      request.read(small)
      request.reset
    end
  end
  x.report("medium") do
    for i in 1..nr
      request.read(medium)
      request.reset
    end
  end
end
