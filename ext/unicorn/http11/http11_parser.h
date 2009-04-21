
#line 1 "http11_parser.rl"
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


#line 109 "http11_parser.rl"


/** Data **/

#line 70 "http11_parser.h"
static const int http_parser_start = 1;
static const int http_parser_first_final = 63;
static const int http_parser_error = 0;

static const int http_parser_en_main = 1;


#line 113 "http11_parser.rl"

static void http_parser_init(http_parser *parser) {
  int cs = 0;
  memset(parser, 0, sizeof(*parser));

#line 84 "http11_parser.h"
	{
	cs = http_parser_start;
	}

#line 118 "http11_parser.rl"
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


#line 110 "http11_parser.h"
	{
	if ( p == pe )
		goto _test_eof;
	switch ( cs )
	{
case 1:
	switch( (*p) ) {
		case 36: goto tr0;
		case 95: goto tr0;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto tr0;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto tr0;
	} else
		goto tr0;
	goto st0;
st0:
cs = 0;
	goto _out;
tr0:
#line 64 "http11_parser.rl"
	{MARK(mark, p); }
	goto st2;
st2:
	if ( ++p == pe )
		goto _test_eof2;
case 2:
#line 141 "http11_parser.h"
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st44;
		case 95: goto st44;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st44;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st44;
	} else
		goto st44;
	goto st0;
tr2:
#line 77 "http11_parser.rl"
	{
    request_method(parser->data, PTR_TO(mark), LEN(mark, p));
  }
	goto st3;
st3:
	if ( ++p == pe )
		goto _test_eof3;
case 3:
#line 166 "http11_parser.h"
	switch( (*p) ) {
		case 42: goto tr4;
		case 47: goto tr5;
		case 72: goto tr6;
		case 104: goto tr6;
	}
	goto st0;
tr4:
#line 64 "http11_parser.rl"
	{MARK(mark, p); }
	goto st4;
st4:
	if ( ++p == pe )
		goto _test_eof4;
case 4:
#line 182 "http11_parser.h"
	switch( (*p) ) {
		case 32: goto tr7;
		case 35: goto tr8;
	}
	goto st0;
tr7:
#line 82 "http11_parser.rl"
	{
    request_uri(parser->data, PTR_TO(mark), LEN(mark, p));
  }
	goto st5;
tr30:
#line 64 "http11_parser.rl"
	{MARK(mark, p); }
#line 85 "http11_parser.rl"
	{
    fragment(parser->data, PTR_TO(mark), LEN(mark, p));
  }
	goto st5;
tr33:
#line 85 "http11_parser.rl"
	{
    fragment(parser->data, PTR_TO(mark), LEN(mark, p));
  }
	goto st5;
tr37:
#line 98 "http11_parser.rl"
	{
    request_path(parser->data, PTR_TO(mark), LEN(mark,p));
  }
#line 82 "http11_parser.rl"
	{
    request_uri(parser->data, PTR_TO(mark), LEN(mark, p));
  }
	goto st5;
tr48:
#line 89 "http11_parser.rl"
	{MARK(query_start, p); }
#line 90 "http11_parser.rl"
	{
    query_string(parser->data, PTR_TO(query_start), LEN(query_start, p));
  }
#line 82 "http11_parser.rl"
	{
    request_uri(parser->data, PTR_TO(mark), LEN(mark, p));
  }
	goto st5;
tr52:
#line 90 "http11_parser.rl"
	{
    query_string(parser->data, PTR_TO(query_start), LEN(query_start, p));
  }
#line 82 "http11_parser.rl"
	{
    request_uri(parser->data, PTR_TO(mark), LEN(mark, p));
  }
	goto st5;
st5:
	if ( ++p == pe )
		goto _test_eof5;
case 5:
#line 244 "http11_parser.h"
	if ( (*p) == 72 )
		goto tr9;
	goto st0;
tr9:
#line 64 "http11_parser.rl"
	{MARK(mark, p); }
	goto st6;
st6:
	if ( ++p == pe )
		goto _test_eof6;
case 6:
#line 256 "http11_parser.h"
	if ( (*p) == 84 )
		goto st7;
	goto st0;
st7:
	if ( ++p == pe )
		goto _test_eof7;
case 7:
	if ( (*p) == 84 )
		goto st8;
	goto st0;
st8:
	if ( ++p == pe )
		goto _test_eof8;
case 8:
	if ( (*p) == 80 )
		goto st9;
	goto st0;
st9:
	if ( ++p == pe )
		goto _test_eof9;
case 9:
	if ( (*p) == 47 )
		goto st10;
	goto st0;
st10:
	if ( ++p == pe )
		goto _test_eof10;
case 10:
	if ( 48 <= (*p) && (*p) <= 57 )
		goto st11;
	goto st0;
st11:
	if ( ++p == pe )
		goto _test_eof11;
case 11:
	if ( (*p) == 46 )
		goto st12;
	if ( 48 <= (*p) && (*p) <= 57 )
		goto st11;
	goto st0;
st12:
	if ( ++p == pe )
		goto _test_eof12;
case 12:
	if ( 48 <= (*p) && (*p) <= 57 )
		goto st13;
	goto st0;
st13:
	if ( ++p == pe )
		goto _test_eof13;
case 13:
	if ( (*p) == 13 )
		goto tr17;
	if ( 48 <= (*p) && (*p) <= 57 )
		goto st13;
	goto st0;
tr17:
#line 94 "http11_parser.rl"
	{
    http_version(parser->data, PTR_TO(mark), LEN(mark, p));
  }
	goto st14;
tr25:
#line 73 "http11_parser.rl"
	{ MARK(mark, p); }
#line 74 "http11_parser.rl"
	{
    http_field(parser->data, PTR_TO(field_start), parser->field_len, PTR_TO(mark), LEN(mark, p));
  }
	goto st14;
tr28:
#line 74 "http11_parser.rl"
	{
    http_field(parser->data, PTR_TO(field_start), parser->field_len, PTR_TO(mark), LEN(mark, p));
  }
	goto st14;
st14:
	if ( ++p == pe )
		goto _test_eof14;
case 14:
#line 337 "http11_parser.h"
	if ( (*p) == 10 )
		goto st15;
	goto st0;
st15:
	if ( ++p == pe )
		goto _test_eof15;
case 15:
	switch( (*p) ) {
		case 13: goto st16;
		case 33: goto tr20;
		case 124: goto tr20;
		case 126: goto tr20;
	}
	if ( (*p) < 45 ) {
		if ( (*p) > 39 ) {
			if ( 42 <= (*p) && (*p) <= 43 )
				goto tr20;
		} else if ( (*p) >= 35 )
			goto tr20;
	} else if ( (*p) > 46 ) {
		if ( (*p) < 65 ) {
			if ( 48 <= (*p) && (*p) <= 57 )
				goto tr20;
		} else if ( (*p) > 90 ) {
			if ( 94 <= (*p) && (*p) <= 122 )
				goto tr20;
		} else
			goto tr20;
	} else
		goto tr20;
	goto st0;
st16:
	if ( ++p == pe )
		goto _test_eof16;
case 16:
	if ( (*p) == 10 )
		goto tr21;
	goto st0;
tr21:
#line 102 "http11_parser.rl"
	{
    parser->body_start = p - buffer + 1;
    header_done(parser->data, p + 1, pe - p - 1);
    {p++; cs = 63; goto _out;}
  }
	goto st63;
st63:
	if ( ++p == pe )
		goto _test_eof63;
case 63:
#line 388 "http11_parser.h"
	goto st0;
tr20:
#line 66 "http11_parser.rl"
	{ MARK(field_start, p); }
#line 67 "http11_parser.rl"
	{ snake_upcase_char((char *)p); }
	goto st17;
tr22:
#line 67 "http11_parser.rl"
	{ snake_upcase_char((char *)p); }
	goto st17;
st17:
	if ( ++p == pe )
		goto _test_eof17;
case 17:
#line 404 "http11_parser.h"
	switch( (*p) ) {
		case 33: goto tr22;
		case 58: goto tr23;
		case 124: goto tr22;
		case 126: goto tr22;
	}
	if ( (*p) < 45 ) {
		if ( (*p) > 39 ) {
			if ( 42 <= (*p) && (*p) <= 43 )
				goto tr22;
		} else if ( (*p) >= 35 )
			goto tr22;
	} else if ( (*p) > 46 ) {
		if ( (*p) < 65 ) {
			if ( 48 <= (*p) && (*p) <= 57 )
				goto tr22;
		} else if ( (*p) > 90 ) {
			if ( 94 <= (*p) && (*p) <= 122 )
				goto tr22;
		} else
			goto tr22;
	} else
		goto tr22;
	goto st0;
tr23:
#line 69 "http11_parser.rl"
	{
    parser->field_len = LEN(field_start, p);
  }
	goto st18;
tr26:
#line 73 "http11_parser.rl"
	{ MARK(mark, p); }
	goto st18;
st18:
	if ( ++p == pe )
		goto _test_eof18;
case 18:
#line 443 "http11_parser.h"
	switch( (*p) ) {
		case 13: goto tr25;
		case 32: goto tr26;
	}
	goto tr24;
tr24:
#line 73 "http11_parser.rl"
	{ MARK(mark, p); }
	goto st19;
st19:
	if ( ++p == pe )
		goto _test_eof19;
case 19:
#line 457 "http11_parser.h"
	if ( (*p) == 13 )
		goto tr28;
	goto st19;
tr8:
#line 82 "http11_parser.rl"
	{
    request_uri(parser->data, PTR_TO(mark), LEN(mark, p));
  }
	goto st20;
tr38:
#line 98 "http11_parser.rl"
	{
    request_path(parser->data, PTR_TO(mark), LEN(mark,p));
  }
#line 82 "http11_parser.rl"
	{
    request_uri(parser->data, PTR_TO(mark), LEN(mark, p));
  }
	goto st20;
tr49:
#line 89 "http11_parser.rl"
	{MARK(query_start, p); }
#line 90 "http11_parser.rl"
	{
    query_string(parser->data, PTR_TO(query_start), LEN(query_start, p));
  }
#line 82 "http11_parser.rl"
	{
    request_uri(parser->data, PTR_TO(mark), LEN(mark, p));
  }
	goto st20;
tr53:
#line 90 "http11_parser.rl"
	{
    query_string(parser->data, PTR_TO(query_start), LEN(query_start, p));
  }
#line 82 "http11_parser.rl"
	{
    request_uri(parser->data, PTR_TO(mark), LEN(mark, p));
  }
	goto st20;
st20:
	if ( ++p == pe )
		goto _test_eof20;
case 20:
#line 503 "http11_parser.h"
	switch( (*p) ) {
		case 32: goto tr30;
		case 35: goto st0;
		case 37: goto tr31;
		case 127: goto st0;
	}
	if ( 0 <= (*p) && (*p) <= 31 )
		goto st0;
	goto tr29;
tr29:
#line 64 "http11_parser.rl"
	{MARK(mark, p); }
	goto st21;
st21:
	if ( ++p == pe )
		goto _test_eof21;
case 21:
#line 521 "http11_parser.h"
	switch( (*p) ) {
		case 32: goto tr33;
		case 35: goto st0;
		case 37: goto st22;
		case 127: goto st0;
	}
	if ( 0 <= (*p) && (*p) <= 31 )
		goto st0;
	goto st21;
tr31:
#line 64 "http11_parser.rl"
	{MARK(mark, p); }
	goto st22;
st22:
	if ( ++p == pe )
		goto _test_eof22;
case 22:
#line 539 "http11_parser.h"
	if ( (*p) < 65 ) {
		if ( 48 <= (*p) && (*p) <= 57 )
			goto st23;
	} else if ( (*p) > 70 ) {
		if ( 97 <= (*p) && (*p) <= 102 )
			goto st23;
	} else
		goto st23;
	goto st0;
st23:
	if ( ++p == pe )
		goto _test_eof23;
case 23:
	if ( (*p) < 65 ) {
		if ( 48 <= (*p) && (*p) <= 57 )
			goto st21;
	} else if ( (*p) > 70 ) {
		if ( 97 <= (*p) && (*p) <= 102 )
			goto st21;
	} else
		goto st21;
	goto st0;
tr5:
#line 64 "http11_parser.rl"
	{MARK(mark, p); }
	goto st24;
tr65:
#line 81 "http11_parser.rl"
	{ host(parser->data, PTR_TO(mark), LEN(mark, p)); }
#line 64 "http11_parser.rl"
	{MARK(mark, p); }
	goto st24;
st24:
	if ( ++p == pe )
		goto _test_eof24;
case 24:
#line 576 "http11_parser.h"
	switch( (*p) ) {
		case 32: goto tr37;
		case 35: goto tr38;
		case 37: goto st25;
		case 59: goto tr40;
		case 63: goto tr41;
		case 127: goto st0;
	}
	if ( 0 <= (*p) && (*p) <= 31 )
		goto st0;
	goto st24;
st25:
	if ( ++p == pe )
		goto _test_eof25;
case 25:
	if ( (*p) < 65 ) {
		if ( 48 <= (*p) && (*p) <= 57 )
			goto st26;
	} else if ( (*p) > 70 ) {
		if ( 97 <= (*p) && (*p) <= 102 )
			goto st26;
	} else
		goto st26;
	goto st0;
st26:
	if ( ++p == pe )
		goto _test_eof26;
case 26:
	if ( (*p) < 65 ) {
		if ( 48 <= (*p) && (*p) <= 57 )
			goto st24;
	} else if ( (*p) > 70 ) {
		if ( 97 <= (*p) && (*p) <= 102 )
			goto st24;
	} else
		goto st24;
	goto st0;
tr40:
#line 98 "http11_parser.rl"
	{
    request_path(parser->data, PTR_TO(mark), LEN(mark,p));
  }
	goto st27;
st27:
	if ( ++p == pe )
		goto _test_eof27;
case 27:
#line 624 "http11_parser.h"
	switch( (*p) ) {
		case 32: goto tr7;
		case 35: goto tr8;
		case 37: goto st28;
		case 63: goto st30;
		case 127: goto st0;
	}
	if ( 0 <= (*p) && (*p) <= 31 )
		goto st0;
	goto st27;
st28:
	if ( ++p == pe )
		goto _test_eof28;
case 28:
	if ( (*p) < 65 ) {
		if ( 48 <= (*p) && (*p) <= 57 )
			goto st29;
	} else if ( (*p) > 70 ) {
		if ( 97 <= (*p) && (*p) <= 102 )
			goto st29;
	} else
		goto st29;
	goto st0;
st29:
	if ( ++p == pe )
		goto _test_eof29;
case 29:
	if ( (*p) < 65 ) {
		if ( 48 <= (*p) && (*p) <= 57 )
			goto st27;
	} else if ( (*p) > 70 ) {
		if ( 97 <= (*p) && (*p) <= 102 )
			goto st27;
	} else
		goto st27;
	goto st0;
tr41:
#line 98 "http11_parser.rl"
	{
    request_path(parser->data, PTR_TO(mark), LEN(mark,p));
  }
	goto st30;
st30:
	if ( ++p == pe )
		goto _test_eof30;
case 30:
#line 671 "http11_parser.h"
	switch( (*p) ) {
		case 32: goto tr48;
		case 35: goto tr49;
		case 37: goto tr50;
		case 127: goto st0;
	}
	if ( 0 <= (*p) && (*p) <= 31 )
		goto st0;
	goto tr47;
tr47:
#line 89 "http11_parser.rl"
	{MARK(query_start, p); }
	goto st31;
st31:
	if ( ++p == pe )
		goto _test_eof31;
case 31:
#line 689 "http11_parser.h"
	switch( (*p) ) {
		case 32: goto tr52;
		case 35: goto tr53;
		case 37: goto st32;
		case 127: goto st0;
	}
	if ( 0 <= (*p) && (*p) <= 31 )
		goto st0;
	goto st31;
tr50:
#line 89 "http11_parser.rl"
	{MARK(query_start, p); }
	goto st32;
st32:
	if ( ++p == pe )
		goto _test_eof32;
case 32:
#line 707 "http11_parser.h"
	if ( (*p) < 65 ) {
		if ( 48 <= (*p) && (*p) <= 57 )
			goto st33;
	} else if ( (*p) > 70 ) {
		if ( 97 <= (*p) && (*p) <= 102 )
			goto st33;
	} else
		goto st33;
	goto st0;
st33:
	if ( ++p == pe )
		goto _test_eof33;
case 33:
	if ( (*p) < 65 ) {
		if ( 48 <= (*p) && (*p) <= 57 )
			goto st31;
	} else if ( (*p) > 70 ) {
		if ( 97 <= (*p) && (*p) <= 102 )
			goto st31;
	} else
		goto st31;
	goto st0;
tr6:
#line 64 "http11_parser.rl"
	{MARK(mark, p); }
#line 68 "http11_parser.rl"
	{ downcase_char((char *)p); }
	goto st34;
st34:
	if ( ++p == pe )
		goto _test_eof34;
case 34:
#line 740 "http11_parser.h"
	switch( (*p) ) {
		case 84: goto tr56;
		case 116: goto tr56;
	}
	goto st0;
tr56:
#line 68 "http11_parser.rl"
	{ downcase_char((char *)p); }
	goto st35;
st35:
	if ( ++p == pe )
		goto _test_eof35;
case 35:
#line 754 "http11_parser.h"
	switch( (*p) ) {
		case 84: goto tr57;
		case 116: goto tr57;
	}
	goto st0;
tr57:
#line 68 "http11_parser.rl"
	{ downcase_char((char *)p); }
	goto st36;
st36:
	if ( ++p == pe )
		goto _test_eof36;
case 36:
#line 768 "http11_parser.h"
	switch( (*p) ) {
		case 80: goto tr58;
		case 112: goto tr58;
	}
	goto st0;
tr58:
#line 68 "http11_parser.rl"
	{ downcase_char((char *)p); }
	goto st37;
st37:
	if ( ++p == pe )
		goto _test_eof37;
case 37:
#line 782 "http11_parser.h"
	switch( (*p) ) {
		case 58: goto tr59;
		case 83: goto tr60;
		case 115: goto tr60;
	}
	goto st0;
tr59:
#line 80 "http11_parser.rl"
	{ scheme(parser->data, PTR_TO(mark), LEN(mark, p)); }
	goto st38;
st38:
	if ( ++p == pe )
		goto _test_eof38;
case 38:
#line 797 "http11_parser.h"
	if ( (*p) == 47 )
		goto st39;
	goto st0;
st39:
	if ( ++p == pe )
		goto _test_eof39;
case 39:
	if ( (*p) == 47 )
		goto st40;
	goto st0;
st40:
	if ( ++p == pe )
		goto _test_eof40;
case 40:
	if ( (*p) == 95 )
		goto tr63;
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto tr63;
	} else if ( (*p) > 57 ) {
		if ( (*p) > 90 ) {
			if ( 97 <= (*p) && (*p) <= 122 )
				goto tr63;
		} else if ( (*p) >= 65 )
			goto tr63;
	} else
		goto tr63;
	goto st0;
tr63:
#line 64 "http11_parser.rl"
	{MARK(mark, p); }
	goto st41;
st41:
	if ( ++p == pe )
		goto _test_eof41;
case 41:
#line 834 "http11_parser.h"
	switch( (*p) ) {
		case 47: goto tr65;
		case 58: goto st42;
		case 95: goto st41;
	}
	if ( (*p) < 65 ) {
		if ( 45 <= (*p) && (*p) <= 57 )
			goto st41;
	} else if ( (*p) > 90 ) {
		if ( 97 <= (*p) && (*p) <= 122 )
			goto st41;
	} else
		goto st41;
	goto st0;
st42:
	if ( ++p == pe )
		goto _test_eof42;
case 42:
	if ( (*p) == 47 )
		goto tr65;
	if ( 48 <= (*p) && (*p) <= 57 )
		goto st42;
	goto st0;
tr60:
#line 68 "http11_parser.rl"
	{ downcase_char((char *)p); }
	goto st43;
st43:
	if ( ++p == pe )
		goto _test_eof43;
case 43:
#line 866 "http11_parser.h"
	if ( (*p) == 58 )
		goto tr59;
	goto st0;
st44:
	if ( ++p == pe )
		goto _test_eof44;
case 44:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st45;
		case 95: goto st45;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st45;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st45;
	} else
		goto st45;
	goto st0;
st45:
	if ( ++p == pe )
		goto _test_eof45;
case 45:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st46;
		case 95: goto st46;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st46;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st46;
	} else
		goto st46;
	goto st0;
st46:
	if ( ++p == pe )
		goto _test_eof46;
case 46:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st47;
		case 95: goto st47;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st47;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st47;
	} else
		goto st47;
	goto st0;
st47:
	if ( ++p == pe )
		goto _test_eof47;
case 47:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st48;
		case 95: goto st48;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st48;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st48;
	} else
		goto st48;
	goto st0;
st48:
	if ( ++p == pe )
		goto _test_eof48;
case 48:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st49;
		case 95: goto st49;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st49;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st49;
	} else
		goto st49;
	goto st0;
st49:
	if ( ++p == pe )
		goto _test_eof49;
case 49:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st50;
		case 95: goto st50;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st50;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st50;
	} else
		goto st50;
	goto st0;
st50:
	if ( ++p == pe )
		goto _test_eof50;
case 50:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st51;
		case 95: goto st51;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st51;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st51;
	} else
		goto st51;
	goto st0;
st51:
	if ( ++p == pe )
		goto _test_eof51;
case 51:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st52;
		case 95: goto st52;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st52;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st52;
	} else
		goto st52;
	goto st0;
st52:
	if ( ++p == pe )
		goto _test_eof52;
case 52:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st53;
		case 95: goto st53;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st53;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st53;
	} else
		goto st53;
	goto st0;
st53:
	if ( ++p == pe )
		goto _test_eof53;
case 53:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st54;
		case 95: goto st54;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st54;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st54;
	} else
		goto st54;
	goto st0;
st54:
	if ( ++p == pe )
		goto _test_eof54;
case 54:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st55;
		case 95: goto st55;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st55;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st55;
	} else
		goto st55;
	goto st0;
st55:
	if ( ++p == pe )
		goto _test_eof55;
case 55:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st56;
		case 95: goto st56;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st56;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st56;
	} else
		goto st56;
	goto st0;
st56:
	if ( ++p == pe )
		goto _test_eof56;
case 56:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st57;
		case 95: goto st57;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st57;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st57;
	} else
		goto st57;
	goto st0;
st57:
	if ( ++p == pe )
		goto _test_eof57;
case 57:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st58;
		case 95: goto st58;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st58;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st58;
	} else
		goto st58;
	goto st0;
st58:
	if ( ++p == pe )
		goto _test_eof58;
case 58:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st59;
		case 95: goto st59;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st59;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st59;
	} else
		goto st59;
	goto st0;
st59:
	if ( ++p == pe )
		goto _test_eof59;
case 59:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st60;
		case 95: goto st60;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st60;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st60;
	} else
		goto st60;
	goto st0;
st60:
	if ( ++p == pe )
		goto _test_eof60;
case 60:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st61;
		case 95: goto st61;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st61;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st61;
	} else
		goto st61;
	goto st0;
st61:
	if ( ++p == pe )
		goto _test_eof61;
case 61:
	switch( (*p) ) {
		case 32: goto tr2;
		case 36: goto st62;
		case 95: goto st62;
	}
	if ( (*p) < 48 ) {
		if ( 45 <= (*p) && (*p) <= 46 )
			goto st62;
	} else if ( (*p) > 57 ) {
		if ( 65 <= (*p) && (*p) <= 90 )
			goto st62;
	} else
		goto st62;
	goto st0;
st62:
	if ( ++p == pe )
		goto _test_eof62;
case 62:
	if ( (*p) == 32 )
		goto tr2;
	goto st0;
	}
	_test_eof2: cs = 2; goto _test_eof;
	_test_eof3: cs = 3; goto _test_eof;
	_test_eof4: cs = 4; goto _test_eof;
	_test_eof5: cs = 5; goto _test_eof;
	_test_eof6: cs = 6; goto _test_eof;
	_test_eof7: cs = 7; goto _test_eof;
	_test_eof8: cs = 8; goto _test_eof;
	_test_eof9: cs = 9; goto _test_eof;
	_test_eof10: cs = 10; goto _test_eof;
	_test_eof11: cs = 11; goto _test_eof;
	_test_eof12: cs = 12; goto _test_eof;
	_test_eof13: cs = 13; goto _test_eof;
	_test_eof14: cs = 14; goto _test_eof;
	_test_eof15: cs = 15; goto _test_eof;
	_test_eof16: cs = 16; goto _test_eof;
	_test_eof63: cs = 63; goto _test_eof;
	_test_eof17: cs = 17; goto _test_eof;
	_test_eof18: cs = 18; goto _test_eof;
	_test_eof19: cs = 19; goto _test_eof;
	_test_eof20: cs = 20; goto _test_eof;
	_test_eof21: cs = 21; goto _test_eof;
	_test_eof22: cs = 22; goto _test_eof;
	_test_eof23: cs = 23; goto _test_eof;
	_test_eof24: cs = 24; goto _test_eof;
	_test_eof25: cs = 25; goto _test_eof;
	_test_eof26: cs = 26; goto _test_eof;
	_test_eof27: cs = 27; goto _test_eof;
	_test_eof28: cs = 28; goto _test_eof;
	_test_eof29: cs = 29; goto _test_eof;
	_test_eof30: cs = 30; goto _test_eof;
	_test_eof31: cs = 31; goto _test_eof;
	_test_eof32: cs = 32; goto _test_eof;
	_test_eof33: cs = 33; goto _test_eof;
	_test_eof34: cs = 34; goto _test_eof;
	_test_eof35: cs = 35; goto _test_eof;
	_test_eof36: cs = 36; goto _test_eof;
	_test_eof37: cs = 37; goto _test_eof;
	_test_eof38: cs = 38; goto _test_eof;
	_test_eof39: cs = 39; goto _test_eof;
	_test_eof40: cs = 40; goto _test_eof;
	_test_eof41: cs = 41; goto _test_eof;
	_test_eof42: cs = 42; goto _test_eof;
	_test_eof43: cs = 43; goto _test_eof;
	_test_eof44: cs = 44; goto _test_eof;
	_test_eof45: cs = 45; goto _test_eof;
	_test_eof46: cs = 46; goto _test_eof;
	_test_eof47: cs = 47; goto _test_eof;
	_test_eof48: cs = 48; goto _test_eof;
	_test_eof49: cs = 49; goto _test_eof;
	_test_eof50: cs = 50; goto _test_eof;
	_test_eof51: cs = 51; goto _test_eof;
	_test_eof52: cs = 52; goto _test_eof;
	_test_eof53: cs = 53; goto _test_eof;
	_test_eof54: cs = 54; goto _test_eof;
	_test_eof55: cs = 55; goto _test_eof;
	_test_eof56: cs = 56; goto _test_eof;
	_test_eof57: cs = 57; goto _test_eof;
	_test_eof58: cs = 58; goto _test_eof;
	_test_eof59: cs = 59; goto _test_eof;
	_test_eof60: cs = 60; goto _test_eof;
	_test_eof61: cs = 61; goto _test_eof;
	_test_eof62: cs = 62; goto _test_eof;

	_test_eof: {}
	_out: {}
	}

#line 138 "http11_parser.rl"

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
