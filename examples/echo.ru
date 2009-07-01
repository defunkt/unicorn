#\-E none
# Example application that echoes read data back to the HTTP client.
# This emulates the old echo protocol people used to run.
#
# An example of using this in a client would be to run:
#   curl -NT- http://host:port/
#
# Then type random stuff in your terminal to watch it get echoed back!

class EchoBody
  def initialize(input)
    @input = input
  end

  def each(&block)
    while buf = @input.read(4096)
      yield buf
    end
    self
  end

  def close
    @input = nil
  end
end

use Rack::Chunked
run lambda { |env|
  [ 200, { 'Content-Type' => 'application/octet-stream' },
    EchoBody.new(env['rack.input']) ]
}
