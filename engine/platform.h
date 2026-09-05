#ifndef LEMON_PLATFORM_H
#define LEMON_PLATFORM_H
#include <stdint.h>
typedef void (*LemonFrameSink)(const uint32_t *rgb, unsigned width, unsigned height);
typedef int (*LemonDialogSink)(const char *title, const char *body, int allow_trial, char *name,
                               char *code);
typedef void (*LemonKeyboardSink)(int visible, int x, int y, int width, int height);
typedef int (*LemonURLSink)(const char *url);
void lemon_url_configure(LemonURLSink sink);
void lemon_keyboard_configure(LemonKeyboardSink sink);
void lemon_configure(const char *resources, const char *saves, LemonFrameSink frame,
                     LemonDialogSink dialog);
void lemon_touch(int x, int y, int phase);
void lemon_key(unsigned character);
void lemon_set_active(int active);
int lemon_run(const char *image_path);
#endif
