# -*- encoding: binary -*-

ENV["VERSION"] or abort "VERSION= must be specified"
manifest = File.readlines('.manifest').map! { |x| x.chomp! }

# don't bother with tests that fork, not worth our time to get working
# with `gem check -t` ... (of course we care for them when testing with
# GNU make when they can run in parallel)
test_files = manifest.grep(%r{\Atest/unit/test_.*\.rb\z}).map do |f|
  File.readlines(f).grep(/\bfork\b/).empty? ? f : nil
end.compact

Gem::Specification.new do |s|
  s.name = %q{unicorn}
  s.version = ENV["VERSION"]

  s.authors = ["Unicorn hackers"]
  s.date = Time.now.utc.strftime('%Y-%m-%d')
  s.description = File.read("README").split(/\n\n/)[1].delete('\\')
  s.email = %q{mongrel-unicorn@rubyforge.org}
  s.executables = %w(unicorn unicorn_rails)
  s.extensions = %w(ext/unicorn_http/extconf.rb)

  s.extra_rdoc_files = File.readlines('.document').map! do |x|
    x.chomp!
    if File.directory?(x)
      manifest.grep(%r{\A#{x}/})
    elsif File.file?(x)
      x
    else
      nil
    end
  end.flatten.compact

  s.files = manifest
  s.homepage = %q{http://unicorn.bogomips.org/}

  summary = %q{Rack HTTP server for fast clients and Unix}
  s.rdoc_options = [ "-Na", "-t", "Unicorn: #{summary}" ]
  s.require_paths = %w(lib ext)
  s.rubyforge_project = %q{mongrel}
  s.summary = summary

  s.test_files = test_files

  # for people that are absolutely stuck on Rails 2.3.2 and can't
  # up/downgrade to any other version, the Rack dependency may be
  # commented out.  Nevertheless, upgrading to Rails 2.3.4 or later is
  # *strongly* recommended for security reasons.
  s.add_dependency(%q<rack>)

  s.add_development_dependency('isolate', '~> 2.0.2')

  # s.licenses = %w(GPLv2 Ruby) # licenses= method is not in older RubyGems
end
