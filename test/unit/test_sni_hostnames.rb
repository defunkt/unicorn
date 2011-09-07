# -*- encoding: binary -*-
require "test/unit"
require "unicorn"

# this tests an implementation detail, it may change so this test
# can be removed later.
class TestSniHostnames < Test::Unit::TestCase
  include Unicorn::SSLServer

  def setup
    GC.start
  end

  def teardown
    GC.start
  end

  def test_host_name_detect_one
    app = Rack::Builder.new do
      map "http://sni1.example.com/" do
        use Rack::ContentLength
        use Rack::ContentType, "text/plain"
        run lambda { |env| [ 200, {}, [] ] }
      end
    end.to_app
    hostnames = rack_sni_hostnames(app)
    assert hostnames.include?("sni1.example.com")
  end

  def test_host_name_detect_multiple
    app = Rack::Builder.new do
      map "http://sni2.example.com/" do
        use Rack::ContentLength
        use Rack::ContentType, "text/plain"
        run lambda { |env| [ 200, {}, [] ] }
      end
      map "http://sni3.example.com/" do
        use Rack::ContentLength
        use Rack::ContentType, "text/plain"
        run lambda { |env| [ 200, {}, [] ] }
      end
    end.to_app
    hostnames = rack_sni_hostnames(app)
    assert hostnames.include?("sni2.example.com")
    assert hostnames.include?("sni3.example.com")
  end
end
