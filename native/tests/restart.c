/* Exercise original CRT startup/teardown repeatedly in a disposable native host.
   No Simulator or user game input is injected by this test. */
#define LEMON_IOS
#include "../platform.c"
#include <assert.h>
static unsigned frames, starts, stops;
int lemon_audio_start(void) {
  starts++;
  return 1;
}
void lemon_audio_stop(void) { stops++; }
static void frame(const uint32_t *rgb, unsigned width, unsigned height) {
  assert(width == 640 && height == 480);
  if (++frames == 3)
    post(0, 0x12, 0, 0); /* Original main-loop WM_QUIT path. */
}
int main(void) {
  alarm(30);
  char temp[] = "/tmp/lemon-restart-XXXXXX";
  assert(mkdtemp(temp));
  lemon_configure("assets", temp, frame, NULL);
  for (unsigned run = 0; run < 3; run++) {
    frames = 0;
    assert(lemon_run("assets/cold-memory.bin") == 0);
    assert(frames >= 3 && starts == run + 1 && stops >= starts);
    for (unsigned i = 0; i < 256; i++)
      assert(!files[i]);
    assert(command_line >= 0x1000000 && environment_wide >= 0x1000000);
  }
  alarm(0);
  printf("PASS: three original startup/main-menu/WM_QUIT/CRT-exit runs in one process; file and "
         "audio cleanup (%s)\n",
         temp);
}
