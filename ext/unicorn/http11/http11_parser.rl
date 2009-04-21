/**
 * Copyright (c) 2005 Zed A. Shaw
 * You can redistribute it and/or modify it under the same terms as Ruby.
 */
#ifndef http11_parser_h
#define http11_parser_h

#include <sys/types.h>

static void http_field(void *data, const char *field,
                       size_t flen, const char *value, size_t vlen);
static void request_method(void *data, const char *at, size_t length);
static void scheme(void *data, const char *at, size_t length);
static void host(void *data, const char *at, size_t length);
static void request_uri(void *data, const char *at, size_t length);
static void fragment(void *data, const char *at, size_t length);
static void request_path(void *data, const char *at, size_t length);
static void query_string(void *data, const char *at, size_t length);
static void http_version(void *data, const char *at, size_t length);
static void header_done(void *data, const char *at, size_t length);

typedef struct http_parser {
  int cs;
  size_t body_start;
  size_t nread;
  size_t mark;
  size_t field_start;
  size_t field_len;
  size_t query_start;

  void *data;
} http_parser;

static int http_parser_has_error(http_parser *parser);
static int http_parser_is_finished(http_parser *parser);

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

  action start_field { MARK(field_start, fpc); }
  action snake_upcase_field { snake_upcase_char((char *)fpc); }
  action downcase_char { downcase_char((char *)fpc); }
  action write_field {
    parser->field_len = LEN(field_start, fpc);
  }

  action start_value { MARK(mark, fpc); }
  action write_value {
    http_field(parser->data, PTR_TO(field_start), parser->field_len, PTR_TO(mark), LEN(mark, fpc));
  }
  action request_method {
    request_method(parser->data, PTR_TO(mark), LEN(mark, fpc));
  }
  action scheme { scheme(parser->data, PTR_TO(mark), LEN(mark, fpc)); }
  action host { host(parser->data, PTR_TO(mark), LEN(mark, fpc)); }
  action request_uri {
    request_uri(parser->data, PTR_TO(mark), LEN(mark, fpc));
  }
  action fragment {
    fragment(parser->data, PTR_TO(mark), LEN(mark, fpc));
  }

  action start_query {MARK(query_start, fpc); }
  action query_string {
    query_string(parser->data, PTR_TO(query_start), LEN(query_start, fpc));
  }

  action http_version {
    http_version(parser->data, PTR_TO(mark), LEN(mark, fpc));
  }

  action request_path {
    request_path(parser->data, PTR_TO(mark), LEN(mark,fpc));
  }

  action done {
    parser->body_start = fpc - buffer + 1;
    header_done(parser->data, fpc + 1, pe - fpc - 1);
    fbreak;
  }

  include http_parser_common "http11_parser_common.rl";
}%%

/** Data **/
%% write data;

static void http_parser_init(http_parser *parser) {
  int cs = 0;
  memset(parser, 0, sizeof(*parser));
  %% write init;
  parser->cs = cs;
}

/** exec **/
static void http_parser_execute(
  http_parser *parser, const char *buffer, size_t len)
{
  const char *p, *pe;
  int cs = parser->cs;
  size_t off = parser->nread;

  assert(off <= len && "offset past end of buffer");

  p = buffer+off;
  pe = buffer+len;

  assert(*pe == '\0' && "pointer does not end on NUL");
  assert(pe - p == len - off && "pointers aren't same distance");

  %% write exec;

  if (!http_parser_has_error(parser))
    parser->cs = cs;
  parser->nread += p - (buffer + off);

  assert(p <= pe && "buffer overflow after parsing execute");
  assert(parser->nread <= len && "nread longer than length");
  assert(parser->body_start <= len && "body starts after buffer end");
  assert(parser->mark < len && "mark is after buffer end");
  assert(parser->field_len <= len && "field has length longer than whole buffer");
  assert(parser->field_start < len && "field starts after buffer end");
}

static int http_parser_has_error(http_parser *parser) {
  return parser->cs == http_parser_error;
}

static int http_parser_is_finished(http_parser *parser) {
  return parser->cs == http_parser_first_final;
}
#endif /* http11_parser_h */
