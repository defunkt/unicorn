require 'mkmf'

version_components = RUBY_VERSION.split('.').map { |c| c.to_i }

need_fastthread = ( !defined? RUBY_ENGINE )
need_fastthread &= ( RUBY_PLATFORM != 'java' )
need_fastthread &= ( version_components[0..1] == [1, 8] && ( version_components[2] < 6 || version_components[2] == 6 && RUBY_PATCHLEVEL < 111 ) )

if need_fastthread
  create_makefile('fastthread')
else
  File.open('Makefile', 'w') do |stream|
    CONFIG.each do |key, value|
      stream.puts "#{key} = #{value}"
    end
    stream.puts
    stream << <<EOS
RUBYARCHDIR = $(sitearchdir)$(target_prefix)

default:

install:
	mkdir -p $(RUBYARCHDIR)
	touch $(RUBYARCHDIR)/fastthread.rb

EOS
  end
end
