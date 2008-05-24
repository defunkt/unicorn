
require 'rubygems'
gem 'echoe', '>=2.7.11'
require 'echoe'
require 'tools/freebasic'

# Task :package needs compile before doing the gem stuff.
# (weird behavior of Rake?)
task :package => [:compile]

echoe_spec = Echoe.new("mongrel_service") do |p|
  p.summary = "Mongrel Native Win32 Service Plugin for Rails"
  p.summary += " (debug build)" unless ENV['RELEASE'] 
  p.description = "This plugin offer native win32 services for rails, powered by Mongrel."
  p.author = "Luis Lavena"
  p.email = "luislavena@gmail.com"
  p.platform = Gem::Platform::CURRENT
  p.dependencies = [['gem_plugin', '>=0.2.3', '<0.3.0'],
                    ['mongrel', '>=1.0.2', '<1.2.0'],
                    ['win32-service', '>=0.5.2', '<0.6.0']]

  p.executable_pattern = ""
  
  p.need_tar_gz = false
  p.need_zip = true
  p.certificate_chain = [
    '~/projects/gem_certificates/mongrel-public_cert.pem',
    '~/projects/gem_certificates/luislavena-mongrel-public_cert.pem'
  ]
  p.require_signed = true
end

desc "Compile native code"
task :compile => [:native_lib, :native_service]

# global options shared by all the project in this Rakefile
OPTIONS = {
  :debug => false,
  :profile => false,
  :errorchecking => :ex,
  :mt => true,
  :pedantic => true }

OPTIONS[:debug] = true if ENV['DEBUG']
OPTIONS[:profile] = true if ENV['PROFILE']
OPTIONS[:errorchecking] = :exx if ENV['EXX']
OPTIONS[:pedantic] = false if ENV['NOPEDANTIC']

# ServiceFB namespace (lib)
namespace :lib do
  project_task 'servicefb' do
    lib       'ServiceFB'
    build_to  'lib'

    define    'SERVICEFB_DEBUG_LOG' unless ENV['RELEASE'] 
    source    'lib/ServiceFB/ServiceFB.bas'
    
    option    OPTIONS
  end
  
  project_task 'servicefb_utils' do
    lib       'ServiceFB_Utils'
    build_to  'lib'

    define    'SERVICEFB_DEBUG_LOG' unless ENV['RELEASE']
    source    'lib/ServiceFB/ServiceFB_Utils.bas'
    
    option    OPTIONS
  end
end

# add lib namespace to global tasks
#include_projects_of :lib
task :native_lib => "lib:build"
task :clean => "lib:clobber"

# mongrel_service (native)
namespace :native do
  project_task  'mongrel_service' do
    executable  'mongrel_service'
    build_to    'bin'
    
    define      'DEBUG_LOG' unless ENV['RELEASE']
    define      "GEM_VERSION=#{echoe_spec.version}"
    
    main        'native/mongrel_service.bas'
    source      'native/console_process.bas'
    
    lib_path    'lib'
    library     'ServiceFB', 'ServiceFB_Utils'
    library     'user32', 'advapi32', 'psapi'
    
    option      OPTIONS
  end
end

#include_projects_of :native
task :native_service => "native:build"
task :clean => "native:clobber"

project_task :mock_process do
  executable  :mock_process
  build_to    'tests'
  
  main        'tests/fixtures/mock_process.bas'
  
  option      OPTIONS
end 

task "all_tests:build" => "lib:build"
project_task :all_tests do
  executable  :all_tests
  build_to    'tests'
  
  search_path 'src', 'lib', 'native'
  lib_path    'lib'
  
  main        'tests/all_tests.bas'
  
  # this temporally fix the inverse namespace ctors of FB
  source      Dir.glob("tests/test_*.bas").reverse
  
  library     'testly'
  
  source      'native/console_process.bas'
  
  option      OPTIONS
end

desc "Run all the internal tests for the library"
task "all_tests:run" => ["mock_process:build", "all_tests:build"] do
  Dir.chdir('tests') do
    sh %{all_tests}
  end
end

desc "Run all the test for this project"
task :test => "all_tests:run"
