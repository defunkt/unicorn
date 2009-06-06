#\-E none
require 'unicorn/app/inetd'

use Rack::Lint
use Rack::Chunked
# run Unicorn::App::Inetd.new('tee', '/tmp/tee.out')
run Unicorn::App::Inetd.new(
 *%w(git daemon --verbose --inetd --export-all --base-path=/home/ew/unicorn)
)
