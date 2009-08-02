require 'mkmf'

dir_config("unicorn_http")
check_sizeof("off_t", "sys/types.h")
have_func("rb_str_set_len", "ruby.h")
create_makefile("unicorn_http")
