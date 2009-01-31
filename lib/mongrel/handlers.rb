# Copyright (c) 2005 Zed A. Shaw 
# You can redistribute it and/or modify it under the same terms as Ruby.
#
# Additional work donated by contributors.  See http://mongrel.rubyforge.org/attributions.html 
# for more information.

require 'mongrel/stats'
require 'zlib'
require 'yaml'

module Mongrel

  # You implement your application handler with this.  It's very light giving
  # just the minimum necessary for you to handle a request and shoot back 
  # a response.  Look at the HttpRequest and HttpResponse objects for how
  # to use them.
  #
  # This is used for very simple handlers that don't require much to operate.
  # More extensive plugins or those you intend to distribute as GemPlugins 
  # should be implemented using the HttpHandlerPlugin mixin.
  #
  class HttpHandler
    attr_reader :request_notify
    attr_accessor :listener

    # This will be called by Mongrel if HttpHandler.request_notify set to *true*.
    # You only get the parameters for the request, with the idea that you'd "bound"
    # the beginning of the request processing and the first call to process.
    def request_begins(params)
    end

    # Called by Mongrel for each IO chunk that is received on the request socket
    # from the client, allowing you to track the progress of the IO and monitor
    # the input.  This will be called by Mongrel only if HttpHandler.request_notify
    # set to *true*.
    def request_progress(params, clen, total)
    end

    def process(request, response)
    end

  end


  # This is used when your handler is implemented as a GemPlugin.
  # The plugin always takes an options hash which you can modify
  # and then access later.  They are stored by default for 
  # the process method later.
  module HttpHandlerPlugin
    attr_reader :options
    attr_reader :request_notify
    attr_accessor :listener

    def request_begins(params)
    end

    def request_progress(params, clen, total)
    end

    def initialize(options={})
      @options = options
      @header_only = false
    end

    def process(request, response)
    end

  end


  #
  # The server normally returns a 404 response if an unknown URI is requested, but it
  # also returns a lame empty message.  This lets you do a 404 response
  # with a custom message for special URIs.
  #
  class Error404Handler < HttpHandler

    # Sets the message to return.  This is constructed once for the handler
    # so it's pretty efficient.
    def initialize(msg)
      @response = Const::ERROR_404_RESPONSE + msg
    end

    # Just kicks back the standard 404 response with your special message.
    def process(request, response)
      response.socket.write(@response)
    end

  end

  # When added to a config script (-S in mongrel_rails) it will
  # look at the client's allowed response types and then gzip 
  # compress anything that is going out.
  #
  # Valid option is :always_deflate => false which tells the handler to
  # deflate everything even if the client can't handle it.
  class DeflateFilter < HttpHandler
    include Zlib
    HTTP_ACCEPT_ENCODING = "HTTP_ACCEPT_ENCODING" 

    def initialize(ops={})
      @options = ops
      @always_deflate = ops[:always_deflate] || false
    end

    def process(request, response)
      accepts = request.params[HTTP_ACCEPT_ENCODING]
      # only process if they support compression
      if @always_deflate or (accepts and (accepts.include? "deflate" and not response.body_sent))
        response.header["Content-Encoding"] = "deflate"
        response.body = deflate(response.body)
      end
    end

    private
      def deflate(stream)
        deflater = Deflate.new(
          DEFAULT_COMPRESSION,
          # drop the zlib header which causes both Safari and IE to choke
          -MAX_WBITS, 
          DEF_MEM_LEVEL,
          DEFAULT_STRATEGY)

        stream.rewind
        gzout = StringIO.new(deflater.deflate(stream.read, FINISH))
        stream.close
        gzout.rewind
        gzout
      end
  end


  # Implements a few basic statistics for a particular URI.  Register it anywhere
  # you want in the request chain and it'll quickly gather some numbers for you
  # to analyze.  It is pretty fast, but don't put it out in production.
  #
  # You should pass the filter to StatusHandler as StatusHandler.new(:stats_filter => stats).
  # This lets you then hit the status URI you want and get these stats from a browser.
  #
  # StatisticsFilter takes an option of :sample_rate.  This is a number that's passed to
  # rand and if that number gets hit then a sample is taken.  This helps reduce the load
  # and keeps the statistics valid (since sampling is a part of how they work).
  #
  # The exception to :sample_rate is that inter-request time is sampled on every request.
  # If this wasn't done then it wouldn't be accurate as a measure of time between requests.
  class StatisticsFilter < HttpHandler
    attr_reader :stats

    def initialize(ops={})
      @sample_rate = ops[:sample_rate] || 300

      @processors = Mongrel::Stats.new("processors")
      @reqsize = Mongrel::Stats.new("request Kb")
      @headcount = Mongrel::Stats.new("req param count")
      @respsize = Mongrel::Stats.new("response Kb")
      @interreq = Mongrel::Stats.new("inter-request time")
    end


    def process(request, response)
      if rand(@sample_rate)+1 == @sample_rate
        @processors.sample(listener.workers.list.length)
        @headcount.sample(request.params.length)
        @reqsize.sample(request.body.length / 1024.0)
        @respsize.sample((response.body.length + response.header.out.length) / 1024.0)
      end
      @interreq.tick
    end

    def dump
      "#{@processors.to_s}\n#{@reqsize.to_s}\n#{@headcount.to_s}\n#{@respsize.to_s}\n#{@interreq.to_s}"
    end
  end


  # The :stats_filter is basically any configured stats filter that you've added to this same
  # URI.  This lets the status handler print out statistics on how Mongrel is doing.
  class StatusHandler < HttpHandler
    def initialize(ops={})
      @stats = ops[:stats_filter]
    end

    def table(title, rows)
      results = "<table border=\"1\"><tr><th colspan=\"#{rows[0].length}\">#{title}</th></tr>"
      rows.each do |cols|
        results << "<tr>"
        cols.each {|col| results << "<td>#{col}</td>" }
        results << "</tr>"
      end
      results + "</table>"
    end

    def describe_listener
      results = ""
      results << "<h1>Listener #{listener.host}:#{listener.port}</h1>"
      results << table("settings", [
                       ["host",listener.host],
                       ["port",listener.port],
                       ["throttle",listener.throttle],
                       ["timeout",listener.timeout],
                       ["workers max",listener.num_processors],
      ])

      if @stats
        results << "<h2>Statistics</h2><p>N means the number of samples, pay attention to MEAN, SD, MIN and MAX."
        results << "<pre>#{@stats.dump}</pre>"
      end

      results << "<h2>Registered Handlers</h2>"
      handler_map = listener.classifier.handler_map
      results << table("handlers", handler_map.map {|uri,handlers| 
        [uri, 
            "<pre>" + 
            handlers.map {|h| h.class.to_s }.join("\n") + 
            "</pre>"
        ]
      })

      results
    end

    def process(request, response)
      response.start do |head,out|
        out.write <<-END
        <html><body><title>Mongrel Server Status</title>
        #{describe_listener}
        </body></html>
        END
      end
    end
  end
end
