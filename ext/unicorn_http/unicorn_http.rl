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

#define UH_FL_CHUNKED  0x1
#define UH_FL_HASBODY  0x2
#define UH_FL_INBODY   0x4
#define UH_FL_HASTRAILER 0x8
#define UH_FL_INTRAILER 0x10
#define UH_FL_INCHUNK  0x20
#define UH_FL_KAMETHOD 0x40
#define UH_FL_KAVERSION 0x80
#define UH_FL_HASHEADER 0x100

/* both of these flags need to be set for keepalive to be supported */
#define UH_FL_KEEPALIVE (UH_FL_KAMETHOD | UH_FL_KAVERSION)

/* keep this small for Rainbows! since every client has one */
struct http_parser {
  int cs; /* Ragel internal state */
  unsigned int flags;
  size_t mark;
  size_t offset;
  union { /* these 2 fields don't nest */
    size_t field;
    size_t query;
  } start;
  union {
    size_t field_len; /* only used during header processing */
    size_t dest_offset; /* only used during body processing */
  } s;
  VALUE cont; /* Qfalse: unset, Qnil: ignored header, T_STRING: append */
  union {
    off_t content;
    off_t chunk;
  } len;
};

static void finalize_header(struct http_parser *hp, VALUE req);

#define REMAINING (unsigned long)(pe - p)
#define LEN(AT, FPC) (FPC - buffer - hp->AT)
#define MARK(M,FPC) (hp->M = (FPC) - buffer)
#define PTR_TO(F) (buffer + hp->F)
#define STR_NEW(M,FPC) rb_str_new(PTR_TO(M), LEN(M, FPC))

#define HP_FL_TEST(hp,fl) ((hp)->flags & (UH_FL_##fl))
#define HP_FL_SET(hp,fl) ((hp)->flags |= (UH_FL_##fl))
#define HP_FL_UNSET(hp,fl) ((hp)->flags &= ~(UH_FL_##fl))
#define HP_FL_ALL(hp,fl) (HP_FL_TEST(hp, fl) == (UH_FL_##fl))

/*
 * handles values of the "Connection:" header, keepalive is implied
 * for HTTP/1.1 but needs to be explicitly enabled with HTTP/1.0
 * Additionally, we require GET/HEAD requests to support keepalive.
 */
static void hp_keepalive_connection(struct http_parser *hp, VALUE val)
{
  /* REQUEST_METHOD is always set before any headers */
  if (HP_FL_TEST(hp, KAMETHOD)) {
    if (STR_CSTR_CASE_EQ(val, "keep-alive")) {
      /* basically have HTTP/1.0 masquerade as HTTP/1.1+ */
      HP_FL_SET(hp, KAVERSION);
    } else if (STR_CSTR_CASE_EQ(val, "close")) {
      /*
       * it doesn't matter what HTTP version or request method we have,
       * if a client says "Connection: close", we disable keepalive
       */
      HP_FL_UNSET(hp, KEEPALIVE);
    } else {
      /*
       * client could've sent anything, ignore it for now.  Maybe
       * "HP_FL_UNSET(hp, KEEPALIVE);" just in case?
       * Raising an exception might be too mean...
       */
    }
  }
}

static void
request_method(struct http_parser *hp, VALUE req, const char *ptr, size_t len)
{
  VALUE v;

  /*
   * we only support keepalive for GET and HEAD requests for now other
   * methods are too rarely seen to be worth optimizing.  POST is unsafe
   * since some clients send extra bytes after POST bodies.
   */
  if (CONST_MEM_EQ("GET", ptr, len)) {
    HP_FL_SET(hp, KAMETHOD);
    v = g_GET;
  } else if (CONST_MEM_EQ("HEAD", ptr, len)) {
    HP_FL_SET(hp, KAMETHOD);
    v = g_HEAD;
  } else {
    v = rb_str_new(ptr, len);
  }
  rb_hash_aset(req, g_request_method, v);
}

static void
http_version(struct http_parser *hp, VALUE req, const char *ptr, size_t len)
{
  VALUE v;

  HP_FL_SET(hp, HASHEADER);

  if (CONST_MEM_EQ("HTTP/1.1", ptr, len)) {
    /* HTTP/1.1 implies keepalive unless "Connection: close" is set */
    HP_FL_SET(hp, KAVERSION);
    v = g_http_11;
  } else if (CONST_MEM_EQ("HTTP/1.0", ptr, len)) {
    v = g_http_10;
  } else {
    v = rb_str_new(ptr, len);
  }
  rb_hash_aset(req, g_server_protocol, v);
  rb_hash_aset(req, g_http_version, v);
}

static inline void hp_invalid_if_trailer(struct http_parser *hp)
{
  if (HP_FL_TEST(hp, INTRAILER))
    rb_raise(eHttpParserError, "invalid Trailer");
}

static void write_cont_value(struct http_parser *hp,
                             char *buffer, const char *p)
{
  char *vptr;

  if (hp->cont == Qfalse)
     rb_raise(eHttpParserError, "invalid continuation line");
  if (NIL_P(hp->cont))
     return; /* we're ignoring this header (probably Host:) */

  assert(TYPE(hp->cont) == T_STRING && "continuation line is not a string");
  assert(hp->mark > 0 && "impossible continuation line offset");

  if (LEN(mark, p) == 0)
    return;

  if (RSTRING_LEN(hp->cont) > 0)
    --hp->mark;

  vptr = PTR_TO(mark);

  if (RSTRING_LEN(hp->cont) > 0) {
    assert((' ' == *vptr || '\t' == *vptr) && "invalid leading white space");
    *vptr = ' ';
  }
  rb_str_buf_cat(hp->cont, vptr, LEN(mark, p));
}

static void write_value(VALUE req, struct http_parser *hp,
                        const char *buffer, const char *p)
{
  VALUE f = find_common_field(PTR_TO(start.field), hp->s.field_len);
  VALUE v;
  VALUE e;

  VALIDATE_MAX_LENGTH(LEN(mark, p), FIELD_VALUE);
  v = LEN(mark, p) == 0 ? rb_str_buf_new(128) : STR_NEW(mark, p);
  if (NIL_P(f)) {
    const char *field = PTR_TO(start.field);
    size_t flen = hp->s.field_len;

    VALIDATE_MAX_LENGTH(flen, FIELD_NAME);

    /*
     * ignore "Version" headers since they conflict with the HTTP_VERSION
     * rack env variable.
     */
    if (CONST_MEM_EQ("VERSION", field, flen)) {
      hp->cont = Qnil;
      return;
    }
    f = uncommon_field(field, flen);
  } else if (f == g_http_connection) {
    hp_keepalive_connection(hp, v);
  } else if (f == g_content_length) {
    hp->len.content = parse_length(RSTRING_PTR(v), RSTRING_LEN(v));
    if (hp->len.content < 0)
      rb_raise(eHttpParserError, "invalid Content-Length");
    HP_FL_SET(hp, HASBODY);
    hp_invalid_if_trailer(hp);
  } else if (f == g_http_transfer_encoding) {
    if (STR_CSTR_CASE_EQ(v, "chunked")) {
      HP_FL_SET(hp, CHUNKED);
      HP_FL_SET(hp, HASBODY);
    }
    hp_invalid_if_trailer(hp);
  } else if (f == g_http_trailer) {
    HP_FL_SET(hp, HASTRAILER);
    hp_invalid_if_trailer(hp);
  } else {
    assert(TYPE(f) == T_STRING && "memoized object is not a string");
    assert_frozen(f);
  }

  e = rb_hash_aref(req, f);
  if (NIL_P(e)) {
    hp->cont = rb_hash_aset(req, f, v);
  } else if (f == g_http_host) {
    /*
     * ignored, absolute URLs in REQUEST_URI take precedence over
     * the Host: header (ref: rfc 2616, section 5.2.1)
     */
     hp->cont = Qnil;
  } else {
    rb_str_buf_cat(e, ",", 1);
    hp->cont = rb_str_buf_append(e, v);
  }
}

/** Machine **/

%%{
  machine http_parser;

  action mark {MARK(mark, fpc); }

  action start_field { MARK(start.field, fpc); }
  action snake_upcase_field { snake_upcase_char(deconst(fpc)); }
  action downcase_char { downcase_char(deconst(fpc)); }
  action write_field { hp->s.field_len = LEN(start.field, fpc); }
  action start_value { MARK(mark, fpc); }
  action write_value { write_value(req, hp, buffer, fpc); }
  action write_cont_value { write_cont_value(hp, buffer, fpc); }
  action request_method {
    request_method(hp, req, PTR_TO(mark), LEN(mark, fpc));
  }
  action scheme {
    rb_hash_aset(req, g_rack_url_scheme, STR_NEW(mark, fpc));
  }
  action host {
    rb_hash_aset(req, g_http_host, STR_NEW(mark, fpc));
  }
  action request_uri {
    VALUE str;

    VALIDATE_MAX_LENGTH(LEN(mark, fpc), REQUEST_URI);
    str = rb_hash_aset(req, g_request_uri, STR_NEW(mark, fpc));
    /*
     * "OPTIONS * HTTP/1.1\r\n" is a valid request, but we can't have '*'
     * in REQUEST_PATH or PATH_INFO or else Rack::Lint will complain
     */
    if (STR_CSTR_EQ(str, "*")) {
      str = rb_str_new(NULL, 0);
      rb_hash_aset(req, g_path_info, str);
      rb_hash_aset(req, g_request_path, str);
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
  action http_version { http_version(hp, req, PTR_TO(mark), LEN(mark, fpc)); }
  action request_path {
    VALUE val;

    VALIDATE_MAX_LENGTH(LEN(mark, fpc), REQUEST_PATH);
    val = rb_hash_aset(req, g_request_path, STR_NEW(mark, fpc));

    /* rack says PATH_INFO must start with "/" or be empty */
    if (!STR_CSTR_EQ(val, "*"))
      rb_hash_aset(req, g_path_info, val);
  }
  action add_to_chunk_size {
    hp->len.chunk = step_incr(hp->len.chunk, fc, 16);
    if (hp->len.chunk < 0)
      rb_raise(eHttpParserError, "invalid chunk size");
  }
  action header_done {
    finalize_header(hp, req);

    cs = http_parser_first_final;
    if (HP_FL_TEST(hp, HASBODY)) {
      HP_FL_SET(hp, INBODY);
      if (HP_FL_TEST(hp, CHUNKED))
        cs = http_parser_en_ChunkedBody;
    } else {
      assert(!HP_FL_TEST(hp, CHUNKED) && "chunked encoding without body!");
    }
    /*
     * go back to Ruby so we can call the Rack application, we'll reenter
     * the parser iff the body needs to be processed.
     */
    goto post_exec;
  }

  action end_trailers {
    cs = http_parser_first_final;
    goto post_exec;
  }

  action end_chunked_body {
    HP_FL_SET(hp, INTRAILER);
    cs = http_parser_en_Trailers;
    ++p;
    assert(p <= pe && "buffer overflow after chunked body");
    goto post_exec;
  }

  action skip_chunk_data {
  skip_chunk_data_hack: {
    size_t nr = MIN((size_t)hp->len.chunk, REMAINING);
    memcpy(RSTRING_PTR(req) + hp->s.dest_offset, fpc, nr);
    hp->s.dest_offset += nr;
    hp->len.chunk -= nr;
    p += nr;
    assert(hp->len.chunk >= 0 && "negative chunk length");
    if ((size_t)hp->len.chunk > REMAINING) {
      HP_FL_SET(hp, INCHUNK);
      goto post_exec;
    } else {
      fhold;
      fgoto chunk_end;
    }
  }}

  include unicorn_http_common "unicorn_http_common.rl";
}%%

/** Data **/
%% write data;

static void http_parser_init(struct http_parser *hp)
{
  int cs = 0;
  memset(hp, 0, sizeof(struct http_parser));
  hp->cont = Qfalse; /* zero on MRI, should be optimized away by above */
  %% write init;
  hp->cs = cs;
}

/** exec **/
static void http_parser_execute(struct http_parser *hp,
  VALUE req, char *buffer, size_t len)
{
  const char *p, *pe;
  int cs = hp->cs;
  size_t off = hp->offset;

  if (cs == http_parser_first_final)
    return;

  assert(off <= len && "offset past end of buffer");

  p = buffer+off;
  pe = buffer+len;

  assert((void *)(pe - p) == (void *)(len - off) &&
         "pointers aren't same distance");

  if (HP_FL_TEST(hp, INCHUNK)) {
    HP_FL_UNSET(hp, INCHUNK);
    goto skip_chunk_data_hack;
  }
  %% write exec;
post_exec: /* "_out:" also goes here */
  if (hp->cs != http_parser_error)
    hp->cs = cs;
  hp->offset = p - buffer;

  assert(p <= pe && "buffer overflow after parsing execute");
  assert(hp->offset <= len && "offset longer than length");
}

static struct http_parser *data_get(VALUE self)
{
  struct http_parser *hp;

  Data_Get_Struct(self, struct http_parser, hp);
  assert(hp && "failed to extract http_parser struct");
  return hp;
}

static void finalize_header(struct http_parser *hp, VALUE req)
{
  VALUE temp = rb_hash_aref(req, g_rack_url_scheme);
  VALUE server_name = g_localhost;
  VALUE server_port = g_port_80;

  /* set rack.url_scheme to "https" or "http", no others are allowed by Rack */
  if (NIL_P(temp)) {
    temp = rb_hash_aref(req, g_http_x_forwarded_proto);
    if (!NIL_P(temp) && STR_CSTR_EQ(temp, "https"))
      server_port = g_port_443;
    else
      temp = g_http;
    rb_hash_aset(req, g_rack_url_scheme, temp);
  } else if (STR_CSTR_EQ(temp, "https")) {
    server_port = g_port_443;
  } else {
    assert(server_port == g_port_80 && "server_port not set");
  }

  /* parse and set the SERVER_NAME and SERVER_PORT variables */
  temp = rb_hash_aref(req, g_http_host);
  if (!NIL_P(temp)) {
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
  if (!HP_FL_TEST(hp, HASHEADER))
    rb_hash_aset(req, g_server_protocol, g_http_09);

  /* rack requires QUERY_STRING */
  if (NIL_P(rb_hash_aref(req, g_query_string)))
    rb_hash_aset(req, g_query_string, rb_str_new(NULL, 0));
}

static void hp_mark(void *ptr)
{
  struct http_parser *hp = ptr;

  rb_gc_mark(hp->cont);
}

static VALUE HttpParser_alloc(VALUE klass)
{
  struct http_parser *hp;
  return Data_Make_Struct(klass, struct http_parser, hp_mark, -1, hp);
}


/**
 * call-seq:
 *    parser.new => parser
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
 *    parser.reset => nil
 *
 * Resets the parser to it's initial state so that you can reuse it
 * rather than making new ones.
 */
static VALUE HttpParser_reset(VALUE self)
{
  http_parser_init(data_get(self));

  return Qnil;
}

static void advance_str(VALUE str, off_t nr)
{
  long len = RSTRING_LEN(str);

  if (len == 0)
    return;

  rb_str_modify(str);

  assert(nr <= len && "trying to advance past end of buffer");
  len -= nr;
  if (len > 0) /* unlikely, len is usually 0 */
    memmove(RSTRING_PTR(str), RSTRING_PTR(str) + nr, len);
  rb_str_set_len(str, len);
}

/**
 * call-seq:
 *   parser.content_length => nil or Integer
 *
 * Returns the number of bytes left to run through HttpParser#filter_body.
 * This will initially be the value of the "Content-Length" HTTP header
 * after header parsing is complete and will decrease in value as
 * HttpParser#filter_body is called for each chunk.  This should return
 * zero for requests with no body.
 *
 * This will return nil on "Transfer-Encoding: chunked" requests.
 */
static VALUE HttpParser_content_length(VALUE self)
{
  struct http_parser *hp = data_get(self);

  return HP_FL_TEST(hp, CHUNKED) ? Qnil : OFFT2NUM(hp->len.content);
}

/**
 * Document-method: trailers
 * call-seq:
 *    parser.trailers(req, data) => req or nil
 *
 * This is an alias for HttpParser#headers
 */

/**
 * Document-method: headers
 * call-seq:
 *    parser.headers(req, data) => req or nil
 *
 * Takes a Hash and a String of data, parses the String of data filling
 * in the Hash returning the Hash if parsing is finished, nil otherwise
 * When returning the req Hash, it may modify data to point to where
 * body processing should begin.
 *
 * Raises HttpParserError if there are parsing errors.
 */
static VALUE HttpParser_headers(VALUE self, VALUE req, VALUE data)
{
  struct http_parser *hp = data_get(self);

  rb_str_update(data);

  http_parser_execute(hp, req, RSTRING_PTR(data), RSTRING_LEN(data));
  VALIDATE_MAX_LENGTH(hp->offset, HEADER);

  if (hp->cs == http_parser_first_final ||
      hp->cs == http_parser_en_ChunkedBody) {
    advance_str(data, hp->offset + 1);
    hp->offset = 0;

    return req;
  }

  if (hp->cs == http_parser_error)
    rb_raise(eHttpParserError, "Invalid HTTP format, parsing fails.");

  return Qnil;
}

static int chunked_eof(struct http_parser *hp)
{
  return ((hp->cs == http_parser_first_final) || HP_FL_TEST(hp, INTRAILER));
}

/**
 * call-seq:
 *    parser.body_eof? => true or false
 *
 * Detects if we're done filtering the body or not.  This can be used
 * to detect when to stop calling HttpParser#filter_body.
 */
static VALUE HttpParser_body_eof(VALUE self)
{
  struct http_parser *hp = data_get(self);

  if (HP_FL_TEST(hp, CHUNKED))
    return chunked_eof(hp) ? Qtrue : Qfalse;

  return hp->len.content == 0 ? Qtrue : Qfalse;
}

/**
 * call-seq:
 *    parser.keepalive? => true or false
 *
 * This should be used to detect if a request can really handle
 * keepalives and pipelining.  Currently, the rules are:
 *
 * 1. MUST be a GET or HEAD request
 * 2. MUST be HTTP/1.1 +or+ HTTP/1.0 with "Connection: keep-alive"
 * 3. MUST NOT have "Connection: close" set
 */
static VALUE HttpParser_keepalive(VALUE self)
{
  struct http_parser *hp = data_get(self);

  return HP_FL_ALL(hp, KEEPALIVE) ? Qtrue : Qfalse;
}

/**
 * call-seq:
 *    parser.headers? => true or false
 *
 * This should be used to detect if a request has headers (and if
 * the response will have headers as well).  HTTP/0.9 requests
 * should return false, all subsequent HTTP versions will return true
 */
static VALUE HttpParser_has_headers(VALUE self)
{
  struct http_parser *hp = data_get(self);

  return HP_FL_TEST(hp, HASHEADER) ? Qtrue : Qfalse;
}

/**
 * call-seq:
 *    parser.filter_body(buf, data) => nil/data
 *
 * Takes a String of +data+, will modify data if dechunking is done.
 * Returns +nil+ if there is more data left to process.  Returns
 * +data+ if body processing is complete. When returning +data+,
 * it may modify +data+ so the start of the string points to where
 * the body ended so that trailer processing can begin.
 *
 * Raises HttpParserError if there are dechunking errors.
 * Basically this is a glorified memcpy(3) that copies +data+
 * into +buf+ while filtering it through the dechunker.
 */
static VALUE HttpParser_filter_body(VALUE self, VALUE buf, VALUE data)
{
  struct http_parser *hp = data_get(self);
  char *dptr;
  long dlen;

  rb_str_update(data);
  dptr = RSTRING_PTR(data);
  dlen = RSTRING_LEN(data);

  StringValue(buf);
  rb_str_resize(buf, dlen); /* we can never copy more than dlen bytes */
  OBJ_TAINT(buf); /* keep weirdo $SAFE users happy */

  if (HP_FL_TEST(hp, CHUNKED)) {
    if (!chunked_eof(hp)) {
      hp->s.dest_offset = 0;
      http_parser_execute(hp, buf, dptr, dlen);
      if (hp->cs == http_parser_error)
        rb_raise(eHttpParserError, "Invalid HTTP format, parsing fails.");

      assert(hp->s.dest_offset <= hp->offset &&
             "destination buffer overflow");
      advance_str(data, hp->offset);
      rb_str_set_len(buf, hp->s.dest_offset);

      if (RSTRING_LEN(buf) == 0 && chunked_eof(hp)) {
        assert(hp->len.chunk == 0 && "chunk at EOF but more to parse");
      } else {
        data = Qnil;
      }
    }
  } else {
    /* no need to enter the Ragel machine for unchunked transfers */
    assert(hp->len.content >= 0 && "negative Content-Length");
    if (hp->len.content > 0) {
      long nr = MIN(dlen, hp->len.content);

      memcpy(RSTRING_PTR(buf), dptr, nr);
      hp->len.content -= nr;
      if (hp->len.content == 0)
        hp->cs = http_parser_first_final;
      advance_str(data, nr);
      rb_str_set_len(buf, nr);
      data = Qnil;
    }
  }
  hp->offset = 0; /* for trailer parsing */
  return data;
}

#define SET_GLOBAL(var,str) do { \
  var = find_common_field(str, sizeof(str) - 1); \
  assert(!NIL_P(var) && "missed global field"); \
} while (0)

void Init_unicorn_http(void)
{
  VALUE mUnicorn, cHttpParser;

  mUnicorn = rb_const_get(rb_cObject, rb_intern("Unicorn"));
  cHttpParser = rb_define_class_under(mUnicorn, "HttpParser", rb_cObject);
  eHttpParserError =
         rb_define_class_under(mUnicorn, "HttpParserError", rb_eIOError);

  init_globals();
  rb_define_alloc_func(cHttpParser, HttpParser_alloc);
  rb_define_method(cHttpParser, "initialize", HttpParser_init,0);
  rb_define_method(cHttpParser, "reset", HttpParser_reset,0);
  rb_define_method(cHttpParser, "headers", HttpParser_headers, 2);
  rb_define_method(cHttpParser, "filter_body", HttpParser_filter_body, 2);
  rb_define_method(cHttpParser, "trailers", HttpParser_headers, 2);
  rb_define_method(cHttpParser, "content_length", HttpParser_content_length, 0);
  rb_define_method(cHttpParser, "body_eof?", HttpParser_body_eof, 0);
  rb_define_method(cHttpParser, "keepalive?", HttpParser_keepalive, 0);
  rb_define_method(cHttpParser, "headers?", HttpParser_has_headers, 0);

  /*
   * The maximum size a single chunk when using chunked transfer encoding.
   * This is only a theoretical maximum used to detect errors in clients,
   * it is highly unlikely to encounter clients that send more than
   * several kilobytes at once.
   */
  rb_define_const(cHttpParser, "CHUNK_MAX", OFFT2NUM(UH_OFF_T_MAX));

  /*
   * The maximum size of the body as specified by Content-Length.
   * This is only a theoretical maximum, the actual limit is subject
   * to the limits of the file system used for +Dir.tmpdir+.
   */
  rb_define_const(cHttpParser, "LENGTH_MAX", OFFT2NUM(UH_OFF_T_MAX));

  init_common_fields();
  SET_GLOBAL(g_http_host, "HOST");
  SET_GLOBAL(g_http_trailer, "TRAILER");
  SET_GLOBAL(g_http_transfer_encoding, "TRANSFER_ENCODING");
  SET_GLOBAL(g_content_length, "CONTENT_LENGTH");
  SET_GLOBAL(g_http_connection, "CONNECTION");
}
#undef SET_GLOBAL
