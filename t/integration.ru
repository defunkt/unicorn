#!ruby
# frozen_string_literal: false
# Copyright (C) unicorn hackers <unicorn-public@80x24.org>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>

# this goes for t/integration.t  We'll try to put as many tests
# in here as possible to avoid startup overhead of Ruby.

def early_hints(env, val)
  env['rack.early_hints'].call('link' => val) # val may be ary or string
  [ 200, {}, [ val.class.to_s ] ]
end

$orig_rack_200 = nil
def tweak_status_code
  $orig_rack_200 = Rack::Utils::HTTP_STATUS_CODES[200]
  Rack::Utils::HTTP_STATUS_CODES[200] = "HI"
  [ 200, {}, [] ]
end

def restore_status_code
  $orig_rack_200 or return [ 500, {}, [] ]
  Rack::Utils::HTTP_STATUS_CODES[200] = $orig_rack_200
  [ 200, {}, [] ]
end

class WriteOnClose
  def each(&block)
    @callback = block
  end

  def close
    @callback.call "7\r\nGoodbye\r\n0\r\n\r\n"
  end
end

def write_on_close
  [ 200, { 'transfer-encoding' => 'chunked' }, WriteOnClose.new ]
end

def env_dump(env)
  require 'json'
  h = {}
  env.each do |k,v|
    case v
    when String, Integer, true, false; h[k] = v
    else
      case k
      when 'rack.version', 'rack.after_reply'; h[k] = v
      end
    end
  end
  h.to_json
end

def rack_input_tests(env)
  return [ 100, {}, [] ] if /\A100-continue\z/i =~ env['HTTP_EXPECT']
  cap = 16384
  require 'digest/md5'
  dig = Digest::MD5.new
  input = env['rack.input']
  case env['PATH_INFO']
  when '/rack_input/size_first'; input.size
  when '/rack_input/rewind_first'; input.rewind
  when '/rack_input'; # OK
  else
    abort "bad path: #{env['PATH_INFO']}"
  end
  if buf = input.read(rand(cap))
    begin
      raise "#{buf.size} > #{cap}" if buf.size > cap
      dig.update(buf)
    end while input.read(rand(cap), buf)
    buf.clear # remove this call if Ruby ever gets escape analysis
  end
  h = { 'content-type' => 'text/plain' }
  if env['HTTP_TRAILER'] =~ /\bContent-MD5\b/i
    cmd5_b64 = env['HTTP_CONTENT_MD5'] or return [500, {}, ['No Content-MD5']]
    cmd5_bin = cmd5_b64.unpack('m')[0]
    if cmd5_bin != dig.digest
      h['content-length'] = cmd5_b64.size.to_s
      return [ 500, h, [ cmd5_b64 ] ]
    end
  end
  h['content-length'] = '32'
  [ 200, h, [ dig.hexdigest ] ]
end

run(lambda do |env|
  case env['REQUEST_METHOD']
  when 'GET'
    case env['PATH_INFO']
    when '/rack-2-newline-headers'; [ 200, { 'X-R2' => "a\nb\nc" }, [] ]
    when '/rack-3-array-headers'; [ 200, { 'x-r3' => %w(a b c) }, [] ]
    when '/nil-header-value'; [ 200, { 'X-Nil' => nil }, [] ]
    when '/unknown-status-pass-through'; [ '666 I AM THE BEAST', {}, [] ]
    when '/env_dump'; [ 200, {}, [ env_dump(env) ] ]
    when '/write_on_close'; write_on_close
    when '/pid'; [ 200, {}, [ "#$$\n" ] ]
    when '/early_hints_rack2'; early_hints(env, "r\n2")
    when '/early_hints_rack3'; early_hints(env, %w(r 3))
    when '/broken_app'; raise RuntimeError, 'hello'
    else '/'; [ 200, {}, [ env_dump(env) ] ]
    end # case PATH_INFO (GET)
  when 'POST'
    case env['PATH_INFO']
    when '/tweak-status-code'; tweak_status_code
    when '/restore-status-code'; restore_status_code
    end # case PATH_INFO (POST)
    # ...
  when 'PUT'
    case env['PATH_INFO']
    when %r{\A/rack_input}; rack_input_tests(env)
    end
  end # case REQUEST_METHOD
end) # run
