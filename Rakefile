# -*- encoding: binary -*-

require 'rubygems'
require 'echoe'

Echoe.new("unicorn") do |p|
  p.summary = "Rack HTTP server for Unix, fast clients and nothing else"
  p.author = "Eric Wong"
  p.email = "normalperson@yhbt.net"
  p.clean_pattern = ['ext/unicorn_http/*.{bundle,so,o,obj,pdb,lib,def,exp}',
                     'lib/*.{bundle,so,o,obj,pdb,lib,def,exp}',
                     'ext/unicorn_http/Makefile',
                     'pkg', 'lib/*.bundle', '*.gem',
                     'site/output', '.config', 'coverage',
                     'test_*.log', 'log', 'doc']
  p.url = "http://unicorn.bogomips.org/"
  p.ignore_pattern = /^(pkg|site|projects|doc|log)|CVS|\.log/
  p.need_tar_gz = false
  p.need_tgz = true
  p.dependencies = [ 'rack' ]

  p.extension_pattern = ["ext/**/extconf.rb"]

  # Eric hasn't bothered to figure out running exec tests properly
  # from Rake, but Eric prefers GNU make to Rake for tests anyways...
  p.test_pattern = [ 'test/unit/test*.rb' ]
end

#### Ragel builder

desc "Rebuild the Ragel sources"
task :ragel do
  Dir.chdir "ext/unicorn_http" do
    target = "unicorn_http.c"
    File.unlink target if File.exist? target
    sh "ragel unicorn_http.rl -C -G2 -o #{target}"
    raise "Failed to build C source" unless File.exist? target
  end
end

desc 'prints RDoc-formatted history'
task :history do
  tags = `git tag -l`.split(/\n/).grep(/^v[\d\.]+$/).reverse
  timefmt = '%Y-%m-%d %H:%M UTC'
  tags.each do |tag|
    header, subject, body = `git cat-file tag #{tag}`.split(/\n\n/, 3)
    tagger = header.split(/\n/).grep(/^tagger /).first.split(/\s/)
    time = Time.at(tagger[-2].to_i).utc
    puts "=== #{tag.sub(/^v/, '')} / #{time.strftime(timefmt)}"
    puts ""
    puts body ? body.gsub(/^/sm, "  ") : "  initial"
    puts ""
  end
end
