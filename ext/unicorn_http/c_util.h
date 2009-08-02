/*
 * Generic C functions and macros go here, there are no dependencies
 * on Unicorn internal structures or the Ruby C API in here.
 */

#ifndef UH_util_h
#define UH_util_h

#define ARRAY_SIZE(x) (sizeof(x)/sizeof(x[0]))

#ifndef SIZEOF_OFF_T
#  define SIZEOF_OFF_T 4
#  warning SIZEOF_OFF_T not defined, guessing 4.  Did you run extconf.rb?
#endif

#if SIZEOF_OFF_T == 4
#  define UH_OFF_T_MAX 0x7fffffff
#elif SIZEOF_OFF_T == 8
#  define UH_OFF_T_MAX 0x7fffffffffffffff
#else
#  error off_t size unknown for this platform!
#endif

/*
 * capitalizes all lower-case ASCII characters and converts dashes
 * to underscores for HTTP headers.  Locale-agnostic.
 */
static void snake_upcase_char(char *c)
{
  if (*c >= 'a' && *c <= 'z')
    *c &= ~0x20;
  else if (*c == '-')
    *c = '_';
}

/* Downcases a single ASCII character.  Locale-agnostic. */
static void downcase_char(char *c)
{
  if (*c >= 'A' && *c <= 'Z')
    *c |= 0x20;
}

#endif /* UH_util_h */
