#ifndef common_field_optimization
#define common_field_optimization
#include "ruby.h"
#include "c_util.h"

/*
 * A list of common HTTP headers we expect to receive.
 * This allows us to avoid repeatedly creating identical string
 * objects to be used with rb_hash_aset().
 */
#include "common_fields.h"

#define HTTP_PREFIX "HTTP_"
#define HTTP_PREFIX_LEN (sizeof(HTTP_PREFIX) - 1)
static ID id_uminus;

/* this dedupes under Ruby 2.5+ (December 2017) */
static VALUE str_dd_freeze(VALUE str)
{
  if (STR_UMINUS_DEDUPE)
    return rb_funcall(str, id_uminus, 0);

  /* freeze,since it speeds up older MRI slightly */
  OBJ_FREEZE(str);
  return str;
}

static VALUE str_new_dd_freeze(const char *ptr, long len)
{
  return str_dd_freeze(rb_str_new(ptr, len));
}

/* this function is not performance-critical, called only at load time */
static void init_common_fields(void)
{
  size_t i;
  char tmp[64];

  id_uminus = rb_intern("-@");
  memcpy(tmp, HTTP_PREFIX, HTTP_PREFIX_LEN);

  for (i = 0; i < ARRAY_SIZE(cf_wordlist); i++) {
    long len = (long)cf_lengthtable[i];
    struct common_field *cf = &cf_wordlist[i];
    const char *s;

    if (!len)
      continue;

    s = cf->name + cf_stringpool;
    /* Rack doesn't like certain headers prefixed with "HTTP_" */
    if (!strcmp("CONTENT_LENGTH", s) || !strcmp("CONTENT_TYPE", s)) {
      cf->value = str_new_dd_freeze(s, len);
    } else {
      memcpy(tmp + HTTP_PREFIX_LEN, s, len + 1);
      cf->value = str_new_dd_freeze(tmp, HTTP_PREFIX_LEN + len);
    }
    rb_gc_register_mark_object(cf->value);
  }
}

/* this function is called for every header set */
static VALUE find_common_field(const char *field, size_t flen)
{
  struct common_field *cf = cf_lookup(field, flen);

  if (cf) {
    assert(cf->value);
    return cf->value;
  }
  return Qnil;
}

/*
 * We got a strange header that we don't have a memoized value for.
 * Fallback to creating a new string to use as a hash key.
 */
static VALUE uncommon_field(const char *field, size_t flen)
{
  VALUE f = rb_str_new(NULL, HTTP_PREFIX_LEN + flen);
  memcpy(RSTRING_PTR(f), HTTP_PREFIX, HTTP_PREFIX_LEN);
  memcpy(RSTRING_PTR(f) + HTTP_PREFIX_LEN, field, flen);
  assert(*(RSTRING_PTR(f) + RSTRING_LEN(f)) == '\0' &&
         "string didn't end with \\0"); /* paranoia */
  return HASH_ASET_DEDUPE ? f : str_dd_freeze(f);
}

#endif /* common_field_optimization_h */
