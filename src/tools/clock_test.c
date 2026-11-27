/*
 * clock_test: do the kernel's clocks and timers agree? Prints each clock's reading, then sleeps on each kind of timer
 * (kevent relative and absolute, on the absolute and the continuous clock; dispatch on the uptime and the monotonic
 * clock) and says how long each really took. A timer that "sleeps" 0 ms is a busy loop for whoever waits on it.
 *
 * usage: clock_test [MS]      each sleep MS milliseconds (default 300)
 */
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/event.h>
#include <time.h>
#include <unistd.h>

#ifndef DISPATCH_MONOTONICTIME_NOW
#define DISPATCH_MONOTONICTIME_NOW (1ull << 63)  /* libdispatch: the continuous clock (older SDK headers lack it) */
#endif

static mach_timebase_info_data_t tb;

static uint64_t
ns(uint64_t ticks)
{
	return ticks * tb.numer / tb.denom;
}

static void
kq_sleep(const char *what, int kq, uint32_t fflags, int64_t data)
{
	struct kevent64_s ev, out;
	uint64_t t0 = mach_continuous_time();

	EV_SET64(&ev, 1, EVFILT_TIMER, EV_ADD | EV_ONESHOT, fflags, data, 0, 0, 0);
	int n = kevent64(kq, &ev, 1, &out, 1, 0, NULL);
	printf("%-44s took %6llu ms (kevent %d)\n", what, ns(mach_continuous_time() - t0) / 1000000, n);
}

static void
dispatch_sleep(const char *what, dispatch_time_t when)
{
	dispatch_semaphore_t s = dispatch_semaphore_create(0);
	uint64_t t0 = mach_continuous_time();

	dispatch_after(when, dispatch_get_global_queue(0, 0), ^{ dispatch_semaphore_signal(s); });
	dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);
	printf("%-44s took %6llu ms\n", what, ns(mach_continuous_time() - t0) / 1000000);
}

int
main(int argc, char **argv)
{
	int64_t ms = argc > 1 ? atoll(argv[1]) : 300;
	int kq = kqueue();

	mach_timebase_info(&tb);
	printf("timebase %u/%u\n", tb.numer, tb.denom);
	printf("mach_absolute_time   %llu ns\n", ns(mach_absolute_time()));
	printf("mach_continuous_time %llu ns\n", ns(mach_continuous_time()));
	printf("mach_approx / cont   %llu / %llu ns\n", ns(mach_approximate_time()), ns(mach_continuous_approximate_time()));
	printf("UPTIME_RAW %llu  MONOTONIC_RAW %llu  MONOTONIC %llu ns\n", clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
	    clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), clock_gettime_nsec_np(CLOCK_MONOTONIC));

	kq_sleep("kevent relative, absolute clock", kq, 0, ms);
	kq_sleep("kevent relative, continuous clock", kq, NOTE_MACH_CONTINUOUS_TIME, ms);
	kq_sleep("kevent absolute deadline, absolute clock", kq, NOTE_ABSOLUTE | NOTE_MACHTIME,
	    (int64_t)(mach_absolute_time() + ms * 1000000 * tb.denom / tb.numer));
	kq_sleep("kevent absolute deadline, continuous clock", kq, NOTE_ABSOLUTE | NOTE_MACHTIME | NOTE_MACH_CONTINUOUS_TIME,
	    (int64_t)(mach_continuous_time() + ms * 1000000 * tb.denom / tb.numer));
	dispatch_sleep("dispatch_after, uptime clock", dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC));
	dispatch_sleep("dispatch_after, monotonic (continuous) clock", dispatch_time(DISPATCH_MONOTONICTIME_NOW, ms * NSEC_PER_MSEC));
	dispatch_sleep("dispatch_after, wall clock", dispatch_walltime(NULL, ms * NSEC_PER_MSEC));
	return 0;
}
