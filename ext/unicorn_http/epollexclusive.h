/*
 * This is only intended for use inside a unicorn worker, nowhere else.
 * EPOLLEXCLUSIVE somewhat mitigates the thundering herd problem for
 * mostly idle processes since we can't use blocking accept4.
 * This is NOT intended for use with multi-threaded servers, nor
 * single-threaded multi-client ("C10K") servers or anything advanced
 * like that.  This use of epoll is only appropriate for a primitive,
 * single-client, single-threaded servers like unicorn that need to
 * support SIGKILL timeouts and parent death detection.
 */
#if defined(HAVE_EPOLL_CREATE1)
#  include <sys/epoll.h>
#  include <errno.h>
#  include <ruby/io.h>
#  include <ruby/thread.h>
#endif /* __linux__ */

#if defined(EPOLLEXCLUSIVE) && defined(HAVE_EPOLL_CREATE1)
#  define USE_EPOLL (1)
#else
#  define USE_EPOLL (0)
#endif

#if USE_EPOLL
/*
 * :nodoc:
 * returns IO object if EPOLLEXCLUSIVE works and arms readers
 */
static VALUE prep_readers(VALUE cls, VALUE readers)
{
	long i;
	int epfd = epoll_create1(EPOLL_CLOEXEC);
	VALUE epio;

	if (epfd < 0) rb_sys_fail("epoll_create1");

	epio = rb_funcall(cls, rb_intern("for_fd"), 1, INT2NUM(epfd));

	Check_Type(readers, T_ARRAY);
	for (i = 0; i < RARRAY_LEN(readers); i++) {
		int rc;
		struct epoll_event e;
		rb_io_t *fptr;
		VALUE io = rb_ary_entry(readers, i);

		e.data.u64 = i; /* the reason readers shouldn't change */

		/*
		 * I wanted to use EPOLLET here, but maintaining our own
		 * equivalent of ep->rdllist in Ruby-space doesn't fit
		 * our design at all (and the kernel already has it's own
		 * code path for doing it).  So let the kernel spend
		 * cycles on maintaining level-triggering.
		 */
		e.events = EPOLLEXCLUSIVE | EPOLLIN;
		io = rb_io_get_io(io);
		GetOpenFile(io, fptr);
		rc = epoll_ctl(epfd, EPOLL_CTL_ADD, fptr->fd, &e);
		if (rc < 0) rb_sys_fail("epoll_ctl");
	}
	return epio;
}
#endif /* USE_EPOLL */

#if USE_EPOLL
struct ep_wait {
	struct epoll_event *events;
	rb_io_t *fptr;
	int maxevents;
	int timeout_msec;
};

static void *do_wait(void *ptr) /* runs w/o GVL */
{
	struct ep_wait *epw = ptr;

	return (void *)(long)epoll_wait(epw->fptr->fd, epw->events,
				epw->maxevents, epw->timeout_msec);
}

/* :nodoc: */
/* readers must not change between prepare_readers and get_readers */
static VALUE
get_readers(VALUE epio, VALUE ready, VALUE readers, VALUE timeout_msec)
{
	struct ep_wait epw;
	long i, n;
	VALUE buf;

	Check_Type(ready, T_ARRAY);
	Check_Type(readers, T_ARRAY);
	epw.maxevents = RARRAY_LENINT(readers);
	buf = rb_str_buf_new(sizeof(struct epoll_event) * epw.maxevents);
	epw.events = (struct epoll_event *)RSTRING_PTR(buf);
	epio = rb_io_get_io(epio);
	GetOpenFile(epio, epw.fptr);

	epw.timeout_msec = NUM2INT(timeout_msec);
	n = (long)rb_thread_call_without_gvl(do_wait, &epw, RUBY_UBF_IO, NULL);
	if (n < 0) {
		if (errno != EINTR) rb_sys_fail("epoll_wait");
		n = 0;
	}
	/* Linux delivers events in order received */
	for (i = 0; i < n; i++) {
		struct epoll_event *ev = &epw.events[i];
		VALUE obj = rb_ary_entry(readers, ev->data.u64);

		if (RTEST(obj))
			rb_ary_push(ready, obj);
	}
	rb_str_resize(buf, 0);
	return Qfalse;
}
#endif /* USE_EPOLL */

static void init_epollexclusive(VALUE mUnicorn)
{
#if USE_EPOLL
	VALUE cWaiter = rb_define_class_under(mUnicorn, "Waiter", rb_cIO);
	rb_define_singleton_method(cWaiter, "prep_readers", prep_readers, 1);
	rb_define_method(cWaiter, "get_readers", get_readers, 3);
#endif
}
