require 'rubygems'
require 'rack'

@app = proc { [200, {}, "tada"] }

@urls = URLMap('\test' => @app)
