#include "../audio.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int lemon_audio_start(void) { return 1; }
void lemon_audio_stop(void) {}
static void near(float a, float b) { assert(fabsf(a - b) < 0.00001f); }
int main(void) {
  assert(lemon_audio_initialize(4));
  uint8_t pcm[] = {0, 64, 128, 192, 255};
  uint32_t sample = lemon_audio_load(pcm, 5, 8 | 32 | 128);
  assert(sample);
  int ch = lemon_audio_play(-1, sample, 1);
  assert(ch == 0);
  float l[16], r[16];
  lemon_audio_render(l, r, 4, 44100);
  for (int i = 0; i < 4; i++)
    near(l[i], 0);
  assert(lemon_audio_playing(ch));
  lemon_audio_control(ch, 1, 0);
  lemon_audio_render(l, r, 8, 44100);
  float expected[] = {-1, -.5, 0, .5, 127.f / 128, 0, 0, 0};
  for (int i = 0; i < 8; i++) {
    near(l[i], expected[i]);
    near(r[i], l[i]);
  }
  assert(!lemon_audio_playing(ch));
  ch = lemon_audio_play(-1, sample, 0);
  lemon_audio_control(ch, 3, 2);
  lemon_audio_control(ch, 5, 22050);
  lemon_audio_render(l, r, 12, 44100);
  near(l[1], -.75);
  near(l[10], -1);
  assert(lemon_audio_playing(ch));
  lemon_audio_control(ch, 2, 1);
  lemon_audio_render(l, r, 4, 44100);
  for (int i = 0; i < 4; i++)
    near(l[i], 0);
  lemon_audio_free(sample);
  assert(!lemon_audio_playing(ch));
  lemon_audio_close();
  puts("PASS: unsigned PCM, pause/resume, end-of-sample, stereo output, looping, resampling, mute, "
       "free while playing");
}
