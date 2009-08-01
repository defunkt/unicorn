#ifndef ext_help_h
#define ext_help_h

#define ARRAY_SIZE(x) (sizeof(x)/sizeof(x[0]))

#ifndef RSTRING_PTR
#define RSTRING_PTR(s) (RSTRING(s)->ptr)
#endif
#ifndef RSTRING_LEN
#define RSTRING_LEN(s) (RSTRING(s)->len)
#endif

#endif
