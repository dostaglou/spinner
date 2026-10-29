/* Deterministic macOS regression for the already-raised GC barrier at the
 * blocking-event-wait boundary. Compile with -DTEST_SCHED_SOURCE='"..."'.
 * This object replaces sp_sched.o in a TEST COPY of the runtime archive.
 * The wrapper counts a blocking kevent attempt without actually sleeping. */
#include <sys/types.h>
#include <sys/event.h>
#include <time.h>
static int test_watch_wait, test_blocking_waits;
static int test_kevent(int, const struct kevent *, int, struct kevent *, int,
                       const struct timespec *);
#define kevent(...) test_kevent(__VA_ARGS__)
#include TEST_SCHED_SOURCE
#undef kevent

static int test_kevent(int fd, const struct kevent *changes, int nchanges,
                       struct kevent *events, int nevents,
                       const struct timespec *timeout) {
  if (test_watch_wait && events && nevents > 0 && timeout &&
      (timeout->tv_sec > 0 || timeout->tv_nsec > 0)) {
    test_blocking_waits++;
    return 0;
  }
  return kevent(fd, changes, nchanges, events, nevents, timeout);
}

__attribute__((constructor)) static void test_gc_before_event_wait(void) {
  int fd = kqueue();
  int pipes[2];
  if (fd < 0 || pipe(pipes) != 0) _exit(97);
  for (int i = 0; i < 2; i++)
    fcntl(pipes[i], F_SETFL, fcntl(pipes[i], F_GETFL) | O_NONBLOCK);
  g_wslot[0].evfd = fd;
  g_wslot[0].kick[0] = pipes[0];
  g_wslot[0].kick[1] = pipes[1];
  /* The notification has already been drained, and the scheduler lock has
     been reacquired with GC active. The only valid next step is to return
     to the caller's barrier check; entering a readiness wait loses the wake. */
  SCHED_LOCK();
  g_stw_active = 1;
  test_watch_wait = 1;
  (void)sp_ev_worker_wait(0, 50);
  test_watch_wait = 0;
  g_stw_active = 0;
  SCHED_UNLOCK();
  close(pipes[0]);
  close(pipes[1]);
  close(fd);
  g_wslot[0].evfd = 0;
  g_wslot[0].kick_armed = 0;
  g_wslot[0].ev_waiting = 0;
  g_wslot[0].parked = 0;
  if (test_blocking_waits) {
    fprintf(stderr, "GC_WAIT_GUARD_FAILED blocking_waits=%d\n", test_blocking_waits);
    _exit(98);
  }
  fprintf(stderr, "GC_WAIT_GUARD_OK\n");
}
