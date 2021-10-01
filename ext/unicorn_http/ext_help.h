#ifndef ext_help_h
#define ext_help_h

/* not all Ruby implementations support frozen objects (Rubinius does not) */
#if defined(OBJ_FROZEN)
#  define assert_frozen(f) assert(OBJ_FROZEN(f) && "unfrozen object")
#else
#  define assert_frozen(f) do {} while (0)
#endif /* !defined(OBJ_FROZEN) */

static inline int str_cstr_eq(VALUE val, const char *ptr, long len)
{
  return (RSTRING_LEN(val) == len && !memcmp(ptr, RSTRING_PTR(val), len));
}

#define STR_CSTR_EQ(val, const_str) \
  str_cstr_eq(val, const_str, sizeof(const_str) - 1)

/* strcasecmp isn't locale independent */
static int str_cstr_case_eq(VALUE val, const char *ptr, long len)
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

#endif /* ext_help_h */
