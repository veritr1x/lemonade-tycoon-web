#include "../lifecycle.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>
#include <sched.h>

static _Atomic uint64_t now;
static atomic_int entered, returned;
uint64_t lemon_monotonic_ns(void) { return atomic_load(&now); }
static void advance(uint64_t ms) { atomic_fetch_add(&now, ms * 1000000); }
static void *worker(void *unused) {
  atomic_store(&entered, 1);
  lemon_lifecycle_wait();
  atomic_store(&returned, 1);
  return NULL;
}
int main(void) {
  alarm(5); /* A missing resume signal must fail instead of hanging the suite. */
  advance(1000);
  assert(lemon_lifecycle_ticks() == 1000);
  lemon_lifecycle_set_active(0);
  advance(60000);
  assert(lemon_lifecycle_ticks() == 1000);
  lemon_lifecycle_set_active(0); /* Duplicate inactive notifications are harmless. */
  advance(2000);
  assert(lemon_lifecycle_ticks() == 1000);
  pthread_t thread;
  assert(!pthread_create(&thread, NULL, worker, NULL));
  while (!atomic_load(&entered))
    sched_yield();
  usleep(20000);
  assert(!atomic_load(&returned));
  lemon_lifecycle_set_active(1);
  assert(!pthread_join(thread, NULL));
  assert(atomic_load(&returned));
  assert(lemon_lifecycle_ticks() == 1000);
  advance(25);
  lemon_lifecycle_set_active(1);
  assert(lemon_lifecycle_ticks() == 1025);
  lemon_lifecycle_set_active(0);
  advance(90000);
  lemon_lifecycle_set_active(1);
  assert(lemon_lifecycle_ticks() == 1025);
  advance((1ull << 32) - 1000);
  assert(lemon_lifecycle_ticks() == 25);
  alarm(0);
  puts("PASS: inactive clock freeze, repeated transitions, resume wakeup, active elapsed time, "
       "32-bit tick wrap");
}
