
require 'rubygems'
require 'echoe'

Echoe.new("unicorn") do |p|
  p.summary = "A small fast HTTP library and server for Rack applications."
  p.author = "Eric Wong"
  p.email = "normalperson@yhbt.net"
  p.clean_pattern = ['ext/http11/*.{bundle,so,o,obj,pdb,lib,def,exp}', 'lib/*.{bundle,so,o,obj,pdb,lib,def,exp}', 'ext/http11/Makefile', 'pkg', 'lib/*.bundle', '*.gem', 'site/output', '.config', 'coverage', 'test_*.log', 'log', 'doc']
  p.url = "http://unicorn.bogomips.org"
  p.rdoc_pattern = ['README', 'LICENSE', 'CONTRIBUTORS', 'CHANGELOG', 'COPYING', 'lib/**/*.rb', 'doc/**/*.rdoc']
  p.ignore_pattern = /^(pkg|site|projects|doc|log)|CVS|\.log/
  p.extension_pattern = nil

  p.need_tar_gz = false
  p.need_tgz = true

  p.extension_pattern = ["ext/**/extconf.rb"]

end

#### Ragel builder

desc "Rebuild the Ragel sources"
task :ragel do
  Dir.chdir "ext/http11" do
    target = "http11_parser.c"
    File.unlink target if File.exist? target
    sh "ragel http11_parser.rl -C -G2 -o #{target}"
    raise "Failed to build C source" unless File.exist? target
  end
end

#### Pre-compiled extensions for alternative platforms

def move_extensions
  Dir["ext/**/*.#{Config::CONFIG['DLEXT']}"].each { |file| mv file, "lib/" }
end
