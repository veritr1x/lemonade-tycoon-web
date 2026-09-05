#ifndef LEMON_AUDIO_H
#define LEMON_AUDIO_H
#include <stdint.h>
int lemon_audio_start(void);
void lemon_audio_stop(void);
int lemon_audio_initialize(unsigned channels);
void lemon_audio_close(void);
uint32_t lemon_audio_load(const void *bytes, unsigned length, unsigned mode);
int lemon_audio_free(uint32_t sample);
int lemon_audio_play(int channel, uint32_t sample, int paused);
int lemon_audio_control(int channel, int property, int value);
int lemon_audio_playing(int channel);
void lemon_audio_render(float *left, float *right, unsigned frames, double rate);
#endif
