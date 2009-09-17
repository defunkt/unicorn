# -*- encoding: binary -*-

# most tasks are in the GNUmakefile which offers better parallelism

desc 'prints RDoc-formatted history'
task :history do
  tags = `git tag -l`.split(/\n/).grep(/^v[\d\.]+$/).reverse
  timefmt = '%Y-%m-%d %H:%M UTC'

  old_summaries = File.readlines(".CHANGELOG.old").inject({}) do |hash, line|
    version, summary = line.split(/ - /, 2)
    hash[version] = summary
    hash
  end

  tags.each do |tag|
    header, subject, body = `git cat-file tag #{tag}`.split(/\n\n/, 3)
    tagger = header.split(/\n/).grep(/^tagger /).first.split(/\s/)
    time = Time.at(tagger[-2].to_i).utc
    puts "=== #{tag.sub(/^v/, '')} / #{time.strftime(timefmt)}"
    puts ""

    if old_summary = old_summaries[tag]
      print "  #{old_summary}\n"
    end

    puts body ? body.gsub(/^/sm, "  ").gsub(/[ \t]+$/sm, "") : "  initial"
    puts ""
  end
end

desc "print release changelog for Rubyforge"
task :release_changes do
  version = ENV['VERSION'] or abort "VERSION= needed"
  version = "v#{version}"
  tags = `git tag -l`.split(/\n/)
  prev = tags[tags.index(version) - 1]
  system('git', 'diff', '--stat', prev, version) or abort $?
  puts ""
  system('git', 'log', "#{prev}..#{version}") or abort $?
end

desc "print release notes for Rubyforge"
task :release_notes do
  require 'rubygems'

  git_url = ENV['GIT_URL'] ||
            `git config --get remote.origin.url 2>/dev/null`.chomp! ||
            'git://git.bogomips.org/unicorn.git'

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
