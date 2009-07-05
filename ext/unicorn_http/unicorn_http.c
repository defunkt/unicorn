/**
 * Copyright (c) 2009 Eric Wong (all bugs are Eric's fault)
 * Copyright (c) 2005 Zed A. Shaw
 * You can redistribute it and/or modify it under the same terms as Ruby.
 */
#include "ruby.h"
#include "ext_help.h"
#include <assert.h>
#include <string.h>
#include "unicorn_http.h"

static http_parser *data_get(VALUE self)
{
  http_parser *http;

  Data_Get_Struct(self, http_parser, http);
  if (!http)
    rb_raise(rb_eArgError, "NULL found for http when shouldn't be.");
  return http;
}

#ifndef RSTRING_PTR
#define RSTRING_PTR(s) (RSTRING(s)->ptr)
#endif
#ifndef RSTRING_LEN
#define RSTRING_LEN(s) (RSTRING(s)->len)
#endif

static VALUE mUnicorn;
static VALUE cHttpParser;
static VALUE eHttpParserError;
static VALUE sym_http_body;

#define HTTP_PREFIX "HTTP_"
#define HTTP_PREFIX_LEN (sizeof(HTTP_PREFIX) - 1)

static VALUE global_rack_url_scheme;
static VALUE global_request_method;
static VALUE global_request_uri;
static VALUE global_fragment;
static VALUE global_query_string;
static VALUE global_http_version;
static VALUE global_request_path;
static VALUE global_path_info;
static VALUE global_server_name;
static VALUE global_server_port;
static VALUE global_server_protocol;
static VALUE global_server_protocol_value;
static VALUE global_http_host;
static VALUE global_http_x_forwarded_proto;
static VALUE global_port_80;
static VALUE global_port_443;
static VALUE global_localhost;
static VALUE global_http;

/** Defines common length and error messages for input length validation. */
#define DEF_MAX_LENGTH(N, length) \
  static const size_t MAX_##N##_LENGTH = length; \
  static const char * const MAX_##N##_LENGTH_ERR = \
    "HTTP element " # N  " is longer than the " # length " allowed length."

/**
 * Validates the max length of given input and throws an HttpParserError
 * exception if over.
 */
#define VALIDATE_MAX_LENGTH(len, N) do { \
  if (len > MAX_##N##_LENGTH) \
    rb_raise(eHttpParserError, MAX_##N##_LENGTH_ERR); \
} while (0)

/** Defines global strings in the init method. */
#define DEF_GLOBAL(N, val) do { \
  global_##N = rb_obj_freeze(rb_str_new(val, sizeof(val) - 1)); \
  rb_global_variable(&global_##N); \
} while (0)

/* Defines the maximum allowed lengths for various input elements.*/
DEF_MAX_LENGTH(FIELD_NAME, 256);
DEF_MAX_LENGTH(FIELD_VALUE, 80 * 1024);
DEF_MAX_LENGTH(REQUEST_URI, 1024 * 12);
DEF_MAX_LENGTH(FRAGMENT, 1024); /* Don't know if this length is specified somewhere or not */
DEF_MAX_LENGTH(REQUEST_PATH, 1024);
DEF_MAX_LENGTH(QUERY_STRING, (1024 * 10));
DEF_MAX_LENGTH(HEADER, (1024 * (80 + 32)));

struct common_field {
	const signed long len;
	const char *name;
	VALUE value;
};

/*
 * A list of common HTTP headers we expect to receive.
 * This allows us to avoid repeatedly creating identical string
 * objects to be used with rb_hash_aset().
 */
static struct common_field common_http_fields[] = {
# define f(N) { (sizeof(N) - 1), N, Qnil }
	f("ACCEPT"),
	f("ACCEPT_CHARSET"),
	f("ACCEPT_ENCODING"),
	f("ACCEPT_LANGUAGE"),
	f("ALLOW"),
	f("AUTHORIZATION"),
	f("CACHE_CONTROL"),
	f("CONNECTION"),
	f("CONTENT_ENCODING"),
	f("CONTENT_LENGTH"),
	f("CONTENT_TYPE"),
	f("COOKIE"),
	f("DATE"),
	f("EXPECT"),
	f("FROM"),
	f("HOST"),
	f("IF_MATCH"),
	f("IF_MODIFIED_SINCE"),
	f("IF_NONE_MATCH"),
	f("IF_RANGE"),
	f("IF_UNMODIFIED_SINCE"),
	f("KEEP_ALIVE"), /* Firefox sends this */
	f("MAX_FORWARDS"),
	f("PRAGMA"),
	f("PROXY_AUTHORIZATION"),
	f("RANGE"),
	f("REFERER"),
	f("TE"),
	f("TRAILER"),
	f("TRANSFER_ENCODING"),
	f("UPGRADE"),
	f("USER_AGENT"),
	f("VIA"),
	f("X_FORWARDED_FOR"), /* common for proxies */
	f("X_FORWARDED_PROTO"), /* common for proxies */
	f("X_REAL_IP"), /* common for proxies */
	f("WARNING")
# undef f
};

/* this function is not performance-critical */
static void init_common_fields(void)
{
  int i;
  struct common_field *cf = common_http_fields;
  char tmp[256]; /* MAX_FIELD_NAME_LENGTH */
  memcpy(tmp, HTTP_PREFIX, HTTP_PREFIX_LEN);

  for(i = 0; i < ARRAY_SIZE(common_http_fields); cf++, i++) {
    /* Rack doesn't like certain headers prefixed with "HTTP_" */
    if (!strcmp("CONTENT_LENGTH", cf->name) ||
        !strcmp("CONTENT_TYPE", cf->name)) {
      cf->value = rb_str_new(cf->name, cf->len);
    } else {
      memcpy(tmp + HTTP_PREFIX_LEN, cf->name, cf->len + 1);
      cf->value = rb_str_new(tmp, HTTP_PREFIX_LEN + cf->len);
    }
    cf->value = rb_obj_freeze(cf->value);
    rb_global_variable(&cf->value);
  }
}

static VALUE find_common_field_value(const char *field, size_t flen)
{
  int i;
  struct common_field *cf = common_http_fields;
  for(i = 0; i < ARRAY_SIZE(common_http_fields); i++, cf++) {
    if (cf->len == flen && !memcmp(cf->name, field, flen))
      return cf->value;
  }
  return Qnil;
}

static void http_field(void *data, const char *field,
                       size_t flen, const char *value, size_t vlen)
{
  VALUE req = (VALUE)data;
  VALUE f = Qnil;

  VALIDATE_MAX_LENGTH(flen, FIELD_NAME);
  VALIDATE_MAX_LENGTH(vlen, FIELD_VALUE);

  f = find_common_field_value(field, flen);

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
  } else if (f == global_http_host && rb_hash_aref(req, f) != Qnil) {
    return;
  }

  rb_hash_aset(req, f, rb_str_new(value, vlen));
}

static void request_method(void *data, const char *at, size_t length)
{
  VALUE req = (VALUE)data;
  VALUE val = Qnil;

  val = rb_str_new(at, length);
  rb_hash_aset(req, global_request_method, val);
}

static void scheme(void *data, const char *at, size_t length)
{
  rb_hash_aset((VALUE)data, global_rack_url_scheme, rb_str_new(at, length));
}

static void host(void *data, const char *at, size_t length)
{
  rb_hash_aset((VALUE)data, global_http_host, rb_str_new(at, length));
}

static void request_uri(void *data, const char *at, size_t length)
{
  VALUE req = (VALUE)data;
  VALUE val = Qnil;

  VALIDATE_MAX_LENGTH(length, REQUEST_URI);

  val = rb_str_new(at, length);
  rb_hash_aset(req, global_request_uri, val);

  /* "OPTIONS * HTTP/1.1\r\n" is a valid request */
  if (length == 1 && *at == '*') {
    val = rb_str_new(NULL, 0);
    rb_hash_aset(req, global_request_path, val);
    rb_hash_aset(req, global_path_info, val);
  }
}

static void fragment(void *data, const char *at, size_t length)
{
  VALUE req = (VALUE)data;
  VALUE val = Qnil;

  VALIDATE_MAX_LENGTH(length, FRAGMENT);

  val = rb_str_new(at, length);
  rb_hash_aset(req, global_fragment, val);
}

static void request_path(void *data, const char *at, size_t length)
{
  VALUE req = (VALUE)data;
  VALUE val = Qnil;

  VALIDATE_MAX_LENGTH(length, REQUEST_PATH);

  val = rb_str_new(at, length);
  rb_hash_aset(req, global_request_path, val);

  /* rack says PATH_INFO must start with "/" or be empty */
  if (!(length == 1 && *at == '*'))
    rb_hash_aset(req, global_path_info, val);
}

static void query_string(void *data, const char *at, size_t length)
{
  VALUE req = (VALUE)data;
  VALUE val = Qnil;

  VALIDATE_MAX_LENGTH(length, QUERY_STRING);

  val = rb_str_new(at, length);
  rb_hash_aset(req, global_query_string, val);
}

static void http_version(void *data, const char *at, size_t length)
{
  VALUE req = (VALUE)data;
  VALUE val = rb_str_new(at, length);
  rb_hash_aset(req, global_http_version, val);
}

/** Finalizes the request header to have a bunch of stuff that's needed. */
static void header_done(void *data, const char *at, size_t length)
{
  VALUE req = (VALUE)data;
  VALUE server_name = global_localhost;
  VALUE server_port = global_port_80;
  VALUE temp;

  /* rack requires QUERY_STRING */
  if (rb_hash_aref(req, global_query_string) == Qnil)
    rb_hash_aset(req, global_query_string, rb_str_new(NULL, 0));

  /* set rack.url_scheme to "https" or "http", no others are allowed by Rack */
  if ((temp = rb_hash_aref(req, global_rack_url_scheme)) == Qnil) {
    if ((temp = rb_hash_aref(req, global_http_x_forwarded_proto)) != Qnil &&
        RSTRING_LEN(temp) == 5 &&
        !memcmp("https", RSTRING_PTR(temp), 5))
      server_port = global_port_443;
    else
      temp = global_http;
    rb_hash_aset(req, global_rack_url_scheme, temp);
  } else if (RSTRING_LEN(temp) == 5 && !memcmp("https", RSTRING_PTR(temp), 5)) {
    server_port = global_port_443;
  }

  /* parse and set the SERVER_NAME and SERVER_PORT variables */
  if ((temp = rb_hash_aref(req, global_http_host)) != Qnil) {
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
  rb_hash_aset(req, global_server_name, server_name);
  rb_hash_aset(req, global_server_port, server_port);
  rb_hash_aset(req, global_server_protocol, global_server_protocol_value);

  /* grab the initial body and stuff it into the hash */
  temp = rb_hash_aref(req, global_request_method);
  if (temp != Qnil) {
    long len = RSTRING_LEN(temp);
    char *ptr = RSTRING_PTR(temp);

    if (memcmp(ptr, "HEAD", len) && memcmp(ptr, "GET", len))
      rb_hash_aset(req, sym_http_body, rb_str_new(at, length));
  }
}

static void HttpParser_free(void *data) {
  TRACE();

  if(data) {
    free(data);
  }
}


static VALUE HttpParser_alloc(VALUE klass)
{
  VALUE obj;
  http_parser *hp = ALLOC_N(http_parser, 1);
  TRACE();
  http_parser_init(hp);

  obj = Data_Wrap_Struct(klass, NULL, HttpParser_free, hp);

  return obj;
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
 *    parser.execute(req_hash, data) -> true/false
 *
 * Takes a Hash and a String of data, parses the String of data filling
 * in the Hash returning a boolean to indicate whether or not parsing
 * is finished.
 * 
 * This function now throws an exception when there is a parsing error.
 * This makes the logic for working with the parser much easier.  You
 * will need to wrap the parser with an exception handling block.
 */

static VALUE HttpParser_execute(VALUE self, VALUE req_hash, VALUE data)
{
  http_parser *http = data_get(self);
  char *dptr = RSTRING_PTR(data);
  long dlen = RSTRING_LEN(data);

  if (http->nread < dlen) {
    http->data = (void *)req_hash;
    http_parser_execute(http, dptr, dlen);

    VALIDATE_MAX_LENGTH(http->nread, HEADER);

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
  global_http_host = find_common_field_value("HOST", 4);
  assert(global_http_host != Qnil);
}
