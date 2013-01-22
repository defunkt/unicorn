use Rack::Lint
use Rack::ContentLength
use Rack::ContentType, "text/plain"
class DieIfUsed
  def each
    abort "body.each called after response hijack\n"
  end

  def close
    abort "body.close called after response hijack\n"
  end
end
run lambda { |env|
  case env["PATH_INFO"]
  when "/hijack_req"
    if env["rack.hijack?"]
      io = env["rack.hijack"].call
      if io.respond_to?(:read_nonblock) &&
         env["rack.hijack_io"].respond_to?(:read_nonblock)
        return [ 200, {}, [ "hijack.OK\n" ] ]
      end
    end
    [ 500, {}, [ "hijack BAD\n" ] ]
  when "/hijack_res"
    r = "response.hijacked"
    [ 200,
      {
        "Content-Length" => r.bytesize.to_s,
        "rack.hijack" => proc do |io|
          io.write(r)
          io.close
        end
      },
      DieIfUsed.new
    ]
  end
}
