#define RSTRING_MODIFIED 1 /* we modify RSTRING_PTR */
#include <ruby.h>
#include <time.h>
#include <stdio.h>

static const size_t buf_capa = sizeof("Thu, 01 Jan 1970 00:00:00 GMT");
static const char week[] = "Sun\0Mon\0Tue\0Wed\0Thu\0Fri\0Sat";
static const char months[] = "Jan\0Feb\0Mar\0Apr\0May\0Jun\0"
                             "Jul\0Aug\0Sep\0Oct\0Nov\0Dec";

/* for people on wonky systems only */
#ifndef HAVE_GMTIME_R
static struct tm * my_gmtime_r(time_t *now, struct tm *tm)
{
	struct tm *global = gmtime(now);
	if (global)
		*tm = *global;
	return tm;
}
#  define gmtime_r my_gmtime_r
#endif

/* TODO: update this in case other implementations lose the GVL */
#if defined(RUBINIUS)
#  define UH_HAVE_GVL (0)
#else
#  define UH_HAVE_GVL (1)
#endif

#if defined(__GNUC__) && (__GNUC__ >= 3)
# define UH_ATTRIBUTE_CONST __attribute__ ((__const__))
#else
# define UH_ATTRIBUTE_CONST /* empty */
#endif

#if UH_HAVE_GVL
static VALUE g_buf;
static char *g_buf_ptr;
static VALUE UH_ATTRIBUTE_CONST get_buf(void) { return g_buf; }
static char * UH_ATTRIBUTE_CONST get_buf_ptr(VALUE ign) { return g_buf_ptr; }
static void init_buf(void)
{
	g_buf = rb_str_new(0, buf_capa - 1);
	g_buf_ptr = RSTRING_PTR(g_buf);
	rb_global_variable(&g_buf);
}
#else /* !UH_HAVE_GVL */
static VALUE buf_key;
static VALUE get_buf(void)
{
	VALUE buf = rb_thread_local_aref(rb_thread_current(), buf_key);

	/*
	 * we must validate this, otherwise some bad code could muck
	 * with local vars in Thread.current and crash us
	 */
	if (TYPE(buf) != T_STRING) {
		buf = rb_str_new(0, buf_capa - 1);
		rb_thread_local_aset(rb_thread_current(), buf_key, buf);
	} else if (RSTRING_LEN(buf) != (long)buf_capa) {
		rb_str_modify(buf);
		rb_str_resize(buf, buf_capa - 1);
	}

	return buf;
}

static char *get_buf_ptr(VALUE buf) { return RSTRING_PTR(buf); }

static void init_buf(void)
{
	buf_key = ID2SYM(rb_intern("uh_httpdate_buf"));
	rb_global_variable(&buf_key); /* in case symbols ever get GC-ed */
}
#endif /* !UH_HAVE_GVL */

/*
 * Returns a string which represents the time as rfc1123-date of HTTP-date
 * defined by RFC 2616:
 *
 *   day-of-week, DD month-name CCYY hh:mm:ss GMT
 *
 * Note that the result is always GMT.
 *
 * This method is identical to Time#httpdate in the Ruby standard library,
 * except it is implemented in C for performance.  We always saw
 * Time#httpdate at or near the top of the profiler output so we
 * decided to rewrite this in C.
 */
static VALUE httpdate(VALUE self)
{
	static time_t last;
	time_t now = time(NULL); /* not a syscall on modern 64-bit systems */
	struct tm tm;
	VALUE buf = get_buf();

	if (last == now)
		return buf;
	last = now;
	gmtime_r(&now, &tm);

	snprintf(get_buf_ptr(buf), buf_capa,
	         "%s, %02d %s %4d %02d:%02d:%02d GMT",
	         week + (tm.tm_wday * 4),
	         tm.tm_mday,
	         months + (tm.tm_mon * 4),
	         tm.tm_year + 1900,
	         tm.tm_hour,
	         tm.tm_min,
	         tm.tm_sec);

	return buf;
}

void init_unicorn_httpdate(void)
{
	VALUE mod = rb_const_get(rb_cObject, rb_intern("Unicorn"));
	mod = rb_define_module_under(mod, "HttpResponse");
	init_buf();

	/*
	 * initialize, gmtime_r uses a lot of stack on FreeBSD for
	 * loading tzinfo data, so this allows a Ruby implementation
	 * to use * smaller thread stacks in child threads.
	 */
	httpdate(Qnil);

	rb_define_method(mod, "httpdate", httpdate, 0);
}
