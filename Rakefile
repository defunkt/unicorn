# -*- encoding: binary -*-

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
        :tagger_name => %r{^tagger ([^<]+)}.match(tagger)[1],
        :tagger_email => %r{<([^>]+)>}.match(tagger)[1],
        :id => `git rev-parse refs/tags/#{tag}`.chomp!,
        :tag => tag,
        :subject => subject,
        :body => (old = old_summaries[tag]) ? "#{old}\n#{body}" : body,
      }
    end
  end.compact.sort { |a,b| b[:time] <=> a[:time] }
end

cgit_url = "http://git.bogomips.org/cgit/unicorn.git"

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
          content(:type => 'text') { tag[:body] }
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
  require 'rubygems'

  git_url = ENV['GIT_URL'] || 'git://git.bogomips.org/unicorn.git'

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
