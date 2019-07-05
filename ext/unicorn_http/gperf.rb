#!/usr/bin/ruby -w
buf = STDIN.read # output of: gperf ext/unicorn_http/common_fields.gperf

# this is supposed to fail if it doesn't subsitute anything:
print buf.sub!(

# make sure all functions are static
/\nstruct \w+ \*\n(\w+_)?lookup/) {
  "\nstatic#$&"
}.

# gperf 3.0.3 (on FreeBSD 12.0) actually uses offsetof
gsub(
# gperf 3.0.x used "(int)(long)", 3.1 uses "(int)(size_t)",
#  input: {(int)(size_t)&((struct cf_pool_t *)0)->cf_pool_str3},
# output: {offsetof(struct cf_pool_t, cf_pool_str3)},
/{\(int\)\(\w+\)\&\(\((struct \w+) *\*\)0\)->(\w+)}/) {
  "{offsetof(#$1, #$2)}"
}.

# make sure everything is 64-bit safe and compilers don't truncate
gsub!(/\b(?:unsigned )?int\b/, 'size_t').

# This isn't need for %switch%, but we'll experiment with to see
# if it's necessary, or not.
# don't give compilers a reason to complain, (struct foo *)->name
# is size_t, so unused slots should be size_t:
gsub(/\{-1\}/, '{(size_t)-1}')
