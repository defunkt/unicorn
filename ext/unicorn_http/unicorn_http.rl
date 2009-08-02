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

static int http_parser_has_error(struct http_parser *parser);
static int http_parser_is_finished(struct http_parser *parser);


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
  action write_field { parser->field_len = LEN(start.field, fpc); }
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

static void http_parser_init(struct http_parser *parser)
{
  int cs = 0;
  memset(parser, 0, sizeof(*parser));
  %% write init;
  parser->cs = cs;
}

/** exec **/
static void http_parser_execute(struct http_parser *parser,
  VALUE req, const char *buffer, size_t len)
{
  const char *p, *pe;
  int cs = parser->cs;
  size_t off = parser->start.offset;

  assert(off <= len && "offset past end of buffer");

  p = buffer+off;
  pe = buffer+len;

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

static int http_parser_has_error(struct http_parser *parser)
{
  return parser->cs == http_parser_error;
}

static int http_parser_is_finished(struct http_parser *parser)
{
  return parser->cs == http_parser_first_final;
}

static struct http_parser *data_get(VALUE self)
{
  struct http_parser *http;

  Data_Get_Struct(self, struct http_parser, http);
  assert(http);
  return http;
}

static void http_field(VALUE req, const char *field,
                       size_t flen, const char *value, size_t vlen)
{
  VALUE f = Qnil;

  VALIDATE_MAX_LENGTH(flen, FIELD_NAME);
  VALIDATE_MAX_LENGTH(vlen, FIELD_VALUE);

  f = find_common_field(field, flen);

  if (f == Qnil) {
    /*
     * We got a strange header that we don't have a memoized value for.
     * Fallback to creating a new string to use as a hash key.
     *
     * using rb_str_new(NULL, len) here is faster than rb_str_buf_new(len)
     * in my testing, because: there's no minimum allocation length (and
     * no check for it, either), RSTRING_LEN(f) does not need to be
     * written twice, and and RSTRING_PTR(f) will already be
     * null-terminated for us.
     */
    f = rb_str_new(NULL, HTTP_PREFIX_LEN + flen);
    memcpy(RSTRING_PTR(f), HTTP_PREFIX, HTTP_PREFIX_LEN);
    memcpy(RSTRING_PTR(f) + HTTP_PREFIX_LEN, field, flen);
    assert(*(RSTRING_PTR(f) + RSTRING_LEN(f)) == '\0'); /* paranoia */
    /* fprintf(stderr, "UNKNOWN HEADER <%s>\n", RSTRING_PTR(f)); */
  } else if (f == g_http_host && rb_hash_aref(req, f) != Qnil) {
    return;
  }

  rb_hash_aset(req, f, rb_str_new(value, vlen));
}

static void request_method(VALUE req, const char *at, size_t length)
{
  rb_hash_aset(req, g_request_method, rb_str_new(at, length));
}

static void scheme(VALUE req, const char *at, size_t length)
{
  rb_hash_aset(req, g_rack_url_scheme, rb_str_new(at, length));
}

static void host(VALUE req, const char *at, size_t length)
{
  rb_hash_aset(req, g_http_host, rb_str_new(at, length));
}

static void request_uri(VALUE req, const char *at, size_t length)
{
  VALIDATE_MAX_LENGTH(length, REQUEST_URI);

  rb_hash_aset(req, g_request_uri, rb_str_new(at, length));

  /* "OPTIONS * HTTP/1.1\r\n" is a valid request */
  if (length == 1 && *at == '*') {
    VALUE val = rb_str_new(NULL, 0);
    rb_hash_aset(req, g_request_path, val);
    rb_hash_aset(req, g_path_info, val);
  }
}

static void fragment(VALUE req, const char *at, size_t length)
{
  VALIDATE_MAX_LENGTH(length, FRAGMENT);

  rb_hash_aset(req, g_fragment, rb_str_new(at, length));
}

static void request_path(VALUE req, const char *at, size_t length)
{
  VALUE val = Qnil;

  VALIDATE_MAX_LENGTH(length, REQUEST_PATH);

  val = rb_str_new(at, length);
  rb_hash_aset(req, g_request_path, val);

  /* rack says PATH_INFO must start with "/" or be empty */
  if (!(length == 1 && *at == '*'))
    rb_hash_aset(req, g_path_info, val);
}

static void query_string(VALUE req, const char *at, size_t length)
{
  VALIDATE_MAX_LENGTH(length, QUERY_STRING);

  rb_hash_aset(req, g_query_string, rb_str_new(at, length));
}

static void http_version(VALUE req, const char *at, size_t length)
{
  rb_hash_aset(req, g_http_version, rb_str_new(at, length));
}

/** Finalizes the request header to have a bunch of stuff that's needed. */
static void header_done(VALUE req, const char *at, size_t length)
{
  VALUE server_name = g_localhost;
  VALUE server_port = g_port_80;
  VALUE temp;

  /* rack requires QUERY_STRING */
  if (rb_hash_aref(req, g_query_string) == Qnil)
    rb_hash_aset(req, g_query_string, rb_str_new(NULL, 0));

  /* set rack.url_scheme to "https" or "http", no others are allowed by Rack */
  if ((temp = rb_hash_aref(req, g_rack_url_scheme)) == Qnil) {
    if ((temp = rb_hash_aref(req, g_http_x_forwarded_proto)) != Qnil &&
        RSTRING_LEN(temp) == 5 &&
        !memcmp("https", RSTRING_PTR(temp), 5))
      server_port = g_port_443;
    else
      temp = g_http;
    rb_hash_aset(req, g_rack_url_scheme, temp);
  } else if (RSTRING_LEN(temp) == 5 && !memcmp("https", RSTRING_PTR(temp), 5)) {
    server_port = g_port_443;
  }

  /* parse and set the SERVER_NAME and SERVER_PORT variables */
  if ((temp = rb_hash_aref(req, g_http_host)) != Qnil) {
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
  struct http_parser *http;
  return Data_Make_Struct(klass, struct http_parser, NULL, NULL, http);
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
  struct http_parser *http = data_get(self);
  char *dptr = RSTRING_PTR(data);
  long dlen = RSTRING_LEN(data);

  if (http->start.offset < dlen) {
    http_parser_execute(http, req, dptr, dlen);

    VALIDATE_MAX_LENGTH(http->start.offset, HEADER);

    if (!http_parser_has_error(http))
      return http_parser_is_finished(http) ? Qtrue : Qfalse;

    rb_raise(eHttpParserError, "Invalid HTTP format, parsing fails.");
  }
  rb_raise(eHttpParserError, "Requested start is after data buffer end.");
}

void Init_unicorn_http(void)
{
  mUnicorn = rb_define_module("Unicorn");

  DEF_GLOBAL(rack_url_scheme, "rack.url_scheme");
  DEF_GLOBAL(request_method, "REQUEST_METHOD");
  DEF_GLOBAL(request_uri, "REQUEST_URI");
  DEF_GLOBAL(fragment, "FRAGMENT");
  DEF_GLOBAL(query_string, "QUERY_STRING");
  DEF_GLOBAL(http_version, "HTTP_VERSION");
  DEF_GLOBAL(request_path, "REQUEST_PATH");
  DEF_GLOBAL(path_info, "PATH_INFO");
  DEF_GLOBAL(server_name, "SERVER_NAME");
  DEF_GLOBAL(server_port, "SERVER_PORT");
  DEF_GLOBAL(server_protocol, "SERVER_PROTOCOL");
  DEF_GLOBAL(server_protocol_value, "HTTP/1.1");
  DEF_GLOBAL(http_x_forwarded_proto, "HTTP_X_FORWARDED_PROTO");
  DEF_GLOBAL(port_80, "80");
  DEF_GLOBAL(port_443, "443");
  DEF_GLOBAL(localhost, "localhost");
  DEF_GLOBAL(http, "http");

  eHttpParserError = rb_define_class_under(mUnicorn, "HttpParserError", rb_eIOError);

  cHttpParser = rb_define_class_under(mUnicorn, "HttpParser", rb_cObject);
  rb_define_alloc_func(cHttpParser, HttpParser_alloc);
  rb_define_method(cHttpParser, "initialize", HttpParser_init,0);
  rb_define_method(cHttpParser, "reset", HttpParser_reset,0);
  rb_define_method(cHttpParser, "execute", HttpParser_execute,2);
  sym_http_body = ID2SYM(rb_intern("http_body"));
  init_common_fields();
  g_http_host = find_common_field("HOST", 4);
  assert(g_http_host != Qnil);
}
