# -*- encoding: binary -*-
ENV["VERSION"] or abort "VERSION= must be specified"
manifest = File.readlines('.manifest').map! { |x| x.chomp! }
require 'olddoc'
extend Olddoc::Gemspec
name, summary, title = readme_metadata

# don't bother with tests that fork, not worth our time to get working
# with `gem check -t` ... (of course we care for them when testing with
# GNU make when they can run in parallel)
test_files = manifest.grep(%r{\Atest/unit/test_.*\.rb\z}).map do |f|
  File.readlines(f).grep(/\bfork\b/).empty? ? f : nil
end.compact

Gem::Specification.new do |s|
  s.name = %q{unicorn}
  s.version = ENV["VERSION"].dup
  s.authors = ["#{name} hackers"]
  s.summary = summary
  s.description = readme_description
  s.email = %q{unicorn-public@bogomips.org}
  s.executables = %w(unicorn unicorn_rails)
  s.extensions = %w(ext/unicorn_http/extconf.rb)
  s.extra_rdoc_files = extra_rdoc_files(manifest)
  s.files = manifest
  s.homepage = Olddoc.config['rdoc_url']
  s.test_files = test_files

  # technically we need ">= 1.9.3", too, but avoid the array here since
  # old rubygems versions (1.8.23.2 at least) do not support multiple
  # version requirements here.
  s.required_ruby_version = '< 3.0'

  # We do not have a hard dependency on rack, it's possible to load
  # things which respond to #call.  HTTP status lines in responses
  # won't have descriptive text, only the numeric status.
  s.add_development_dependency(%q<rack>)

  s.add_dependency(%q<kgio>, '~> 2.6')
  s.add_dependency(%q<raindrops>, '~> 0.7')

  s.add_development_dependency('test-unit', '~> 3.0')
  s.add_development_dependency('olddoc', '~> 1.2')

  # Note: To avoid ambiguity, we intentionally avoid the SPDX-compatible
  # 'Ruby' here since Ruby 1.9.3 switched to BSD-2-Clause, but we
  # inherited our license from Mongrel when Ruby was at 1.8.
  # We cannot automatically switch licenses when Ruby changes.
  s.licenses = ['GPL-2.0+', 'Ruby-1.8']
end
