require 'mkmf'

dir_config("unicorn_http")

have_macro("SIZEOF_OFF_T", "ruby.h") or check_sizeof("off_t", "sys/types.h")
have_func("rb_str_set_len", "ruby.h")
create_makefile("unicorn_http")
