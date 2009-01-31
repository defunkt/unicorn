Dir.glob('test/unit/*').select { |path| path =~ /^test\/unit\/test_.*\.rb$/ }.each do |test_path|
  require test_path
end
