#ifndef LEMON_GAME_CONFIG_H
#define LEMON_GAME_CONFIG_H
#include "runtime.h"

/* Standalone browser and native-test product configuration.
   The original program uses these globals for its full-game execution path:
   0x57f9a0 gates trial initialization and minute accounting (426296/4261cd);
   0x57f99c is queried by 4264bc for the prompt, HUD, and purchase controls.
   Apply to the private runtime image; never alter the source EXE or archives. */
static inline void lemon_game_configure(CPU *cpu) {
#if defined(LEMON_IOS) || defined(LEMON_WEB)
  wr(cpu, 0x57f9a0, 1, 32);
  wr(cpu, 0x57f99c, 0, 32);
#endif
}
#endif
