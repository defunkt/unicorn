# -*- encoding: binary -*-

ENV["VERSION"] or abort "VERSION= must be specified"
manifest = File.readlines('.manifest').map! { |x| x.chomp! }

Gem::Specification.new do |s|
  s.name = %q{unicorn}
  s.version = ENV["VERSION"]

  s.authors = ["Eric Wong"]
  s.date = Time.now.utc.strftime('%Y-%m-%d')
  s.description = File.read("README").split(/\n\n/)[1]
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

  s.rdoc_options = [ "-Na", "-t",
                     "Unicorn: Rack HTTP server for Unix and fast clients" ]
  s.require_paths = %w(lib ext)
  s.rubyforge_project = %q{mongrel}
  s.summary = %q{Rack HTTP server for Unix and fast clients}
  s.test_files = manifest.grep(%r{\Atest/unit/test_*\.rb\z})

  s.add_dependency(%q<rack>)
  s.licenses = %w(GPLv2 Ruby)
end
