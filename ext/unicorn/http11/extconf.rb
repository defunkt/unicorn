require 'mkmf'

dir_config("unicorn/http11")
have_library("c", "main")
create_makefile("unicorn/http11")
