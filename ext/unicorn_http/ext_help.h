#ifndef ext_help_h
#define ext_help_h

#ifndef RSTRING_PTR
#define RSTRING_PTR(s) (RSTRING(s)->ptr)
#endif
#ifndef RSTRING_LEN
#define RSTRING_LEN(s) (RSTRING(s)->len)
#endif

#ifndef HAVE_RB_STR_SET_LEN
/* this is taken from Ruby 1.8.7, 1.8.6 may not have it */
static void rb_18_str_set_len(VALUE str, long len)
{
  RSTRING(str)->len = len;
  RSTRING(str)->ptr[len] = '\0';
}
#  define rb_str_set_len(str,len) rb_18_str_set_len(str,len)
#endif

#endif
