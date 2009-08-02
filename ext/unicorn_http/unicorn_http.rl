/**
 * Copyright (c) 2009 Eric Wong (all bugs are Eric's fault)
 * Copyright (c) 2005 Zed A. Shaw
 * You can redistribute it and/or modify it under the same terms as Ruby.
 */
#include "ruby.h"
#include "ext_help.h"
#include <assert.h>
#include <string.h>
#include <sys/types.h>
#include "common_field_optimization.h"
#include "global_variables.h"
#include "c_util.h"

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

static void http_field(VALUE req, const char *field, size_t flen, VALUE val);
static void header_done(VALUE req, const char *at, size_t length);

#define LEN(AT, FPC) (FPC - buffer - hp->AT)
#define MARK(M,FPC) (hp->M = (FPC) - buffer)
#define PTR_TO(F) (buffer + hp->F)
#define STR_NEW(M,FPC) rb_str_new(PTR_TO(M), LEN(M, FPC))

/** Machine **/

%%{
  machine http_parser;

  action mark {MARK(mark, fpc); }

  action start_field { MARK(start.field, fpc); }
  action snake_upcase_field { snake_upcase_char((char *)fpc); }
  action downcase_char { downcase_char((char *)fpc); }
  action write_field { hp->field_len = LEN(start.field, fpc); }
  action start_value { MARK(mark, fpc); }
  action write_value {
    VALIDATE_MAX_LENGTH(LEN(mark, fpc), FIELD_VALUE);
    http_field(req, PTR_TO(start.field), hp->field_len, STR_NEW(mark, fpc));
  }
  action request_method {
    rb_hash_aset(req, g_request_method, STR_NEW(mark, fpc));
  }
  action scheme {
    rb_hash_aset(req, g_rack_url_scheme, STR_NEW(mark, fpc));
  }
  action host {
    rb_hash_aset(req, g_http_host, STR_NEW(mark, fpc));
  }
  action request_uri {
    size_t len = LEN(mark, fpc);
    VALIDATE_MAX_LENGTH(len, REQUEST_URI);
    rb_hash_aset(req, g_request_uri, STR_NEW(mark, fpc));
    /*
     * "OPTIONS * HTTP/1.1\r\n" is a valid request, but we can't have '*'
     * in REQUEST_PATH or PATH_INFO or else Rack::Lint will complain
     */
    if (len == 1 && *PTR_TO(mark) == '*') {
      VALUE val = rb_str_new(NULL, 0);
      rb_hash_aset(req, g_request_path, val);
      rb_hash_aset(req, g_path_info, val);
    }
  }
  action fragment {
    VALIDATE_MAX_LENGTH(LEN(mark, fpc), FRAGMENT);
    rb_hash_aset(req, g_fragment, STR_NEW(mark, fpc));
  }
  action start_query {MARK(start.query, fpc); }
  action query_string {
    VALIDATE_MAX_LENGTH(LEN(start.query, fpc), QUERY_STRING);
    rb_hash_aset(req, g_query_string, STR_NEW(start.query, fpc));
  }
  action http_version {
    rb_hash_aset(req, g_http_version, STR_NEW(mark, fpc));
  }
  action request_path {
    VALUE val;
    size_t len = LEN(mark, fpc);

    VALIDATE_MAX_LENGTH(len, REQUEST_PATH);
    val = STR_NEW(mark, fpc);

    rb_hash_aset(req, g_request_path, val);
    /* rack says PATH_INFO must start with "/" or be empty */
    if (!(len == 1 && *PTR_TO(mark) == '*'))
      rb_hash_aset(req, g_path_info, val);
  }
  action done {
    hp->start.body = fpc - buffer + 1;
    header_done(req, fpc + 1, pe - fpc - 1);
    fbreak;
  }

  include unicorn_http_common "unicorn_http_common.rl";
}%%

/** Data **/
%% write data;

static void http_parser_init(struct http_parser *hp)
{
  int cs = 0;
  memset(hp, 0, sizeof(struct http_parser));
  %% write init;
  hp->cs = cs;
}

/** exec **/
static void http_parser_execute(struct http_parser *hp,
  VALUE req, const char *buffer, size_t len)
{
  const char *p, *pe;
  int cs = hp->cs;
  size_t off = hp->start.offset;

  assert(off <= len && "offset past end of buffer");

  p = buffer+off;
  pe = buffer+len;

  assert(pe - p == len - off && "pointers aren't same distance");

  %% write exec;

  if (hp->cs != http_parser_error)
    hp->cs = cs;
  hp->start.offset = p - buffer;

  assert(p <= pe && "buffer overflow after parsing execute");
  assert(hp->start.offset <= len && "start.offset longer than length");
  assert(hp->mark < len && "mark is after buffer end");
  assert(hp->field_len <= len && "field has length longer than whole buffer");
}

static struct http_parser *data_get(VALUE self)
{
  struct http_parser *hp;

  Data_Get_Struct(self, struct http_parser, hp);
  assert(hp);
  return hp;
}

static void http_field(VALUE req, const char *field, size_t flen, VALUE val)
{
  VALUE f = find_common_field(field, flen);

  if (f == Qnil) {
    VALIDATE_MAX_LENGTH(flen, FIELD_NAME);
    f = uncommon_field(field, flen);
  } else if (f == g_http_host && rb_hash_aref(req, f) != Qnil) {
    return;
  }

  rb_hash_aset(req, f, val);
}

static int is_https(VALUE str)
{
  return RSTRING_LEN(str) == 5 && !memcmp("https", RSTRING_PTR(str), 5);
}

static void set_server_params(VALUE req)
{
  VALUE temp = rb_hash_aref(req, g_rack_url_scheme);
  VALUE server_name = g_localhost;
  VALUE server_port = g_port_80;

  /* set rack.url_scheme to "https" or "http", no others are allowed by Rack */
  if (temp == Qnil) {
    temp = rb_hash_aref(req, g_http_x_forwarded_proto);
    if (temp != Qnil && is_https(temp))
      server_port = g_port_443;
    else
      temp = g_http;
    rb_hash_aset(req, g_rack_url_scheme, temp);
  } else if (is_https(temp)) {
    server_port = g_port_443;
  }

  /* parse and set the SERVER_NAME and SERVER_PORT variables */
  temp = rb_hash_aref(req, g_http_host);
  if (temp != Qnil) {
    char *colon = memchr(RSTRING_PTR(temp), ':', RSTRING_LEN(temp));
    if (colon) {
      long port_start = colon - RSTRING_PTR(temp) + 1;

      server_name = rb_str_substr(temp, 0, colon - RSTRING_PTR(temp));
      if ((RSTRING_LEN(temp) - port_start) > 0)
        server_port = rb_str_substr(temp, port_start, RSTRING_LEN(temp));
    } else {
      server_name = temp;
    }
  }
  rb_hash_aset(req, g_server_name, server_name);
  rb_hash_aset(req, g_server_port, server_port);
}

/** Finalizes the request header to have a bunch of stuff that's needed. */
static void header_done(VALUE req, const char *at, size_t length)
{
  VALUE temp;

  /* rack requires QUERY_STRING */
  if (rb_hash_aref(req, g_query_string) == Qnil)
    rb_hash_aset(req, g_query_string, rb_str_new(NULL, 0));

  set_server_params(req);
  rb_hash_aset(req, g_server_protocol, g_server_protocol_value);

  /* grab the initial body and stuff it into the hash */
  temp = rb_hash_aref(req, g_request_method);
  if (temp != Qnil) {
    long len = RSTRING_LEN(temp);
    char *ptr = RSTRING_PTR(temp);

    if (memcmp(ptr, "HEAD", len) && memcmp(ptr, "GET", len))
      rb_hash_aset(req, sym_http_body, rb_str_new(at, length));
  }
}

static VALUE HttpParser_alloc(VALUE klass)
{
  struct http_parser *hp;
  return Data_Make_Struct(klass, struct http_parser, NULL, NULL, hp);
}


/**
 * call-seq:
 *    parser.new -> parser
 *
 * Creates a new parser.
 */
static VALUE HttpParser_init(VALUE self)
{
  http_parser_init(data_get(self));

  return self;
}


/**
 * call-seq:
 *    parser.reset -> nil
 *
 * Resets the parser to it's initial state so that you can reuse it
 * rather than making new ones.
 */
static VALUE HttpParser_reset(VALUE self)
{
  http_parser_init(data_get(self));

  return Qnil;
}


/**
 * call-seq:
 *    parser.execute(req, data) -> true/false
 *
 * Takes a Hash and a String of data, parses the String of data filling
 * in the Hash returning a boolean to indicate whether or not parsing
 * is finished.
 *
 * This function now throws an exception when there is a parsing error.
 * This makes the logic for working with the parser much easier.  You
 * will need to wrap the parser with an exception handling block.
 */

static VALUE HttpParser_execute(VALUE self, VALUE req, VALUE data)
{
  struct http_parser *hp = data_get(self);
  char *dptr = RSTRING_PTR(data);
  long dlen = RSTRING_LEN(data);

  if (hp->start.offset < dlen) {
    http_parser_execute(hp, req, dptr, dlen);

    VALIDATE_MAX_LENGTH(hp->start.offset, HEADER);

    if (hp->cs != http_parser_error)
      return hp->cs == http_parser_first_final ? Qtrue : Qfalse;

    rb_raise(eHttpParserError, "Invalid HTTP format, parsing fails.");
  }
  rb_raise(eHttpParserError, "Requested start is after data buffer end.");
}

#define SET_GLOBAL(var,str) do { \
  var = find_common_field(str, sizeof(str) - 1); \
  assert(var != Qnil); \
} while (0)

void Init_unicorn_http(void)
{
  init_globals();
  rb_define_alloc_func(cHttpParser, HttpParser_alloc);
  rb_define_method(cHttpParser, "initialize", HttpParser_init,0);
  rb_define_method(cHttpParser, "reset", HttpParser_reset,0);
  rb_define_method(cHttpParser, "execute", HttpParser_execute,2);
  init_common_fields();
  SET_GLOBAL(g_http_host, "HOST");
}
#undef SET_GLOBAL
