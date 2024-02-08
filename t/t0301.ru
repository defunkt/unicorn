#\-N --debug
# frozen_string_literal: false
run(lambda do |env|
  case env['PATH_INFO']
  when '/vars'
    b = "debug=#{$DEBUG.inspect}\n" \
        "lint=#{caller.grep(%r{rack/lint\.rb})[0].split(':')[0]}\n"
  end
  h = {
    'content-length' => b.size.to_s,
    'content-type' => 'text/plain',
  }
  [ 200, h, [ b ] ]
end)
