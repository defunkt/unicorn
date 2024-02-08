#\-E none
# frozen_string_literal: false
require 'digest/md5'
require 'unicorn/preread_input'
use Unicorn::PrereadInput
nr = 0
run lambda { |env|
  $stderr.write "app dispatch: #{nr += 1}\n"
  input = env["rack.input"]
  dig = Digest::MD5.new
  if buf = input.read(16384)
    begin
      dig.update(buf)
    end while input.read(16384, buf)
    buf.clear # remove this call if Ruby ever gets escape analysis
  end
  if env['HTTP_TRAILER'] =~ /\bContent-MD5\b/i
    cmd5_b64 = env['HTTP_CONTENT_MD5'] or return [500, {}, ['No Content-MD5']]
    cmd5_bin = cmd5_b64.unpack('m')[0]
    return [500, {}, [ cmd5_b64 ] ] if cmd5_bin != dig.digest
  end
  [ 200, {}, [ dig.hexdigest ] ]
}
