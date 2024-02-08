# frozen_string_literal: false
use Rack::ContentLength
headers = { 'content-type' => 'text/plain' }
run lambda { |env|
  case env['PATH_INFO']
  when "/block-forever"
    Process.kill(:STOP, $$)
    sleep # in case STOP signal is not received in time
    [ 500, headers, [ "Should never get here\n" ] ]
  else
    [ 200, headers, [ "#$$" ] ]
  end
}
