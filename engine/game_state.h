/* HUD bindings for the pinned cold image. Included only by platform.c.
 * Keep guest addresses here so every host uses the same copied game state. */
#include "game.h"
static const uint32_t GAME_MODEL = 0x47dbd4;
static const uint32_t GAME_VIEW = 0x4d3060;
static pthread_mutex_t game_lock = PTHREAD_MUTEX_INITIALIZER;
static LemonGameState game_snapshot;

void lemon_game_state(LemonGameState *state) {
  if (!state)
    return;
  pthread_mutex_lock(&game_lock);
  *state = game_snapshot;
  pthread_mutex_unlock(&game_lock);
}
static int game_visible(CPU *c, uint32_t widget) { return (rd(c, widget + 8, 32) & 1) != 0; }
static void game_read(CPU *c, LemonGameState *s) {
  s->loaded = rd(c, GAME_MODEL, 32) == 0x464a64 && game_visible(c, GAME_VIEW);
  // Alerts and confirmations must remain visible in the full original view.
  s->modal_open = game_visible(c, 0x484724) || !!rd(c, 0x4791d8, 8);
  // Recipe's navigation button has state 8 during selling and end-of-day flow.
  s->can_manage = s->loaded && rd(c, 0x4d3bc8 + 0x84, 32) != 8 && !s->modal_open;
  s->cash_cents = rd(c, GAME_MODEL + 0x54, 32);
  s->price_cents = rd(c, GAME_MODEL + 0x50, 32);
}
static void game_sync(CPU *c) {
  LemonGameState state = {0};
  game_read(c, &state);
  pthread_mutex_lock(&game_lock);
  game_snapshot = state;
  pthread_mutex_unlock(&game_lock);
}
static void game_reset(void) {
  pthread_mutex_lock(&game_lock);
  memset(&game_snapshot, 0, sizeof(game_snapshot));
  pthread_mutex_unlock(&game_lock);
}
