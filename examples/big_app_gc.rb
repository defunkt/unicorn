# Run GC after every request, before attempting to accept more connections.
#
# You could customize this patch to read REQ["PATH_INFO"] and only
# call GC.start after expensive requests.
#
# We could have this wrap the response body.close as middleware, but the
# scannable stack is would still be bigger than it would be here.
#
# This shouldn't hurt overall performance as long as the server cluster
# is at <=50% CPU capacity, and improves the performance of most memory
# intensive requests.  This serves to improve _client-visible_
# performance (possibly at the cost of overall performance).
#
# We'll call GC after each request is been written out to the socket, so
# the client never sees the extra GC hit it. It's ideal to call the GC
# inside the HTTP server (vs middleware or hooks) since the stack is
# smaller at this point, so the GC will both be faster and more
# effective at releasing unused memory.
#
# This monkey patch is _only_ effective for applications that use a lot
# of memory, and will hurt simpler apps/endpoints that can process
# multiple requests before incurring GC.

class Unicorn::HttpServer
  REQ = Unicorn::HttpRequest::REQ
  alias _process_client process_client
  undef_method :process_client
  def process_client(client)
    _process_client(client)
    REQ.clear
    GC.start
  end
end if defined?(Unicorn)
