/* Exercise original controls and the copied HUD state against the real
 * game. Every run uses disposable saves, including the transfer destination. */
#define LEMON_WEB
#include "../platform.c"
#include <assert.h>
static CPU cpu;
static uint32_t pc;
static void frame(const uint32_t *rgb, unsigned w, unsigned h) {}
int lemon_audio_start(void) { return 1; }
void lemon_audio_stop(void) {}
static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}
static void advance(int ms) {
  double until = now() + ms;
  do {
    browser_yield = 0;
    do {
      assert(!cpu.fault && !cpu.halted && pc != 0xeeeeeeee);
      pc = game_dispatch(&cpu, pc);
    } while (!browser_yield);
    usleep(1000);
  } while (now() < until);
}
static void tap(int x, int y) {
  lemon_touch(x, y, 0);
  advance(100);
  lemon_touch(x, y, 2);
  advance(200);
}
static LemonGameState state(void) {
  LemonGameState s;
  lemon_game_state(&s);
  return s;
}
int main(void) {
  char temp[] = "/tmp/lemon-gameplay-XXXXXX";
  assert(mkdtemp(temp));
  lemon_configure("assets", temp, frame, NULL);
  assert(!prepare_run(&cpu, "assets/cold-memory.bin"));
  pc = 0x44fb6b;
  advance(1200);
  assert(!state().can_manage);
  tap(54, 198);
  tap(72, 280);
  for (const char *s = "TEST"; *s; s++)
    lemon_key(*s);
  lemon_key(13);
  advance(600);
  assert(state().loaded && state().can_manage && state().cash_cents == 4000);
  tap(272, 468);
  assert(state().modal_open && !state().can_manage);
  tap(440, 268);
  assert(!state().modal_open && state().can_manage);
  // Recipe and Supplies use the original bitmap buttons exclusively.
  tap(257, 80);
  unsigned lemons = rd(&cpu, GAME_MODEL + 0x4dc4 + 8, 32);
  tap(170, 244);
  assert(rd(&cpu, GAME_MODEL + 0x4dc4 + 8, 32) == lemons + 1);
  tap(294, 80);
  for (unsigned i = 0; i < 4; i++) {
    tap(50 + i * 60, 240);
    tap(244, 284);
  }
  tap(280, 412);
  assert(state().modal_open && state().cash_cents == 4000);
  tap(440, 268);
  assert(!state().modal_open && state().cash_cents == 2840);
  tap(272, 468);
  advance(800);
  assert(!state().can_manage);
  finish_run(&cpu);
  char archive[4096];
  snprintf(archive, sizeof(archive), "%s/checkpoint.lemonade-save", temp);
  assert(!lemon_save_export(temp, archive, 0));
  assert(!lemon_save_validate(archive));
  fprintf(stderr, "Transfer fixture: %s\n", archive);
  assert(!state().loaded);
  char destination[] = "/tmp/lemon-restored-XXXXXX";
  assert(mkdtemp(destination));
  assert(!lemon_save_import(destination, archive));
  lemon_configure("assets", destination, frame, NULL);
  assert(!prepare_run(&cpu, "assets/cold-memory.bin"));
  pc = 0x44fb6b;
  advance(1200);
  tap(72, 280);
  advance(500);
  assert(state().loaded && state().cash_cents == 2840);
  assert(rd(&cpu, GAME_MODEL + 0x4dc4 + 8, 32) == lemons + 1);
  finish_run(&cpu);
  puts("PASS: original recipe, purchase and Start Day controls, "
       "and portable checkpoint reload");
}
