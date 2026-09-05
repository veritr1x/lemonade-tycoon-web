/* Native PCM sample mixer for the game's FMOD 3 sample API calls. */
#include "audio.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#define MAX_SAMPLES 256
#define MAX_CHANNELS 64
typedef struct {
  float *data;
  unsigned frames, channels;
} Sample;
typedef struct {
  int sample, playing, paused, mute, loop, priority;
  float volume;
  double frequency, position;
  int direction;
} Channel;
static Sample samples[MAX_SAMPLES];
static Channel channels[MAX_CHANNELS];
static unsigned channel_limit = 32;
static int initialized;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
__attribute__((weak)) int lemon_audio_start(void) { return 0; }
__attribute__((weak)) void lemon_audio_stop(void) {}
int lemon_audio_initialize(unsigned count) {
  if (!count || count > MAX_CHANNELS)
    count = MAX_CHANNELS;
  channel_limit = count;
  initialized = lemon_audio_start();
  return initialized;
}
void lemon_audio_close(void) {
  lemon_audio_stop();
  pthread_mutex_lock(&lock);
  memset(channels, 0, sizeof(channels));
  for (int i = 0; i < MAX_SAMPLES; i++) {
    free(samples[i].data);
    memset(&samples[i], 0, sizeof(Sample));
  }
  initialized = 0;
  pthread_mutex_unlock(&lock);
}
uint32_t lemon_audio_load(const void *bytes, unsigned length, unsigned mode) {
  if (!initialized)
    return 0;
  unsigned bits = (mode & 16) ? 16 : 8, ch = (mode & 64) ? 2 : 1, frames = length / (bits / 8) / ch;
  if (!frames)
    return 0;
  float *data = malloc(frames * ch * sizeof(float));
  if (!data)
    return 0;
  const uint8_t *raw = bytes;
  for (unsigned i = 0; i < frames * ch; i++) {
    int v;
    if (bits == 8)
      v = (mode & 128) ? (int)raw[i] - 128 : (int8_t)raw[i];
    else {
      uint16_t n = raw[i * 2] | raw[i * 2 + 1] << 8;
      v = (mode & 128) ? (int)n - 32768 : (int16_t)n;
    }
    data[i] = v / (bits == 8 ? 128.f : 32768.f);
  }
  pthread_mutex_lock(&lock);
  unsigned slot;
  for (slot = 0; slot < MAX_SAMPLES; slot++)
    if (!samples[slot].data)
      break;
  if (slot < MAX_SAMPLES)
    samples[slot] = (Sample){data, frames, ch};
  pthread_mutex_unlock(&lock);
  if (slot == MAX_SAMPLES) {
    free(data);
    return 0;
  }
  return 0x50000 + slot;
}
int lemon_audio_free(uint32_t handle) {
  if (handle < 0x50000 || handle >= 0x50000 + MAX_SAMPLES)
    return 0;
  unsigned i = handle - 0x50000;
  pthread_mutex_lock(&lock);
  for (unsigned c = 0; c < channel_limit; c++)
    if (channels[c].sample == i)
      channels[c].playing = 0;
  free(samples[i].data);
  memset(&samples[i], 0, sizeof(Sample));
  pthread_mutex_unlock(&lock);
  return 1;
}
int lemon_audio_play(int channel, uint32_t handle, int paused) {
  if (!initialized || handle < 0x50000 || handle >= 0x50000 + MAX_SAMPLES)
    return -1;
  pthread_mutex_lock(&lock);
  int sample = handle - 0x50000;
  if (!samples[sample].data) {
    pthread_mutex_unlock(&lock);
    return -1;
  }
  if (channel == -1) {
    for (channel = 0; channel < channel_limit; channel++)
      if (!channels[channel].playing)
        break;
  }
  if (channel < 0 || channel >= channel_limit) {
    pthread_mutex_unlock(&lock);
    return -1;
  }
  channels[channel] = (Channel){.sample = sample,
                                .playing = 1,
                                .paused = paused,
                                .volume = 1,
                                .frequency = 44100,
                                .direction = 1,
                                .priority = 128};
  pthread_mutex_unlock(&lock);
  return channel;
}
/* Properties: stop, pause, mute, loop mode, volume 0..255, Hz, priority. */
int lemon_audio_control(int channel, int property, int value) {
  if (channel != -3 && (channel < 0 || channel >= channel_limit))
    return 0;
  pthread_mutex_lock(&lock);
  unsigned first = channel == -3 ? 0 : channel, end = channel == -3 ? channel_limit : channel + 1;
  for (unsigned i = first; i < end; i++) {
    Channel *c = &channels[i];
    switch (property) {
    case 0:
      c->playing = 0;
      break;
    case 1:
      c->paused = !!value;
      break;
    case 2:
      c->mute = !!value;
      break;
    case 3:
      c->loop = value & 6;
      break;
    case 4:
      c->volume = fmaxf(0, fminf(1, value / 255.f));
      break;
    case 5:
      if (value > 0)
        c->frequency = value;
      break;
    case 6:
      c->priority = value;
      break;
    }
  }
  pthread_mutex_unlock(&lock);
  return 1;
}
int lemon_audio_playing(int channel) {
  if (channel < 0 || channel >= channel_limit)
    return 0;
  pthread_mutex_lock(&lock);
  int result = channels[channel].playing;
  pthread_mutex_unlock(&lock);
  return result;
}
void lemon_audio_render(float *left, float *right, unsigned frames, double rate) {
  memset(left, 0, frames * sizeof(float));
  memset(right, 0, frames * sizeof(float));
  if (pthread_mutex_trylock(&lock))
    return;
  for (unsigned index = 0; index < channel_limit; index++) {
    Channel *c = &channels[index];
    if (!c->playing || c->paused)
      continue;
    Sample *s = &samples[c->sample];
    if (!s->data)
      continue;
    for (unsigned frame = 0; frame < frames; frame++) {
      if (c->position >= s->frames || c->position < 0) {
        if (c->loop & 4) {
          c->direction = -c->direction;
          c->position = c->position < 0 ? -c->position : 2 * (s->frames - 1) - c->position;
        } else if (c->loop & 2)
          c->position = fmod(c->position, s->frames);
        else {
          c->playing = 0;
          break;
        }
      }
      if (c->position < 0 || c->position >= s->frames) {
        c->playing = 0;
        break;
      }
      unsigned a = c->position, b = a + 1 < s->frames ? a + 1 : ((c->loop & 2) ? 0 : a);
      float t = c->position - a, v = c->mute ? 0 : c->volume;
      float l = s->data[a * s->channels] * (1 - t) + s->data[b * s->channels] * t,
            r = s->channels == 1 ? l : s->data[a * 2 + 1] * (1 - t) + s->data[b * 2 + 1] * t;
      left[frame] += l * v;
      right[frame] += r * v;
      c->position += c->direction * c->frequency / rate;
    }
  }
  for (unsigned i = 0; i < frames; i++) {
    left[i] = fmaxf(-1, fminf(1, left[i]));
    right[i] = fmaxf(-1, fminf(1, right[i]));
  }
  pthread_mutex_unlock(&lock);
}
