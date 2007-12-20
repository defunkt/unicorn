
require 'echoe'

Echoe.new("fastthread") do |p|
  p.project = "mongrel"
  p.author = "MenTaLguY <mental@rydia.net>"
  p.summary = "Optimized replacement for thread.rb primitives"
  p.extensions = "ext/fastthread/extconf.rb"
  p.clean_pattern = ['build/*', '**/*.o', '**/*.so', '**/*.a', 'lib/*-*', '**/*.log', "ext/fastthread/*.{bundle,so,obj,pdb,lib,def,exp}", "ext/fastthread/Makefile", "pkg", "lib/*.bundle", "*.gem", ".config"]

  p.need_tar_gz = false
  p.need_tgz = true
  # FIXME: find a workaround to have multiple key chains outside the Rakefile
  # tried GEM_CERTIFICATE_CHAIN but produces an asn1 error
  p.certificate_chain = [
    '~/projects/gem_certificates/mongrel-public_cert.pem',
    '~/projects/gem_certificates/luislavena-mongrel-public_cert.pem'
  ]
  #p.certificate_chain = ['/Users/eweaver/p/configuration/gem_certificates/mongrel/mongrel-public_cert.pem',
  #  '/Users/eweaver/p/configuration/gem_certificates/evan_weaver-mongrel-public_cert.pem']    
  p.require_signed = true

  p.eval = proc do  
    if RUBY_PLATFORM.match("win32")
      extensions.clear
      self.files += ['lib/fastthread.so']
      self.platform = Gem::Platform::CURRENT
      task :package => [:clean, :compile]
    end
  end
end

def move_extensions
  Dir["ext/**/*.#{Config::CONFIG['DLEXT']}"].each { |file| mv file, "lib/" }
end

case RUBY_PLATFORM
when /mswin/
  filename = "lib/fastthread.so"
  file filename do
    Dir.chdir("ext/fastthread") do
      ruby "extconf.rb"
      system(PLATFORM =~ /mswin/ ? 'nmake' : 'make')
    end
    move_extensions
  end
  task :compile => [filename]
end
