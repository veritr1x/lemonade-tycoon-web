/* Emscripten host: adapt the shared engine to the browser's event loop.
 * platform.c is included once here so startup, cleanup, and the guest message
 * queue remain internal implementation details instead of a second public API.
 */
#include <emscripten.h>
#include "../../engine/platform.c"

static const uint32_t GAME_ENTRY = 0x44fb6b; /* Original CRT startup. */
static const uint32_t RETURN_SENTINEL = 0xeeeeeeee;
static CPU web_cpu;
static uint32_t web_pc;
static int web_running, web_active = 1;

/* EM_JS bodies run in JavaScript. ports/web/app.js owns DOM, audio, and persistence.
 * Mask each color byte before storing into a clamped array; high bits would
 * otherwise turn the green/blue components white.
 */
// clang-format off
EM_JS(void, web_frame, (const uint32_t *pixels, unsigned w, unsigned h), {
  const rgba = new Uint8ClampedArray(w * h * 4);
  const src = HEAPU32.subarray(pixels >>> 2, (pixels >>> 2) + w * h);
  for (let i = 0; i < src.length; i++) {
    const color = src[i], offset = i * 4;
    rgba[offset] = (color >>> 16) & 255;
    rgba[offset + 1] = (color >>> 8) & 255;
    rgba[offset + 2] = color & 255;
    rgba[offset + 3] = 255;
  }
  Module['onGameFrame'](rgba, w, h);
});
EM_JS(void, web_keyboard, (int visible, int x, int y, int w, int h), {
  Module['onGameKeyboard'](visible, x, y, w, h);
});
EM_JS(int, web_url, (const char *url), {
  return Module['onGameURL'](UTF8ToString(url));
});
EM_JS(void, web_stopped, (int failed), { Module['onGameStopped'](failed); });
EM_JS(void, web_audio_stop, (), { Module['onGameAudioStop'](); });
EM_JS(void, web_pcm, (float *left, float *right, unsigned count), {
  Module['onGameAudio'](
    HEAPF32.subarray(left >>> 2, (left >>> 2) + count),
    HEAPF32.subarray(right >>> 2, (right >>> 2) + count)
  );
});
EM_JS(void, web_message, (const char *title, const char *body), {
  alert(UTF8ToString(title) + '\n\n' + UTF8ToString(body));
});
EM_JS(void, web_state, (int loaded, int editable, int modal, int cash, int price), {
  Module['onGameState']({loaded:!!loaded, canManage:!!editable, modal:!!modal, cash, price});
});
EM_JS(void, web_save_state, (unsigned revision, int result, int available, double saved), {
  Module['onSaveState']({revision,result,available,saved});
});
// clang-format on

EMSCRIPTEN_KEEPALIVE void lemon_web_read_state(void) {
  LemonGameState s;
  lemon_game_state(&s);
  web_state(s.loaded, s.can_manage, s.modal_open, s.cash_cents, s.price_cents);
  LemonSaveStatus saves;
  lemon_save_status("/saves", &saves);
  web_save_state(saves.revision, saves.result, saves.available, saves.saved_at);
}
EMSCRIPTEN_KEEPALIVE int lemon_web_export(unsigned source) {
  return lemon_save_export("/saves", "/transfer.lemonade-save", source);
}
EMSCRIPTEN_KEEPALIVE int lemon_web_import(int validate_only) {
  return validate_only ? lemon_save_validate("/import.lemonade-save")
                       : lemon_save_import("/saves", "/import.lemonade-save");
}
static int web_dialog(const char *title, const char *body, int trial, char *name, char *code) {
  web_message(title, body);
  return 2; /* Win32 IDCANCEL: close an OS-level error dialog. */
}

int lemon_audio_start(void) { return 1; }
void lemon_audio_stop(void) { web_audio_stop(); }

EMSCRIPTEN_KEEPALIVE int lemon_web_start(void) {
  if (web_running)
    return 0;
  lemon_configure("/Game", "/saves", web_frame, web_dialog);
  lemon_keyboard_configure(web_keyboard);
  lemon_url_configure(web_url);
  web_cpu = (CPU){0};
  if (prepare_run(&web_cpu, "/cold-memory.bin"))
    return 0;
  web_pc = GAME_ENTRY;
  web_running = 1;
  return 1;
}

/* Keep the guest program counter between frames. Return to the browser so it
 * can paint and process input. Stop at Sleep or after roughly 8 ms; a single
 * dispatch cannot be preempted, so this is a cooperative scheduling budget.
 */
EMSCRIPTEN_KEEPALIVE void lemon_web_step(void) {
  if (!web_running || !web_active)
    return;
  if (browser_ready_at && lemon_monotonic_ns() < browser_ready_at)
    return;
  browser_yield = 0;
  double until = emscripten_get_now() + 8;
  unsigned dispatches = 0;
  do {
    if (web_cpu.fault || web_cpu.halted || web_pc == RETURN_SENTINEL) {
      int failed = web_cpu.fault || (web_cpu.halted && web_cpu.exit_code);
      fprintf(stderr, "Browser engine stopped: fault=%08x exit=%u\n", web_cpu.fault,
              web_cpu.exit_code);
      finish_run(&web_cpu);
      web_running = 0;
      web_stopped(failed);
      return;
    }
    web_pc = game_dispatch(&web_cpu, web_pc);
    // Crossing into JS for a timestamp on every tiny translated call dominated
    // the profile. Check once per 32 calls; Sleep still yields immediately.
    // A single translated call is non-preemptible, as before.
  } while (!browser_yield && (++dispatches % 32 || emscripten_get_now() < until));
}

EMSCRIPTEN_KEEPALIVE void lemon_web_active(int active) {
  web_active = !!active;
  browser_ready_at = 0;
  lemon_set_active(active);
}

/* Finish queued input and its redraw inside the DOM gesture. A field first
 * focused in a later animation frame may not open the mobile keyboard. Bound
 * the extra work to avoid monopolizing the browser's main thread.
 */
EMSCRIPTEN_KEEPALIVE void lemon_web_flush_input(void) {
  double until = emscripten_get_now() + 50;
  unsigned before = frame_count;
  do {
    // A real input gesture can bypass the frame limiter to open the keyboard.
    browser_ready_at = 0;
    lemon_web_step();
  } while (web_running && web_active &&
           (!browser_yield || message_head < message_tail || frame_count == before) &&
           emscripten_get_now() < until);
  if (web_running && !web_cpu.fault)
    sync_keyboard(&web_cpu);
}

/* The JS host copies these temporary channels into an AudioBuffer before the
 * next render overwrites them. Samples are stereo float32 at 44.1 kHz.
 */
EMSCRIPTEN_KEEPALIVE void lemon_web_audio(unsigned count) {
  static float left[4096], right[4096];
  if (count > 4096)
    count = 4096;
  lemon_audio_render(left, right, count, 44100);
  web_pcm(left, right, count);
}
