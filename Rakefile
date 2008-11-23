
require 'rubygems'
require 'echoe'

Echoe.new("mongrel") do |p|
  p.summary = "A small fast HTTP library and server for Rack applications."
  p.author = "Evan Weaver"
  p.email = "evan@cloudbur.st"
  p.clean_pattern = ['ext/http11/*.{bundle,so,o,obj,pdb,lib,def,exp}', 'lib/*.{bundle,so,o,obj,pdb,lib,def,exp}', 'ext/http11/Makefile', 'pkg', 'lib/*.bundle', '*.gem', 'site/output', '.config', 'lib/http11.jar', 'ext/http11_java/classes', 'coverage', 'test_*.log', 'log', 'doc']
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

  unless Platform.windows? or Platform.java?
    p.extension_pattern = ["ext/**/extconf.rb"]
  end

  p.eval = proc do
    if Platform.windows?
      self.files += ['lib/http11.so']
      self.platform = Gem::Platform::CURRENT
    elsif Platform.java?
      self.files += ['lib/http11.jar']
      self.platform = 'jruby' # XXX Is this right?
    else
      add_dependency('daemons', '>= 1.0.3')
    end
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
  Dir.chdir "ext/http11" do
    target = "../../ext/http11_java/org/jruby/mongrel/Http11Parser.java"
    File.unlink target if File.exist? target
    sh "ragel http11_parser.rl -J -o #{target}"
    raise "Failed to build Java source" unless File.exist? target
  end
end

#### Pre-compiled extensions for alternative platforms

def move_extensions
  Dir["ext/**/*.#{Config::CONFIG['DLEXT']}"].each { |file| mv file, "lib/" }
end

def java_classpath_arg
  # A myriad of ways to discover the JRuby classpath
  classpath = begin
    require 'java'
    # Already running in a JRuby JVM
    Java::java.lang.System.getProperty('java.class.path')
  rescue LoadError
    ENV['JRUBY_PARENT_CLASSPATH'] || ENV['JRUBY_HOME'] && FileList["#{ENV['JRUBY_HOME']}/lib/*.jar"].join(File::PATH_SEPARATOR)
  end
  classpath ? "-cp #{classpath}" : ""
end

if Platform.windows?
  filename = "lib/http11.so"
  file filename do
    Dir.chdir("ext/http11") do
      ruby "extconf.rb"
      system(Platform.make)
    end
    move_extensions
  end
  task :compile => [filename]

elsif Platform.java?

  # Avoid JRuby in-process launching problem
  begin
    require 'jruby'
    JRuby.runtime.instance_config.run_ruby_in_process = false 
  rescue LoadError
  end

  filename = "lib/http11.jar"
  file filename do
    build_dir = "ext/http11_java/classes"
    mkdir_p build_dir
    sources = FileList['ext/http11_java/**/*.java'].join(' ')
    sh "javac -target 1.4 -source 1.4 -d #{build_dir} #{java_classpath_arg} #{sources}"
    sh "jar cf lib/http11.jar -C #{build_dir} ."
    move_extensions
  end
  task :compile => [filename]

end
