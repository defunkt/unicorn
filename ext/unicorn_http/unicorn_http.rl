/**
 * Copyright (c) 2009 Eric Wong (all bugs are Eric's fault)
 * Copyright (c) 2005 Zed A. Shaw
 * You can redistribute it and/or modify it under the same terms as Ruby.
 */
#ifndef unicorn_http_h
#define unicorn_http_h

#include "ruby.h"
#include "ext_help.h"
#include <sys/types.h>

static void http_field(VALUE req, const char *field,
                       size_t flen, const char *value, size_t vlen);
static void request_method(VALUE req, const char *at, size_t length);
static void scheme(VALUE req, const char *at, size_t length);
static void host(VALUE req, const char *at, size_t length);
static void request_uri(VALUE req, const char *at, size_t length);
static void fragment(VALUE req, const char *at, size_t length);
static void request_path(VALUE req, const char *at, size_t length);
static void query_string(VALUE req, const char *at, size_t length);
static void http_version(VALUE req, const char *at, size_t length);
static void header_done(VALUE req, const char *at, size_t length);

struct http_parser {
  int cs;
  union {
    size_t body;
    size_t field;
    size_t query;
    size_t offset;
  } start;
  size_t mark;
  size_t field_len;
};

static int http_parser_has_error(struct http_parser *parser);
static int http_parser_is_finished(struct http_parser *parser);

/*
 * capitalizes all lower-case ASCII characters,
 * converts dashes to underscores.
 */
static void snake_upcase_char(char *c)
{
  if (*c >= 'a' && *c <= 'z')
    *c &= ~0x20;
  else if (*c == '-')
    *c = '_';
}

static void downcase_char(char *c)
{
  if (*c >= 'A' && *c <= 'Z')
    *c |= 0x20;
}

#define LEN(AT, FPC) (FPC - buffer - parser->AT)
#define MARK(M,FPC) (parser->M = (FPC) - buffer)
#define PTR_TO(F) (buffer + parser->F)

/** Machine **/

%%{
  machine http_parser;

  action mark {MARK(mark, fpc); }

  action start_field { MARK(start.field, fpc); }
  action snake_upcase_field { snake_upcase_char((char *)fpc); }
  action downcase_char { downcase_char((char *)fpc); }
  action write_field {
    parser->field_len = LEN(start.field, fpc);
  }

  action start_value { MARK(mark, fpc); }
  action write_value {
    http_field(req, PTR_TO(start.field), parser->field_len,
               PTR_TO(mark), LEN(mark, fpc));
  }
  action request_method { request_method(req, PTR_TO(mark), LEN(mark, fpc)); }
  action scheme { scheme(req, PTR_TO(mark), LEN(mark, fpc)); }
  action host { host(req, PTR_TO(mark), LEN(mark, fpc)); }
  action request_uri { request_uri(req, PTR_TO(mark), LEN(mark, fpc)); }
  action fragment { fragment(req, PTR_TO(mark), LEN(mark, fpc)); }

  action start_query {MARK(start.query, fpc); }
  action query_string {
    query_string(req, PTR_TO(start.query), LEN(start.query, fpc));
  }

  action http_version { http_version(req, PTR_TO(mark), LEN(mark, fpc)); }
  action request_path { request_path(req, PTR_TO(mark), LEN(mark,fpc)); }

  action done {
    parser->start.body = fpc - buffer + 1;
    header_done(req, fpc + 1, pe - fpc - 1);
    fbreak;
  }

  include unicorn_http_common "unicorn_http_common.rl";
}%%

/** Data **/
%% write data;

static void http_parser_init(struct http_parser *parser) {
  int cs = 0;
  memset(parser, 0, sizeof(*parser));
  %% write init;
  parser->cs = cs;
}

/** exec **/
static void http_parser_execute(
  struct http_parser *parser, VALUE req, const char *buffer, size_t len)
{
  const char *p, *pe;
  int cs = parser->cs;
  size_t off = parser->start.offset;

  assert(off <= len && "offset past end of buffer");

  p = buffer+off;
  pe = buffer+len;

  assert(*pe == '\0' && "pointer does not end on NUL");
  assert(pe - p == len - off && "pointers aren't same distance");

  %% write exec;

  if (!http_parser_has_error(parser))
    parser->cs = cs;
  parser->start.offset = p - buffer;

  assert(p <= pe && "buffer overflow after parsing execute");
  assert(parser->start.offset <= len && "start.offset longer than length");
  assert(parser->mark < len && "mark is after buffer end");
  assert(parser->field_len <= len && "field has length longer than whole buffer");
}

static int http_parser_has_error(struct http_parser *parser) {
  return parser->cs == http_parser_error;
}

static int http_parser_is_finished(struct http_parser *parser) {
  return parser->cs == http_parser_first_final;
}
#endif /* unicorn_http_h */
