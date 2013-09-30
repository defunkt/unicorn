# -*- encoding: binary -*-
autoload :Gem, 'rubygems'
require 'wrongdoc'

cgit_url = Wrongdoc.config[:cgit_url]
git_url = Wrongdoc.config[:git_url]

desc "post to FM"
task :fm_update do
  require 'tempfile'
  require 'net/http'
  require 'net/netrc'
  require 'json'
  version = ENV['VERSION'] or abort "VERSION= needed"
  uri = URI.parse('https://freecode.com/projects/unicorn/releases.json')
  rc = Net::Netrc.locate('unicorn-fm') or abort "~/.netrc not found"
  api_token = rc.password
  _, subject, body = `git cat-file tag v#{version}`.split(/\n\n/, 3)
  tmp = Tempfile.new('fm-changelog')
  tmp.puts subject
  tmp.puts
  tmp.puts body
  tmp.flush
  system(ENV["VISUAL"], tmp.path) or abort "#{ENV["VISUAL"]} failed: #$?"
  changelog = File.read(tmp.path).strip

  req = {
    "auth_code" => api_token,
    "release" => {
      "tag_list" => "Experimental",
      "version" => version,
      "changelog" => changelog,
    },
  }.to_json

  if ! changelog.strip.empty? && version =~ %r{\A[\d\.]+\d+\z}
    Net::HTTP.start(uri.host, uri.port, :use_ssl => true) do |http|
      p http.post(uri.path, req, {'Content-Type'=>'application/json'})
    end
  else
    warn "not updating freshmeat for v#{version}"
  end
end

# optional rake-compiler support in case somebody needs to cross compile
begin
  mk = "ext/unicorn_http/Makefile"
  if File.readable?(mk)
    warn "run 'gmake -C ext/unicorn_http clean' and\n" \
         "remove #{mk} before using rake-compiler"
  elsif ENV['VERSION']
    unless File.readable?("ext/unicorn_http/unicorn_http.c")
      abort "run 'gmake ragel' or 'make ragel' to generate the Ragel source"
    end
    spec = Gem::Specification.load('unicorn.gemspec')
    require 'rake/extensiontask'
    Rake::ExtensionTask.new('unicorn_http', spec)
  end
rescue LoadError
end
