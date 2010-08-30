# -*- encoding: binary -*-
autoload :Gem, 'rubygems'

# most tasks are in the GNUmakefile which offers better parallelism

def old_summaries
  @old_summaries ||= File.readlines(".CHANGELOG.old").inject({}) do |hash, line|
    version, summary = line.split(/ - /, 2)
    hash[version] = summary
    hash
  end
end

def tags
  timefmt = '%Y-%m-%dT%H:%M:%SZ'
  @tags ||= `git tag -l`.split(/\n/).map do |tag|
    next if tag == "v0.0.0"
    if %r{\Av[\d\.]+\z} =~ tag
      header, subject, body = `git cat-file tag #{tag}`.split(/\n\n/, 3)
      header = header.split(/\n/)
      tagger = header.grep(/\Atagger /).first
      body ||= "initial"
      {
        :time => Time.at(tagger.split(/ /)[-2].to_i).utc.strftime(timefmt),
        :tagger_name => %r{^tagger ([^<]+)}.match(tagger)[1].strip,
        :tagger_email => %r{<([^>]+)>}.match(tagger)[1].strip,
        :id => `git rev-parse refs/tags/#{tag}`.chomp!,
        :tag => tag,
        :subject => subject,
        :body => (old = old_summaries[tag]) ? "#{old}\n#{body}" : body,
      }
    end
  end.compact.sort { |a,b| b[:time] <=> a[:time] }
end

cgit_url = "http://git.bogomips.org/cgit/unicorn.git"
git_url = ENV['GIT_URL'] || 'git://git.bogomips.org/unicorn.git'

desc 'prints news as an Atom feed'
task :news_atom do
  require 'nokogiri'
  new_tags = tags[0,10]
  puts(Nokogiri::XML::Builder.new do
    feed :xmlns => "http://www.w3.org/2005/Atom" do
      id! "http://unicorn.bogomips.org/NEWS.atom.xml"
      title "Unicorn news"
      subtitle "Rack HTTP server for Unix and fast clients"
      link! :rel => 'alternate', :type => 'text/html',
            :href => 'http://unicorn.bogomips.org/NEWS.html'
      updated new_tags.first[:time]
      new_tags.each do |tag|
        entry do
          title tag[:subject]
          updated tag[:time]
          published tag[:time]
          author {
            name tag[:tagger_name]
            email tag[:tagger_email]
          }
          url = "#{cgit_url}/tag/?id=#{tag[:tag]}"
          link! :rel => "alternate", :type => "text/html", :href =>url
          id! url
          message_only = tag[:body].split(/\n.+\(\d+\):\n {6}/s).first.strip
          content({:type =>:text}, message_only)
          content(:type =>:xhtml) { pre tag[:body] }
        end
      end
    end
  end.to_xml)
end

desc 'prints RDoc-formatted news'
task :news_rdoc do
  tags.each do |tag|
    time = tag[:time].tr!('T', ' ').gsub!(/:\d\dZ/, ' UTC')
    puts "=== #{tag[:tag].sub(/^v/, '')} / #{time}"
    puts ""

    body = tag[:body]
    puts tag[:body].gsub(/^/sm, "  ").gsub(/[ \t]+$/sm, "")
    puts ""
  end
end

desc "print release changelog for Rubyforge"
task :release_changes do
  version = ENV['VERSION'] or abort "VERSION= needed"
  version = "v#{version}"
  vtags = tags.map { |tag| tag[:tag] =~ /\Av/ and tag[:tag] }.sort
  prev = vtags[vtags.index(version) - 1]
  system('git', 'diff', '--stat', prev, version) or abort $?
  puts ""
  system('git', 'log', "#{prev}..#{version}") or abort $?
end

desc "print release notes for Rubyforge"
task :release_notes do
  spec = Gem::Specification.load('unicorn.gemspec')
  puts spec.description.strip
  puts ""
  puts "* #{spec.homepage}"
  puts "* #{spec.email}"
  puts "* #{git_url}"

  _, _, body = `git cat-file tag v#{spec.version}`.split(/\n\n/, 3)
  print "\nChanges:\n\n"
  puts body
end

desc "post to RAA"
task :raa_update do
  require 'net/http'
  require 'net/netrc'
  rc = Net::Netrc.locate('unicorn-raa') or abort "~/.netrc not found"
  password = rc.password

  s = Gem::Specification.load('unicorn.gemspec')
  desc = [ s.description.strip ]
  desc << ""
  desc << "* #{s.email}"
  desc << "* #{git_url}"
  desc << "* #{cgit_url}"
  desc = desc.join("\n")
  uri = URI.parse('http://raa.ruby-lang.org/regist.rhtml')
  form = {
    :name => s.name,
    :short_description => s.summary,
    :version => s.version.to_s,
    :status => 'stable',
    :owner => s.authors.first,
    :email => s.email,
    :category_major => 'Library',
    :category_minor => 'Web',
    :url => s.homepage,
    :download => "http://rubyforge.org/frs/?group_id=1306",
    :license => "Ruby's",
    :description_style => 'Plain',
    :description => desc,
    :pass => password,
    :submit => "Update",
  }
  res = Net::HTTP.post_form(uri, form)
  p res
  puts res.body
end

desc "post to FM"
task :fm_update do
  require 'tempfile'
  require 'net/http'
  require 'net/netrc'
  require 'json'
  version = ENV['VERSION'] or abort "VERSION= needed"
  uri = URI.parse('http://freshmeat.net/projects/unicorn/releases.json')
  rc = Net::Netrc.locate('unicorn-fm') or abort "~/.netrc not found"
  api_token = rc.password
  changelog = tags.find { |t| t[:tag] == "v#{version}" }[:body]
  tmp = Tempfile.new('fm-changelog')
  tmp.syswrite(changelog)
  system(ENV["VISUAL"], tmp.path) or abort "#{ENV["VISUAL"]} failed: #$?"
  changelog = File.read(tmp.path).strip

  req = {
    "auth_code" => api_token,
    "release" => {
      "tag_list" => "Stable",
      "version" => version,
      "changelog" => changelog,
    },
  }.to_json
  Net::HTTP.start(uri.host, uri.port) do |http|
    p http.post(uri.path, req, {'Content-Type'=>'application/json'})
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

task :isolate do
  require 'isolate'
  ruby_engine = defined?(RUBY_ENGINE) ? RUBY_ENGINE : 'ruby'
  opts = {
    :system => false,
    :path => "tmp/isolate/#{ruby_engine}-#{RUBY_VERSION}",
    :multiruby => false, # we want "1.8.7" instead of "1.8"
  }
  fp = File.open(__FILE__, "rb")
  fp.flock(File::LOCK_EX)

  # C extensions aren't binary-compatible across Ruby versions
  pid = fork { Isolate.now!(opts) { gem 'sqlite3-ruby', '1.2.5' } }
  _, status = Process.waitpid2(pid)
  status.success? or abort status.inspect

  # pure Ruby gems can be shared across all Rubies
  %w(3.0.0).each do |rails_ver|
    opts[:path] = "tmp/isolate/rails-#{rails_ver}"
    pid = fork { Isolate.now!(opts) { gem 'rails', rails_ver } }
    _, status = Process.waitpid2(pid)
    status.success? or abort status.inspect
  end
  fp.flock(File::LOCK_UN)
end
