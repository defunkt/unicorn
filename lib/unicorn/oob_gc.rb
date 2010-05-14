# -*- encoding: binary -*-
module Unicorn

  # Run GC after every request, after closing the client socket and
  # before attempting to accept more connections.
  #
  # This shouldn't hurt overall performance as long as the server cluster
  # is at <50% CPU capacity, and improves the performance of most memory
  # intensive requests.  This serves to improve _client-visible_
  # performance (possibly at the cost of overall performance).
  #
  # We'll call GC after each request is been written out to the socket, so
  # the client never sees the extra GC hit it.
  #
  # This middleware is _only_ effective for applications that use a lot
  # of memory, and will hurt simpler apps/endpoints that can process
  # multiple requests before incurring GC.
  #
  # This middleware is only designed to work with Unicorn, as it harms
  # keepalive performance.
  #
  # Example (in config.ru):
  #
  #     require 'unicorn/oob_gc'
  #
  #     # GC ever two requests that hit /expensive/foo or /more_expensive/foo
  #     # in your app.  By default, this will GC once every 5 requests
  #     # for all endpoints in your app
  #     use Unicorn::OobGC, 2, %r{\A/(?:expensive/foo|more_expensive/foo)}
  class OobGC < Struct.new(:app, :interval, :path, :nr, :env, :body)

    def initialize(app, interval = 5, path = %r{\A/})
      super(app, interval, path, interval)
    end

    def call(env)
      status, headers, self.body = app.call(self.env = env)
      [ status, headers, self ]
    end

    def each(&block)
      body.each(&block)
    end

    # in Unicorn, this is closed _after_ the client socket
    def close
      body.close if body.respond_to?(:close)

      if path =~ env['PATH_INFO'] && ((self.nr -= 1) <= 0)
        self.nr = interval
        self.body = nil
        env.clear
        GC.start
      end
    end

  end
end
