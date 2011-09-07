# -*- encoding: binary -*-
# :stopdoc:
# This module is included in Unicorn::Configurator
# :startdoc:
#
module Unicorn::SSLConfigurator
  def ssl(&block)
    ssl_require!
    before = @set[:listeners].dup
    opts = @set[:ssl_opts] = {}
    yield
    (@set[:listeners] - before).each do |address|
      (@set[:listener_opts][address] ||= {})[:ssl_opts] = opts
    end
    ensure
      @set.delete(:ssl_opts)
  end

  def ssl_certificate(file)
    ssl_set(:ssl_certificate, file)
  end

  def ssl_certificate_key(file)
    ssl_set(:ssl_certificate_key, file)
  end

  def ssl_client_certificate(file)
    ssl_set(:ssl_client_certificate, file)
  end

  def ssl_dhparam(file)
    ssl_set(:ssl_dhparam, file)
  end

  def ssl_ciphers(openssl_cipherlist_spec)
    ssl_set(:ssl_ciphers, openssl_cipherlist_spec)
  end

  def ssl_crl(file)
    ssl_set(:ssl_crl, file)
  end

  def ssl_prefer_server_ciphers(bool)
    ssl_set(:ssl_prefer_server_ciphers, check_bool(bool))
  end

  def ssl_protocols(list)
    ssl_set(:ssl_protocols, list)
  end

  def ssl_verify_client(on_off_optional)
    ssl_set(:ssl_verify_client, on_off_optional)
  end

  def ssl_session_timeout(seconds)
    ssl_set(:ssl_session_timeout, seconds)
  end

  def ssl_verify_depth(depth)
    ssl_set(:ssl_verify_depth, depth)
  end

  # Allows specifying an engine for OpenSSL to use.  We have not been
  # able to successfully test this feature due to a lack of hardware,
  # Reports of success or patches to mongrel-unicorn@rubyforge.org is
  # greatly appreciated.
  def ssl_engine(engine)
    ssl_warn_global(:ssl_engine)
    ssl_require!
    OpenSSL::Engine.load
    OpenSSL::Engine.by_id(engine)
    @set[:ssl_engine] = engine
  end

  def ssl_compression(bool)
    # OpenSSL uses the SSL_OP_NO_COMPRESSION flag, Flipper follows suit
    # with :ssl_no_compression, but we negate it to avoid exposing double
    # negatives to the user.
    ssl_set(:ssl_no_compression, check_bool(:ssl_compression, ! bool))
  end

private

  def ssl_warn_global(func) # :nodoc:
    Hash === @set[:ssl_opts] or return
    warn("`#{func}' affects all SSL contexts in this process, " \
         "not just this block")
  end

  def ssl_set(key, value) # :nodoc:
    cur = @set[:ssl_opts]
    Hash === cur or
             raise ArgumentError, "#{key} must be called inside an `ssl' block"
    cur[key] = value
  end

  def ssl_require! # :nodoc:
    require "flipper"
    require "unicorn/ssl_client"
    rescue LoadError
      warn "install 'kgio-monkey' for SSL support"
      raise
  end
end
