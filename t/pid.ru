# frozen_string_literal: false
use Rack::ContentLength
use Rack::ContentType, "text/plain"
run lambda { |env| [ 200, {}, [ "#$$\n" ] ] }
