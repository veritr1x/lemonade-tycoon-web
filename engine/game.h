#ifndef LEMON_GAME_H
#define LEMON_GAME_H
#include <stdint.h>

/* Hosts read a copied snapshot. Only the engine worker accesses original game
 * memory; UIKit and the browser never need guest addresses. Money is in cents. */
typedef struct {
  int loaded, can_manage, cash_cents, price_cents, modal_open;
} LemonGameState;
void lemon_game_state(LemonGameState *state);

#endif
