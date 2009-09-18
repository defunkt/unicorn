# -*- encoding: binary -*-
require 'mkmf'

dir_config("unicorn_http")

have_macro("SIZEOF_OFF_T", "ruby.h") or check_sizeof("off_t", "sys/types.h")
have_macro("SIZEOF_LONG", "ruby.h") or check_sizeof("long", "sys/types.h")
have_func("rb_str_set_len", "ruby.h")
have_func("rb_str_modify", "ruby.h")

# -fPIC is needed for Rubinius, MRI already uses it regardless
with_cflags($CFLAGS + " -fPIC ") do
  create_makefile("unicorn_http")
end
