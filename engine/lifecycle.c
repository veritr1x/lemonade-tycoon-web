#include "lifecycle.h"
#include <pthread.h>
#include <time.h>

static pthread_mutex_t lifecycle_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t lifecycle_changed = PTHREAD_COND_INITIALIZER;
static int lifecycle_active = 1;
static uint64_t paused_at, paused_total;

/* Weak only to give the clock test a deterministic source. */
__attribute__((weak)) uint64_t lemon_monotonic_ns(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000000000ull + now.tv_nsec;
}
void lemon_lifecycle_set_active(int active) {
  pthread_mutex_lock(&lifecycle_lock);
  active = !!active;
  if (active != lifecycle_active) {
    uint64_t now = lemon_monotonic_ns();
    if (active)
      paused_total += now - paused_at;
    else
      paused_at = now;
    lifecycle_active = active;
    pthread_cond_broadcast(&lifecycle_changed);
  }
  pthread_mutex_unlock(&lifecycle_lock);
}
void lemon_lifecycle_wait(void) {
  pthread_mutex_lock(&lifecycle_lock);
  while (!lifecycle_active)
    pthread_cond_wait(&lifecycle_changed, &lifecycle_lock);
  pthread_mutex_unlock(&lifecycle_lock);
}
uint32_t lemon_lifecycle_ticks(void) {
  pthread_mutex_lock(&lifecycle_lock);
  uint64_t now = lifecycle_active ? lemon_monotonic_ns() : paused_at;
  uint32_t ticks = (now - paused_total) / 1000000;
  pthread_mutex_unlock(&lifecycle_lock);
  return ticks;
}
