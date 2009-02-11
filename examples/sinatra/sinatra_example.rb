#!/home/ew/bin/ruby
# this is a standalone Sinatra application, there is absolutely NOTHING
# special that has to be done in this file for running with Unicorn,
# instead take a look at the unicorn-sinatra-example script in this
# directory
require 'sinatra'
get('/') { "hello world\n" }
