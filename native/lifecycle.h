#ifndef LEMON_LIFECYCLE_H
#define LEMON_LIFECYCLE_H
#include <stdint.h>
void lemon_lifecycle_set_active(int active);
void lemon_lifecycle_wait(void);
uint32_t lemon_lifecycle_ticks(void);
#endif
