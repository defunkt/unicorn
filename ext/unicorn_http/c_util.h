/*
 * Generic C functions and macros go here, there are no dependencies
 * on Unicorn internal structures or the Ruby C API in here.
 */

#ifndef UH_util_h
#define UH_util_h

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
