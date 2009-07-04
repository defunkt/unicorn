# This code is based on the original Rails handler in Mongrel
# Copyright (c) 2005 Zed A. Shaw
# Copyright (c) 2009 Eric Wong
# You can redistribute it and/or modify it under the same terms as Ruby.

require 'rack/file'

# Static file handler for Rails < 2.3.  This handler is only provided
# as a convenience for developers.  Performance-minded deployments should
# use nginx (or similar) for serving static files.
#
# This supports page caching directly and will try to resolve a
# request in the following order:
#
# * If the requested exact PATH_INFO exists as a file then serve it.
# * If it exists at PATH_INFO+rest_operator+".html" exists
#   then serve that.
#
# This means that if you are using page caching it will actually work
# with Unicorn and you should see a decent speed boost (but not as
# fast as if you use a static server like nginx).
class Unicorn::App::OldRails::Static < Struct.new(:app, :root, :file_server)
  FILE_METHODS = { 'GET' => true, 'HEAD' => true }.freeze
  REQUEST_METHOD = 'REQUEST_METHOD'.freeze
  REQUEST_URI = 'REQUEST_URI'.freeze
  PATH_INFO = 'PATH_INFO'.freeze

  def initialize(app)
    self.app = app
    self.root = "#{::RAILS_ROOT}/public"
    self.file_server = ::Rack::File.new(root)
  end

  def call(env)
    # short circuit this ASAP if serving non-file methods
    FILE_METHODS.include?(env[REQUEST_METHOD]) or return app.call(env)

    # first try the path as-is
    path_info = env[PATH_INFO].chomp("/")
    if File.file?("#{root}/#{::Rack::Utils.unescape(path_info)}")
      # File exists as-is so serve it up
      env[PATH_INFO] = path_info
      return file_server.call(env)
    end

    # then try the cached version:

    # grab the semi-colon REST operator used by old versions of Rails
    # this is the reason we didn't just copy the new Rails::Rack::Static
    env[REQUEST_URI] =~ /^#{Regexp.escape(path_info)}(;[^\?]+)/
    path_info << "#$1#{ActionController::Base.page_cache_extension}"

    if File.file?("#{root}/#{::Rack::Utils.unescape(path_info)}")
      env[PATH_INFO] = path_info
      return file_server.call(env)
    end

    app.call(env) # call OldRails
  end
end if defined?(Unicorn::App::OldRails)
