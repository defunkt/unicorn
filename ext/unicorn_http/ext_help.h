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

static inline int str_cstr_eq(VALUE val, const char *ptr, size_t len)
{
  return (RSTRING_LEN(val) == len && !memcmp(ptr, RSTRING_PTR(val), len));
}

#define STR_CSTR_EQ(val, const_str) \
  str_cstr_eq(val, const_str, sizeof(const_str) - 1)

/* strcasecmp isn't locale independent */
static int str_cstr_case_eq(VALUE val, const char *ptr, size_t len)
{
  if (RSTRING_LEN(val) == len) {
    const char *v = RSTRING_PTR(val);

    for (; len--; ++ptr, ++v) {
      if ((*ptr == *v) || (*v >= 'A' && *v <= 'Z' && (*v | 0x20) == *ptr))
        continue;
      return 0;
    }
    return 1;
  }
  return 0;
}

#define STR_CSTR_CASE_EQ(val, const_str) \
  str_cstr_case_eq(val, const_str, sizeof(const_str) - 1)

#endif
