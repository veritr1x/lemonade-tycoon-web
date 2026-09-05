#ifndef LEMON_LIFECYCLE_H
#define LEMON_LIFECYCLE_H
#include <stdint.h>
/* Host clock for scheduling; unlike guest ticks, this continues while paused. */
uint64_t lemon_monotonic_ns(void);
void lemon_lifecycle_set_active(int active);
void lemon_lifecycle_wait(void);
uint32_t lemon_lifecycle_ticks(void);
#endif
