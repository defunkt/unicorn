# -*- encoding: binary -*-
# :stopdoc:
# this module is meant to be included in Unicorn::HttpServer
# It is an implementation detail and NOT meant for users.
module Unicorn::SSLServer
  attr_accessor :ssl_engine

  def ssl_enable!
    sni_hostnames = rack_sni_hostnames(@app)
    seen = {} # we map a single SSLContext to multiple listeners
    listener_ctx = {}
    @listener_opts.each do |address, address_opts|
      ssl_opts = address_opts[:ssl_opts] or next
      listener_ctx[address] = seen[ssl_opts.object_id] ||= begin
        unless sni_hostnames.empty?
          ssl_opts = ssl_opts.dup
          ssl_opts[:sni_hostnames] = sni_hostnames
        end
        ctx = Flipper.ssl_context(ssl_opts)
        # FIXME: make configurable
        ctx.session_cache_mode = OpenSSL::SSL::SSLContext::SESSION_CACHE_OFF
        ctx
      end
    end
    Unicorn::HttpServer::LISTENERS.each do |listener|
      ctx = listener_ctx[sock_name(listener)] or next
      listener.extend(Kgio::SSLServer)
      listener.ssl_ctx = ctx
      listener.kgio_ssl_class = Unicorn::SSLClient
    end
  end

  # ugh, this depends on Rack internals...
  def rack_sni_hostnames(rack_app) # :nodoc:
    hostnames = {}
    if Rack::URLMap === rack_app
      mapping = rack_app.instance_variable_get(:@mapping)
      mapping.each { |hostname,_,_,_| hostnames[hostname] = true }
    end
    hostnames.keys
  end
end
