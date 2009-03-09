
require 'rubygems'
require 'echoe'

Echoe.new("unicorn") do |p|
  p.summary = "A small fast HTTP library and server for Rack applications."
  p.author = "Eric Wong"
  p.email = "normalperson@yhbt.net"
  p.clean_pattern = ['ext/unicorn/http11/*.{bundle,so,o,obj,pdb,lib,def,exp}',
                     'lib/*.{bundle,so,o,obj,pdb,lib,def,exp}',
                     'ext/unicorn/http11/Makefile',
                     'pkg', 'lib/*.bundle', '*.gem',
                     'site/output', '.config', 'coverage',
                     'test_*.log', 'log', 'doc']
  p.url = "http://unicorn.bogomips.org"
  p.ignore_pattern = /^(pkg|site|projects|doc|log)|CVS|\.log/
  p.need_tar_gz = false
  p.need_tgz = true

  p.extension_pattern = ["ext/**/extconf.rb"]

  # Eric hasn't bothered to figure out running exec tests properly
  # from Rake, but Eric prefers GNU make to Rake for tests anyways...
  p.test_pattern = [ 'test/unit/test*.rb' ]
end

#### Ragel builder

desc "Rebuild the Ragel sources"
task :ragel do
  Dir.chdir "ext/unicorn/http11" do
    target = "http11_parser.c"
    File.unlink target if File.exist? target
    sh "ragel http11_parser.rl -C -G2 -o #{target}"
    raise "Failed to build C source" unless File.exist? target
  end
end
