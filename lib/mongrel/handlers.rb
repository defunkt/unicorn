# Copyright (c) 2005 Zed A. Shaw 
# You can redistribute it and/or modify it under the same terms as Ruby.
#
# Additional work donated by contributors.  See http://mongrel.rubyforge.org/attributions.html 
# for more information.

require 'zlib'
require 'yaml'

module Mongrel
  #
  # You implement your application handler with this.  It's very light giving
  # just the minimum necessary for you to handle a request and shoot back 
  # a response.  Look at the HttpRequest and HttpResponse objects for how
  # to use them.
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
end
