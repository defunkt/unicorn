require 'mkmf'

dir_config("unicorn_http")
have_library("c", "main")
create_makefile("unicorn_http")
