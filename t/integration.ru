#!ruby
# Copyright (C) unicorn hackers <unicorn-public@80x24.org>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>

# this goes for t/integration.t  We'll try to put as many tests
# in here as possible to avoid startup overhead of Ruby.

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

run(lambda do |env|
  case env['REQUEST_METHOD']
  when 'GET'
    case env['PATH_INFO']
    when '/rack-2-newline-headers'; [ 200, { 'X-R2' => "a\nb\nc" }, [] ]
    when '/rack-3-array-headers'; [ 200, { 'x-r3' => %w(a b c) }, [] ]
    when '/nil-header-value'; [ 200, { 'X-Nil' => nil }, [] ]
    when '/unknown-status-pass-through'; [ '666 I AM THE BEAST', {}, [] ]
    end # case PATH_INFO (GET)
  when 'POST'
    case env['PATH_INFO']
    when '/tweak-status-code'; tweak_status_code
    when '/restore-status-code'; restore_status_code
    end # case PATH_INFO (POST)
    # ...
  when 'PUT'
    # ...
  end # case REQUEST_METHOD
end) # run
