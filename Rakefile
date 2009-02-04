
require 'rubygems'
require 'echoe'

Echoe.new("mongrel") do |p|
  p.summary = "A small fast HTTP library and server for Rack applications."
  p.author = "Evan Weaver"
  p.email = "evan@cloudbur.st"
  p.clean_pattern = ['ext/http11/*.{bundle,so,o,obj,pdb,lib,def,exp}', 'lib/*.{bundle,so,o,obj,pdb,lib,def,exp}', 'ext/http11/Makefile', 'pkg', 'lib/*.bundle', '*.gem', 'site/output', '.config', 'coverage', 'test_*.log', 'log', 'doc']
  p.url = "http://mongrel.rubyforge.org"
  p.rdoc_pattern = ['README', 'LICENSE', 'CONTRIBUTORS', 'CHANGELOG', 'COPYING', 'lib/**/*.rb', 'doc/**/*.rdoc']
  p.docs_host = 'mongrel.cloudbur.st:/home/eweaver/www/mongrel/htdocs/web'
  p.ignore_pattern = /^(pkg|site|projects|doc|log)|CVS|\.log/
  p.extension_pattern = nil
  p.dependencies = ['daemons', 'rack']
  
  p.certificate_chain = case (ENV['USER'] || ENV['USERNAME']).downcase
    when 'eweaver' 
      ['~/p/configuration/gem_certificates/mongrel/mongrel-public_cert.pem',
       '~/p/configuration/gem_certificates/evan_weaver-mongrel-public_cert.pem']
    when 'luislavena', 'luis'
      ['~/projects/gem_certificates/mongrel-public_cert.pem',
        '~/projects/gem_certificates/luislavena-mongrel-public_cert.pem']    
  end
  
  p.need_tar_gz = false
  p.need_tgz = true

  p.extension_pattern = ["ext/**/extconf.rb"]

  p.eval = proc do
    add_dependency('daemons', '>= 1.0.3')
  end

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
