/* Win32 compatibility adapter for the translated game.
 * Guest addresses index CPU.mem; host handles index the tables below.
 * native_api decodes the guest stack and applies stdcall cleanup through RET.
 * Unsupported APIs set a guest fault rather than calling into the host OS.
 */
/* Native platform bring-up host. Unsupported services fail explicitly.
   This host is not yet the finished iOS platform layer. */
#include "runtime.h"
#include "generated/imports.h"
#include "platform.h"
#include "audio.h"
#include "save.h"
#include "game_config.h"
#include "lifecycle.h"
#include <pthread.h>
#include <time.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <strings.h>
static uint32_t heap_next = 0x1000000;
static struct {
  uint32_t addr, size, capacity;
  int live;
} allocations[65536];
static unsigned allocation_count;
static FILE *files[256];
static uint32_t last_error;
static const char *resource_dir = "assets";
static const char *save_dir = "build/userdata";
static LemonFrameSink frame_sink;
static LemonDialogSink dialog_sink;
static LemonKeyboardSink keyboard_sink;
static LemonURLSink url_sink;
void lemon_url_configure(LemonURLSink sink) { url_sink = sink; }
static uint32_t text_editor;
static int keyboard_state[5];
void lemon_keyboard_configure(LemonKeyboardSink sink) { keyboard_sink = sink; }
void native_text_focus(CPU *c, uint32_t editor, int active) {
  if (active)
    text_editor = editor;
  else if (text_editor == editor)
    text_editor = 0;
}
/* Convert the original text widget and visible parent chain into a host field. */
static void sync_keyboard(CPU *c) {
  if (!keyboard_sink)
    return;
  int state[5] = {0};
  if (text_editor && text_editor + 0x48 < c->mem_size) {
    uint32_t label = rd(c, text_editor + 0x34, 32);
    if (label && label + 0x34 < c->mem_size) {
      state[0] = 1;
      state[1] = rd(c, label + 0xc, 32);
      state[2] = rd(c, label + 0x10, 32);
      state[3] = rd(c, label + 0x14, 32);
      state[4] = rd(c, label + 0x18, 32);
      uint32_t p = label;
      unsigned depth = 0;
      while (p && depth++ < 64) {
        if (p + 0x54 >= c->mem_size || !(rd(c, p + 8, 32) & 1)) {
          state[0] = 0;
          break;
        }
        p = rd(c, p + 0x30, 32);
        if (p && p + 0x54 < c->mem_size) {
          state[1] += (int32_t)rd(c, p + 0xc, 32) - (int32_t)rd(c, p + 0x4c, 32);
          state[2] += (int32_t)rd(c, p + 0x10, 32) - (int32_t)rd(c, p + 0x50, 32);
        }
      }
      if (p || state[3] <= 0 || state[4] <= 0)
        state[0] = 0;
    }
  }
  if (!state[0])
    memset(state, 0, sizeof(state));
  if (memcmp(state, keyboard_state, sizeof(state))) {
    memcpy(keyboard_state, state, sizeof(state));
    fprintf(stderr, "Keyboard field: visible=%d rect=%d,%d,%d,%d\n", state[0], state[1], state[2],
            state[3], state[4]);
    keyboard_sink(state[0], state[1], state[2], state[3], state[4]);
  }
}
static uint32_t active_window;
#ifdef LEMON_WEB
static int browser_yield;
#endif
static uint32_t command_line, environment_wide, environment_ansi;
/* Restrict guest filenames to the resource and save directories. */
static int host_path(const char *name, int writing, char *out, size_t capacity) {
  const char *leaf = name;
  for (const char *p = name; *p; p++)
    if (*p == '\\' || *p == '/')
      leaf = p + 1;
  if (!*leaf || !strcmp(leaf, ".") || !strcmp(leaf, ".."))
    return 0;
  int bundle = !strcasecmp(leaf, "Lemonade.RB") || !strcasecmp(leaf, "Lemonade.exe");
  if (writing && bundle)
    return 0;
  const char *canonical = !strcasecmp(leaf, "Lemonade.RB")    ? "Lemonade.RB"
                          : !strcasecmp(leaf, "Lemonade.exe") ? "Lemonade.exe"
                                                              : leaf;
  snprintf(out, capacity, "%s/%s", bundle ? resource_dir : save_dir, canonical);
  return 1;
}
static FILE *file_handle(uint32_t h) { return h >= 0x400 && h < 0x500 ? files[h - 0x400] : NULL; }
static uint64_t api_counts[API_COUNT];
typedef struct {
  int kind, width, height, bits, stride, topdown;
  uint32_t pixels, palette, selected, color, masks[3];
} Gdi;
static Gdi gdi[1024];
static unsigned frame_count;
static uint32_t screen[640 * 480];
static uint32_t gdi_new(int kind) {
  for (unsigned i = 1; i < 1024; i++)
    if (!gdi[i].kind) {
      memset(&gdi[i], 0, sizeof(Gdi));
      gdi[i].kind = kind;
      return 0x20000 + i;
    }
  return 0;
}
static Gdi *gdi_get(uint32_t h) {
  return h >= 0x20000 && h < 0x20400 && gdi[h - 0x20000].kind ? &gdi[h - 0x20000] : NULL;
}
static uint32_t channel(uint32_t p, uint32_t mask) {
  if (!mask)
    return 0;
  unsigned s = __builtin_ctz(mask);
  return ((p & mask) >> s) * 255 / (mask >> s);
}
static uint32_t pixel(CPU *c, Gdi *b, int x, int y) {
  if (x < 0 || y < 0 || x >= b->width || y >= b->height)
    return 0;
  uint32_t row = b->pixels + (b->topdown ? y : b->height - 1 - y) * b->stride, p;
  if (b->bits == 16 || b->bits == 32) {
    p = rd(c, row + x * (b->bits / 8), b->bits);
    return channel(p, b->masks[0]) << 16 | channel(p, b->masks[1]) << 8 | channel(p, b->masks[2]);
  }
  if (b->bits == 24)
    return rd(c, row + x * 3, 8) | (rd(c, row + x * 3 + 1, 8) << 8) |
           (rd(c, row + x * 3 + 2, 8) << 16);
  if (b->bits == 8)
    p = rd(c, row + x, 8);
  else if (b->bits == 4)
    p = (rd(c, row + x / 2, 8) >> ((1 - x % 2) * 4)) & 15;
  else
    p = (rd(c, row + x / 8, 8) >> (7 - x % 8)) & 1;
  return rd(c, b->palette + p * 4, 32) & 0xffffff;
}
static void save_frame(void) {
  if (frame_sink) {
    frame_sink(screen, 640, 480);
    return;
  }
  FILE *f = fopen("build/native-frame.ppm", "wb");
  if (!f)
    return;
  fprintf(f, "P6\n640 480\n255\n");
  for (int i = 0; i < 640 * 480; i++) {
    uint8_t rgb[] = {screen[i] >> 16, screen[i] >> 8, screen[i]};
    fwrite(rgb, 1, 3, f);
  }
  fclose(f);
}
typedef struct {
  uint32_t handle, id, parent, style, proc;
  int enabled, ended, result;
  char title[4096];
} Window;
static Window windows[256];
static unsigned window_count;
static struct {
  char name[256];
  uint32_t proc;
} classes[32];
static unsigned class_count;
static struct {
  uint32_t h, msg, wp, lp;
} messages[1024];
static unsigned message_head, message_tail;
static pthread_mutex_t message_lock = PTHREAD_MUTEX_INITIALIZER;
#include "game_state.h"
static void post(uint32_t h, uint32_t msg, uint32_t wp, uint32_t lp) {
  pthread_mutex_lock(&message_lock);
  if (message_tail - message_head < 1024)
    messages[message_tail++ % 1024] = (typeof(messages[0])){h, msg, wp, lp};
  pthread_mutex_unlock(&message_lock);
}
void lemon_configure(const char *resources, const char *saves, LemonFrameSink frame,
                     LemonDialogSink dialog) {
  resource_dir = resources;
  save_dir = saves;
  frame_sink = frame;
  dialog_sink = dialog;
}
void lemon_touch(int x, int y, int phase) {
  uint32_t pos = (x & 65535) | ((y & 65535) << 16);
  if (getenv("LEMON_INPUT_TRACE"))
    fprintf(stderr, "TOUCH x=%d y=%d phase=%d\n", x, y, phase);
  post(0, 0x200, phase == 2 ? 0 : 1, pos);
  if (phase == 0)
    post(0, 0x201, 1, pos);
  if (phase == 2)
    post(0, 0x202, 0, pos);
}
void lemon_key(unsigned character) { post(0, 0x102, character, 0); }
void lemon_request_quit(void) { post(0, 0x12, 0, 0); }
void lemon_set_active(int active) {
  lemon_lifecycle_set_active(active);
  post(0, 6, !!active, 0);
  fprintf(stderr, "Lifecycle: %s\n", active ? "active" : "paused");
}
static Window *window(uint32_t h) {
  for (unsigned i = 0; i < window_count; i++)
    if (windows[i].handle == h)
      return &windows[i];
  return NULL;
}
static Window *new_window(uint32_t parent, uint32_t id, uint32_t style) {
  if (window_count == 256)
    return NULL;
  Window *w = &windows[window_count++];
  w->handle = 0x10000 + window_count;
  w->parent = parent;
  w->id = id;
  w->style = style;
  w->enabled = !(style & 0x08000000);
  return w;
}
static Window *child(uint32_t parent, uint32_t id) {
  for (unsigned i = 0; i < window_count; i++)
    if (windows[i].parent == parent && windows[i].id == id)
      return &windows[i];
  return NULL;
}
/* Re-enter translated code for a Win32 window procedure, preserving its caller. */
static uint32_t callback(CPU *c, uint32_t proc, uint32_t h, uint32_t msg, uint32_t wp,
                         uint32_t lp) {
  uint32_t esp = c->esp;
  push(c, lp);
  push(c, wp);
  push(c, msg);
  push(c, h);
  push(c, 0xeeeeeeed);
  game_run(c, proc, 0xeeeeeeed);
  if (c->esp != esp && !c->fault && !c->halted) {
    fprintf(stderr, "Callback stack mismatch %08x -> %08x\n", esp, c->esp);
    fault(c, proc);
  }
  return c->eax;
}
/* Reuse released guest blocks; host pointers are never exposed to game code. */
static uint32_t alloc(CPU *c, uint32_t size) {
  if (!size)
    size = 1;
  unsigned best = 65536;
  for (unsigned i = 0; i < allocation_count; i++)
    if (!allocations[i].live && allocations[i].capacity >= size &&
        (best == 65536 || allocations[i].capacity < allocations[best].capacity))
      best = i;
  if (best != 65536) {
    allocations[best].size = size;
    allocations[best].live = 1;
    memset(c->mem + allocations[best].addr, 0, size);
    return allocations[best].addr;
  }
  uint32_t a = heap_next;
  uint64_t end = (uint64_t)a + size;
  if (end > c->mem_size || allocation_count >= 65536) {
    last_error = 8;
    return 0;
  }
  heap_next = (end + 15) & ~15u;
  memset(c->mem + a, 0, size);
  allocations[allocation_count++] = (typeof(allocations[0])){a, size, heap_next - a, 1};
  return a;
}
static uint32_t allocation_size(uint32_t a) {
  for (unsigned i = 0; i < allocation_count; i++)
    if (allocations[i].addr == a && allocations[i].live)
      return allocations[i].size;
  return 0;
}
static int release(uint32_t a) {
  if (!a)
    return 1;
  for (unsigned i = 0; i < allocation_count; i++)
    if (allocations[i].addr == a && allocations[i].live) {
      allocations[i].live = 0;
      return 1;
    }
  return 0;
}
static const char *str(CPU *c, uint32_t a) {
  if (a >= c->mem_size || !memchr(c->mem + a, 0, c->mem_size - a)) {
    fault(c, a);
    return "";
  }
  return (const char *)c->mem + a;
}
static uint32_t text(CPU *c, const char *s) {
  uint32_t a = alloc(c, strlen(s) + 1);
  memcpy(c->mem + a, s, strlen(s) + 1);
  return a;
}
static uint32_t resource_child(CPU *c, uint32_t node, uint32_t id) {
  uint32_t base = 0x593000, n = (uint32_t)rd(c, node + 12, 16) + (uint32_t)rd(c, node + 14, 16);
  for (uint32_t i = 0; i < n; i++) {
    uint32_t e = node + 16 + i * 8, key = rd(c, e, 32);
    if (!(key & 0x80000000) && key == id)
      return base + (rd(c, e + 4, 32) & 0x7fffffff);
  }
  return 0;
}
static uint32_t find_resource(CPU *c, uint32_t type, uint32_t name) {
  uint32_t a = resource_child(c, 0x593000, type);
  if (!a)
    return 0;
  uint32_t b = resource_child(c, a, name);
  if (!b)
    return 0;
  return 0x593000 + (rd(c, b + 20, 32) & 0x7fffffff);
}
static uint32_t template_string(CPU *c, uint32_t p, char *out, size_t size) {
  unsigned i = 0;
  if (rd(c, p, 16) == 0xffff) {
    if (out && size)
      out[0] = 0;
    return p + 4;
  }
  for (;; p += 2) {
    unsigned v = rd(c, p, 16);
    if (out && i + 1 < size)
      out[i++] = v < 256 ? v : '?';
    if (!v)
      break;
  }
  if (out && size)
    out[i < size ? i : size - 1] = 0;
  return p + 2;
}
static Window *dialog_create(CPU *c, uint32_t id, uint32_t parent, uint32_t proc) {
  uint32_t r = find_resource(c, 5, id);
  if (!r)
    return NULL;
  uint32_t p = 0x400000 + rd(c, r, 32), style = rd(c, p, 32), n = rd(c, p + 8, 16);
  if (rd(c, p + 2, 16) == 0xffff) {
    fprintf(stderr, "Extended dialog template unsupported\n");
    return NULL;
  }
  Window *w = new_window(parent, id, style);
  if (!w)
    return NULL;
  w->proc = proc;
  p += 18;
  p = template_string(c, p, NULL, 0);
  p = template_string(c, p, NULL, 0);
  p = template_string(c, p, w->title, sizeof(w->title));
  if (style & 0x40)
    p = template_string(c, p + 2, NULL, 0);
  for (unsigned i = 0; i < n; i++) {
    p = (p + 3) & ~3u;
    Window *v = new_window(w->handle, rd(c, p + 16, 16), rd(c, p, 32));
    if (!v)
      return NULL;
    p = template_string(c, p + 18, NULL, 0);
    p = template_string(c, p, v->title, sizeof(v->title));
    uint32_t extra = rd(c, p, 16);
    p += extra ? extra : 2;
  }
  return w;
}
static uint32_t arg(CPU *c, int i) { return rd(c, c->esp + 4 + 4 * i, 32); }
static void put(CPU *c, uint32_t a, uint32_t v) { wr(c, a, v, 32); }
#include "registry.h"
#define A(n) arg(c, n)
#define RET(value, n)                                                                              \
  do {                                                                                             \
    uint32_t lemon_api_result = (value);                                                           \
    uint32_t lemon_api_next = pop(c);                                                              \
    c->esp += 4 * (n);                                                                             \
    c->eax = lemon_api_result;                                                                     \
    return lemon_api_next;                                                                         \
  } while (0)
#define OK(n) RET(1, n)
/* Import thunks use synthetic addresses starting at 0xf0000000, one per API. */
uint32_t native_api(CPU *c, uint32_t pc) {
  if (pc < 0xf0000000u || pc >= 0xf0000000u + API_COUNT * 16 || pc % 16) {
    fault(c, pc);
    return 0;
  }
  API api = (pc - 0xf0000000u) / 16;
  if (++api_counts[api] == 1)
    fprintf(stderr, "API %s return=%08x\n", api_names[api], (uint32_t)rd(c, c->esp, 32));
  switch (api) {
  case API_Rectangle: {
    Gdi *d = gdi_get(A(0)), *b = d ? gdi_get(d->selected) : NULL;
    if (A(0) != 0x20000 || !b || b->kind != 3) {
      fault(c, pc);
      return 0;
    }
    uint32_t v = b->color, color = ((v & 255) << 16) | (v & 0xff00) | ((v >> 16) & 255);
    int l = A(1), t = A(2), r = A(3), bot = A(4);
    for (int y = t < 0 ? 0 : t; y < bot && y < 480; y++)
      for (int x = l < 0 ? 0 : l; x < r && x < 640; x++)
        screen[y * 640 + x] = color;
    OK(5);
  }
  case API_CreateFileA: {
    char path[4096];
    uint32_t desired_access = A(1), creation = A(4);
    int writing = !!(desired_access & 0x40000000);
    const char *name = str(c, A(0));
    if (!host_path(name, writing, path, sizeof(path))) {
      last_error = 5;
      RET(-1, 7);
    }
    FILE *f = NULL;
    const char *leaf = strrchr(path, '/');
    int save = writing && leaf && !strcasecmp(leaf + 1, "Lemonade.dat");
    if (save)
      f = lemon_save_open(save_dir, creation);
    else if (creation == 1) {
      if (access(path, F_OK) == 0) {
        last_error = 80;
        RET(-1, 7);
      }
      f = fopen(path, "w+b");
    } else if (creation == 2)
      f = fopen(path, "w+b");
    else if (creation == 3)
      f = fopen(path, writing ? "r+b" : "rb");
    else if (creation == 4) {
      f = fopen(path, "r+b");
      if (!f)
        f = fopen(path, "w+b");
    } else if (creation == 5) {
      f = fopen(path, "r+b");
      if (f)
        ftruncate(fileno(f), 0);
    }
    if (!f) {
      last_error = errno == ENOENT ? 2 : errno == EEXIST ? 80 : 5;
      fprintf(stderr, "FILE unavailable: %s error=%u\n", name, last_error);
      RET(-1, 7);
    }
    for (unsigned i = 0; i < 256; i++)
      if (!files[i]) {
        files[i] = f;
        fprintf(stderr, "FILE open: %s (%s)\n", name, writing ? "native save" : "read");
        RET(0x400 + i, 7);
      }
    lemon_save_close(f, 0);
    last_error = 4;
    RET(-1, 7);
  }
  case API_ReadFile: {
    FILE *f = file_handle(A(0));
    uint32_t p = A(1), n = A(2);
    if (!f || (uint64_t)p + n > c->mem_size) {
      last_error = 6;
      RET(0, 5);
    }
    size_t got = fread(c->mem + p, 1, n, f);
    if (A(3))
      put(c, A(3), got);
    RET(!ferror(f), 5);
  }
  case API_WriteFile: {
    FILE *f = file_handle(A(0));
    uint32_t p = A(1), n = A(2);
    if (!f || (uint64_t)p + n > c->mem_size) {
      last_error = 6;
      RET(0, 5);
    }
    size_t got = fwrite(c->mem + p, 1, n, f);
    if (A(3))
      put(c, A(3), got);
    RET(got == n, 5);
  }
  case API_GetFileSize: {
    FILE *f = file_handle(A(0));
    if (!f)
      RET(-1, 2);
    struct stat s;
    if (fstat(fileno(f), &s))
      RET(-1, 2);
    if (A(1))
      put(c, A(1), (uint64_t)s.st_size >> 32);
    RET(s.st_size, 2);
  }
  case API_SetFilePointer: {
    FILE *f = file_handle(A(0));
    if (!f)
      RET(-1, 4);
    int64_t off = (int32_t)A(1);
    if (A(2))
      off = ((int64_t)(int32_t)rd(c, A(2), 32) << 32) | A(1);
    if (fseeko(f, off, A(3)))
      RET(-1, 4);
    off = ftello(f);
    if (A(2))
      put(c, A(2), (uint64_t)off >> 32);
    RET(off, 4);
  }
  case API_FlushFileBuffers: {
    FILE *f = file_handle(A(0));
    RET(f && !fflush(f), 1);
  }
  case API_CloseHandle: {
    uint32_t h = A(0);
    FILE *f = file_handle(h);
    if (f) {
      int ok = lemon_save_close(f, 1);
      files[h - 0x400] = NULL;
      if (!ok) {
        last_error = 5;
        RET(0, 1);
      }
    }
    RET(f || h == 0x200, 1);
  }
  case API__FSOUND_SetMemorySystem_20:
    OK(5); /* Native audio will own its allocations. */
  case API__FSOUND_Init_12:
    RET(lemon_audio_initialize(A(1)), 3);
  case API__FSOUND_Sample_Load_16:
    if ((uint64_t)A(1) + A(3) > c->mem_size)
      RET(0, 4);
    RET(lemon_audio_load(c->mem + A(1), A(3), A(2)), 4);
  case API__FSOUND_Close_0:
    lemon_audio_close();
    RET(0, 0);
  case API__FSOUND_SetMute_8:
    RET(lemon_audio_control(A(0), 2, A(1)), 2);
  case API__FSOUND_SetPaused_8:
    RET(lemon_audio_control(A(0), 1, A(1)), 2);
  case API__FSOUND_SetLoopMode_8:
    RET(lemon_audio_control(A(0), 3, A(1)), 2);
  case API__FSOUND_SetVolume_8:
    RET(lemon_audio_control(A(0), 4, A(1)), 2);
  case API__FSOUND_SetFrequency_8:
    RET(lemon_audio_control(A(0), 5, A(1)), 2);
  case API__FSOUND_SetPriority_8:
    RET(lemon_audio_control(A(0), 6, A(1)), 2);
  case API__FSOUND_IsPlaying_4:
    RET(lemon_audio_playing(A(0)), 1);
  case API__FSOUND_StopSound_4:
    RET(lemon_audio_control(A(0), 0, 0), 1);
  case API__FSOUND_Sample_Free_4:
    RET(lemon_audio_free(A(0)), 1);
  case API__FSOUND_PlaySoundEx_16:
    RET(lemon_audio_play(A(0), A(1), A(3)), 4);
  case API_MessageBoxA: {
    if (dialog_sink) {
      char name[1024] = {0}, code[1024] = {0};
      dialog_sink(str(c, A(2)), str(c, A(1)), -1, name, code);
    } else
      fprintf(stderr, "Message: %s\n", str(c, A(1)));
    RET(1, 4);
  }
  case API_ShellExecuteA: {
    const char *verb = A(1) ? str(c, A(1)) : "open", *target = str(c, A(2));
    /* The original helper first tries a Windows browser executable, then
       retries with the URL itself. Return the documented failure so its
       existing fallback runs; iOS opens the URL using its default browser. */
    int web = !strncasecmp(target, "https://", 8) || !strncasecmp(target, "http://", 7);
    if (strcasecmp(verb, "open") || !web || !url_sink) {
      last_error = 31;
      RET(31, 6);
    }
    int opened = url_sink(target);
    if (!opened)
      last_error = 31;
    RET(opened ? 33 : 31, 6);
  }
  case API_GetDC:
    RET(0x20000, 1);
  case API_ReleaseDC:
    OK(2);
  case API_BeginPaint:
    memset(c->mem + A(1), 0, 64);
    put(c, A(1), 0x20000);
    put(c, A(1) + 16, 640);
    put(c, A(1) + 20, 480);
    RET(0x20000, 2);
  case API_EndPaint:
    OK(2);
  case API_CreateCompatibleDC:
    RET(gdi_new(1), 1);
  case API_CreateSolidBrush: {
    uint32_t h = gdi_new(3);
    Gdi *b = gdi_get(h);
    if (b)
      b->color = A(0);
    RET(h, 1);
  }
  case API_SelectObject: {
    Gdi *d = gdi_get(A(0));
    uint32_t old = d ? d->selected : 0;
    if (d)
      d->selected = A(1);
    RET(old, 2);
  }
  case API_DeleteDC:
  case API_DeleteObject: {
    Gdi *d = gdi_get(A(0));
    if (d)
      d->kind = 0;
    RET(d != NULL, 1);
  }
  case API_LoadBitmapA:
  case API_CreateDIBSection: {
    int resource = api == API_LoadBitmapA;
    uint32_t p = resource ? find_resource(c, 2, A(1)) : A(1);
    if (!p)
      RET(0, resource ? 2 : 6);
    if (resource)
      p = 0x400000 + rd(c, p, 32);
    uint32_t h = gdi_new(2);
    Gdi *b = gdi_get(h);
    if (!b)
      RET(0, resource ? 2 : 6);
    b->width = rd(c, p + 4, 32);
    int height = rd(c, p + 8, 32);
    b->topdown = height < 0;
    b->height = abs(height);
    b->bits = rd(c, p + 14, 16);
    b->stride = ((b->width * b->bits + 31) / 32) * 4;
    b->palette = p + rd(c, p, 32);
    uint32_t compression = rd(c, p + 16, 32), colors = rd(c, p + 32, 32);
    if (!colors && b->bits <= 8)
      colors = 1u << b->bits;
    if (compression == 3) {
      for (int i = 0; i < 3; i++)
        b->masks[i] = rd(c, b->palette + 4 * i, 32);
      b->palette += 12;
    } else {
      b->masks[0] = b->bits == 16 ? 0x7c00 : 0xff0000;
      b->masks[1] = b->bits == 16 ? 0x3e0 : 0xff00;
      b->masks[2] = b->bits == 16 ? 0x1f : 0xff;
    }
    if (b->width <= 0 || b->height <= 0 || b->width > 4096 || b->height > 4096) {
      fault(c, pc);
      return 0;
    }
    b->pixels = resource ? b->palette + colors * 4 : alloc(c, b->stride * b->height);
    if (!resource)
      put(c, A(3), b->pixels);
    fprintf(stderr, "BITMAP %dx%d bits=%d pixels=%08x\n", b->width, b->height, b->bits, b->pixels);
    RET(h, resource ? 2 : 6);
  }
  case API_BitBlt:
  case API_StretchBlt: {
    int stretch = api == API_StretchBlt;
    Gdi *d = gdi_get(A(5)), *b = d ? gdi_get(d->selected) : NULL;
    int x = A(1), y = A(2), w = A(3), h = A(4), sx = A(6), sy = A(7), sw = stretch ? A(8) : w,
        sh = stretch ? A(9) : h;
    uint32_t rop = A(stretch ? 10 : 8);
    if (A(0) != 0x20000 || !b || b->kind != 2 || rop != 0xcc0020) {
      fprintf(stderr, "Unsupported blit target=%08x source=%08x rop=%08x\n", A(0), A(5), rop);
      fault(c, pc);
      return 0;
    }
    for (int yy = 0; yy < h; yy++)
      for (int xx = 0; xx < w; xx++)
        if (x + xx >= 0 && x + xx < 640 && y + yy >= 0 && y + yy < 480)
          screen[(y + yy) * 640 + x + xx] =
              pixel(c, b, sx + (int64_t)xx * sw / w, sy + (int64_t)yy * sh / h);
    frame_count++;
    if (frame_sink || frame_count <= 10 || frame_count % 60 == 0)
      save_frame();
    if (frame_count <= 10 || frame_count % 60 == 0)
      fprintf(stderr, "FRAME %u steps=%u\n", frame_count, c->steps);
    OK(stretch ? 11 : 9);
  }
  case API_LoadIconA:
  case API_LoadCursorA:
    RET(0x80000000 | A(1), 2);
  case API_RegisterClassA: {
    uint32_t p = A(0);
    if (class_count >= 32)
      RET(0, 1);
    snprintf(classes[class_count].name, 256, "%s", str(c, rd(c, p + 36, 32)));
    classes[class_count++].proc = rd(c, p + 4, 32);
    RET(class_count, 1);
  }
  case API_CreateWindowExA: {
    uint32_t a[12];
    for (int i = 0; i < 12; i++)
      a[i] = A(i);
    uint32_t proc = 0;
    const char *name = str(c, a[1]);
    for (unsigned i = 0; i < class_count; i++)
      if (!strcmp(name, classes[i].name))
        proc = classes[i].proc;
    if (!proc)
      RET(0, 12);
    Window *w = new_window(a[8], a[9], a[3]);
    if (!w)
      RET(0, 12);
    w->proc = proc;
    snprintf(w->title, sizeof(w->title), "%s", str(c, a[2]));
    fprintf(stderr, "WINDOW %s %ux%u proc=%08x\n", w->title, a[6], a[7], proc);
    uint32_t cs = alloc(c, 48),
             v[] = {a[11], a[10], a[9], a[8], a[7], a[6], a[5], a[4], a[3], a[2], a[1], a[0]};
    memcpy(c->mem + cs, v, 48);
    if (!callback(c, proc, w->handle, 0x81, 0, cs) || c->fault)
      RET(0, 12);
    if (callback(c, proc, w->handle, 1, 0, cs) == 0xffffffff || c->fault)
      RET(0, 12);
    active_window = w->handle;
    if (a[3] & 0x10000000)
      post(w->handle, 6, 1, 0);
    RET(w->handle, 12);
  }
  case API_NtdllDefWindowProc_A:
    RET(A(1) == 0x81 ? 1 : 0, 4);
  case API_AdjustWindowRectEx:
    OK(4);
  case API_ChangeDisplaySettingsA:
    RET(0, 2);
  case API_GetSystemMetrics:
    RET(A(0) == 0 ? 640 : A(0) == 1 ? 480 : 0, 1);
  case API_ShowWindow: {
    Window *w = window(A(0));
    if (w && w->proc) {
      post(w->handle, 6, 1, 0);
      post(w->handle, 0xf, 0, 0);
    }
    RET(w != NULL, 2);
  }
  case API_UpdateWindow: {
    Window *w = window(A(0));
    if (w && w->proc)
      callback(c, w->proc, w->handle, 0xf, 0, 0);
    RET(w != NULL, 1);
  }
  case API_SetForegroundWindow:
    OK(1);
  case API_SendMessageA: {
    Window *w = window(A(0));
    uint32_t r = w && w->proc ? callback(c, w->proc, A(0), A(1), A(2), A(3)) : 0;
    RET(r, 4);
  }
  case API_PostMessageA:
    post(A(0), A(1), A(2), A(3));
    OK(4);
  case API_PostQuitMessage:
    post(0, 0x12, A(0), 0);
    RET(0, 1);
  case API_DestroyWindow: {
    Window *w = window(A(0));
    if (w && w->proc)
      callback(c, w->proc, w->handle, 2, 0, 0);
    RET(w != NULL, 1);
  }
  case API_PeekMessageA: {
    if (frame_sink)
      c->steps = 0;
    pthread_mutex_lock(&message_lock);
    int available = message_head < message_tail;
    if (available) {
      uint32_t p = A(0);
      memset(c->mem + p, 0, 28);
      typeof(messages[0]) m = messages[message_head % 1024];
      if (!m.h && m.msg != 0x12)
        m.h = active_window;
      memcpy(c->mem + p, &m, 16);
      if (A(4) & 1)
        message_head++;
    }
    pthread_mutex_unlock(&message_lock);
    RET(available, 5);
  }
  case API_TranslateMessage:
    RET(0, 1);
  case API_DispatchMessageA: {
    uint32_t p = A(0), h = rd(c, p, 32);
    Window *w = window(h);
    uint32_t r = w && w->proc ? callback(c, w->proc, h, rd(c, p + 4, 32), rd(c, p + 8, 32),
                                         rd(c, p + 12, 32))
                              : 0;
    RET(r, 1);
  }
  case API_Sleep:
    sync_keyboard(c);
    game_sync(c);
#ifdef LEMON_WEB
    browser_yield = 1;
#else
    lemon_lifecycle_wait();
    usleep((uint64_t)A(0) * 1000);
#endif
    RET(0, 1);
  case API_DialogBoxParamA: {
    uint32_t lp = A(4);
    Window *w = dialog_create(c, A(1), A(2), A(3));
    if (!w)
      RET(-1, 5);
    callback(c, w->proc, w->handle, 0x110, 0, lp);
    if (c->fault)
      return 0;
    fprintf(stderr, "DIALOG %u: %s\n", w->id, w->title);
    for (unsigned i = 0; i < window_count; i++)
      if (windows[i].parent == w->handle)
        fprintf(stderr, " control %u enabled=%d title=%s\n", windows[i].id, windows[i].enabled,
                windows[i].title);
    /* Non-iOS reference hosts retain the original registration dialog. */
    Window *try_now = child(w->handle, 1005);
    if (dialog_sink) {
      while (!w->ended && !c->fault) {
        Window *body = child(w->handle, 1004);
        char name[1024] = {0}, code[1024] = {0};
        int selection =
            dialog_sink(w->title, body ? body->title : "", try_now && try_now->enabled, name, code);
        if (selection == 1003) {
          uint32_t ids[] = {1000, 1001};
          const char *values[] = {name, code};
          for (int i = 0; i < 2; i++) {
            Window *v = child(w->handle, ids[i]);
            if (v) {
              snprintf(v->title, sizeof(v->title), "%s", values[i]);
              callback(c, w->proc, w->handle, 0x111, ids[i] | 0x03000000, v->handle);
            }
          }
        }
        Window *v = child(w->handle, selection);
        if (selection == 2 || (v && v->enabled))
          callback(c, w->proc, w->handle, 0x111, selection, v ? v->handle : 0);
      }
    } else if (!w->ended && try_now && try_now->enabled) {
      fprintf(stderr, "Headless input: %s\n", try_now->title);
      callback(c, w->proc, w->handle, 0x111, try_now->id, try_now->handle);
    }
    if (!w->ended && !c->fault) {
      fprintf(stderr, "Dialog requires user input\n");
      fault(c, pc);
    }
    if (c->fault)
      return 0;
    RET(w->result, 5);
  }
  case API_GetDlgItem: {
    Window *w = child(A(0), A(1));
    RET(w ? w->handle : 0, 2);
  }
  case API_EnableWindow: {
    Window *w = window(A(0));
    int old = w ? !w->enabled : 0;
    if (w)
      w->enabled = !!A(1);
    RET(old, 2);
  }
  case API_IsWindowEnabled: {
    Window *w = window(A(0));
    RET(w && w->enabled, 1);
  }
  case API_EndDialog: {
    Window *w = window(A(0));
    if (w) {
      w->ended = 1;
      w->result = A(1);
    }
    RET(w != NULL, 2);
  }
  case API_SetDlgItemTextA: {
    Window *w = child(A(0), A(1));
    if (w)
      snprintf(w->title, sizeof(w->title), "%s", str(c, A(2)));
    RET(w != NULL, 3);
  }
  case API_SetWindowTextA: {
    Window *w = window(A(0));
    if (w)
      snprintf(w->title, sizeof(w->title), "%s", str(c, A(1)));
    RET(w != NULL, 2);
  }
  case API_GetWindowTextA:
  case API_GetDlgItemTextA: {
    int d = api == API_GetDlgItemTextA;
    Window *w = d ? child(A(0), A(1)) : window(A(0));
    uint32_t dst = A(1 + d), cap = A(2 + d);
    size_t n = w ? strlen(w->title) : 0;
    if (cap) {
      if (n >= cap)
        n = cap - 1;
      if (n)
        memcpy(c->mem + dst, w->title, n);
      wr(c, dst + n, 0, 8);
    } else
      n = 0;
    RET(n, 3 + d);
  }
  case API_GetWindowLongA: {
    Window *w = window(A(0));
    RET(w && A(1) == (uint32_t)-16 ? w->style : 0, 2);
  }
  case API_SystemParametersInfoA:
    if (A(0) == 0x30) {
      put(c, A(2), 0);
      put(c, A(2) + 4, 0);
      put(c, A(2) + 8, 640);
      put(c, A(2) + 12, 480);
      OK(4);
    }
    fprintf(stderr, "Unsupported system parameter %u\n", A(0));
    fault(c, pc);
    return 0;
  case API_GetWindowRect:
  case API_GetClientRect:
    put(c, A(1), 0);
    put(c, A(1) + 4, 0);
    put(c, A(1) + 8, 640);
    put(c, A(1) + 12, 480);
    OK(2);
  case API_SetWindowPos:
    OK(7);
  case API_GetVersion:
    RET(0x0a280105, 0);
  case API_GetVersionExA: {
    uint32_t p = A(0);
    put(c, p + 4, 5);
    put(c, p + 8, 1);
    put(c, p + 12, 2600);
    put(c, p + 16, 2);
    wr(c, p + 20, 0, 8);
    OK(1);
  }
  case API_GetCurrentProcess:
    RET(0xffffffff, 0);
  case API_GetCommandLineA:
    if (!command_line)
      command_line = text(c, "C:\\Lemonade\\Lemonade.exe");
    RET(command_line, 0);
  case API_GetModuleHandleA:
    RET(0x400000, 1);
  case API_GetModuleFileNameA: {
    const char *s = "C:\\Lemonade\\Lemonade.exe";
    uint32_t count = A(2);
    size_t n = strlen(s);
    if (count <= n)
      n = count ? count - 1 : 0;
    if (count) {
      memcpy(c->mem + A(1), s, n);
      wr(c, A(1) + n, 0, 8);
    }
    RET(n, 3);
  }
  case API_GetStartupInfoA: {
    uint32_t p = A(0);
    memset(c->mem + p, 0, 68);
    put(c, p, 68);
    OK(1);
  }
  case API_HeapCreate:
    RET(1, 3);
  case API_HeapAlloc: {
    uint32_t p = alloc(c, A(2));
    RET(p, 3);
  }
  case API_HeapSize:
    RET(allocation_size(A(2)), 3);
  case API_HeapReAlloc: {
    uint32_t old = A(2), n = A(3), p = alloc(c, n), sz = allocation_size(old);
    if (p && old) {
      memcpy(c->mem + p, c->mem + old, sz < n ? sz : n);
      release(old);
    }
    RET(p, 4);
  }
  case API_HeapFree:
    RET(release(A(2)), 3);
  case API_HeapDestroy:
    OK(1);
  case API_VirtualAlloc: {
    uint32_t request = A(0), size = A(1);
    if (request) {
      if ((uint64_t)request + size > c->mem_size)
        RET(0, 4);
      RET(request, 4);
    }
    uint32_t p = alloc(c, size + 4096);
    RET((p + 4095) & ~4095u, 4);
  }
  case API_VirtualFree:
    OK(3);
  case API_GetStdHandle:
    RET(0x100 + (A(0) == (uint32_t)-10 ? 0 : A(0) == (uint32_t)-11 ? 1 : 2), 1);
  case API_SetStdHandle:
    OK(2);
  case API_GetFileType:
    RET(2, 1);
  case API_SetHandleCount:
    RET(A(0), 1);
  case API_GetACP:
  case API_GetOEMCP:
    RET(1252, 0);
  case API_GetCPInfo: {
    uint32_t p = A(1);
    memset(c->mem + p, 0, 20);
    put(c, p, 1);
    wr(c, p + 4, '?', 8);
    OK(2);
  }
  case API_GetEnvironmentStringsW:
    if (!environment_wide)
      environment_wide = alloc(c, 4);
    RET(environment_wide, 0);
  case API_GetEnvironmentStrings:
    if (!environment_ansi)
      environment_ansi = alloc(c, 2);
    RET(environment_ansi, 0);
  case API_FreeEnvironmentStringsW:
  case API_FreeEnvironmentStringsA:
    OK(1);
  case API_GetEnvironmentVariableA:
    RET(0, 3);
  case API_WideCharToMultiByte: {
    uint32_t src = A(2), dst = A(4), capacity = A(5);
    int n = (int)A(3);
    if (n == -1) {
      n = 0;
      do {
        n++;
      } while (rd(c, src + 2 * (n - 1), 16));
    }
    if (dst && capacity) {
      for (int i = 0; i < n && i < capacity; i++)
        wr(c, dst + i, rd(c, src + 2 * i, 16) & 255, 8);
    }
    RET(n, 8);
  }
  case API_MultiByteToWideChar: {
    uint32_t src = A(2), dst = A(4), capacity = A(5);
    int n = (int)A(3);
    if (n == -1)
      n = strlen(str(c, src)) + 1;
    if (dst && capacity) {
      for (int i = 0; i < n && i < capacity; i++)
        wr(c, dst + 2 * i, rd(c, src + i, 8), 16);
    }
    RET(n, 6);
  }
  case API_GetStringTypeW: {
    uint32_t src = A(1), dst = A(3);
    int n = (int)A(2);
    if (n == -1) {
      n = 0;
      do {
        n++;
      } while (rd(c, src + 2 * (n - 1), 16));
    }
    for (int i = 0; i < n; i++) {
      unsigned ch = rd(c, src + i * 2, 16), v = 0;
      if (ch < 32)
        v |= 0x20;
      if (ch == ' ' || ch == '\t')
        v |= 0x48;
      if (ch >= '0' && ch <= '9')
        v |= 0x84;
      if (ch >= 'A' && ch <= 'Z')
        v |= 0x101;
      if (ch >= 'a' && ch <= 'z')
        v |= 0x102;
      wr(c, dst + 2 * i, v, 16);
    }
    OK(4);
  }
  case API_LCMapStringW: {
    uint32_t src = A(2), dst = A(4);
    int n = (int)A(3);
    if (n == -1) {
      n = 0;
      do {
        n++;
      } while (rd(c, src + 2 * (n - 1), 16));
    }
    if (dst && A(5))
      for (int i = 0; i < n && i < A(5); i++) {
        unsigned v = rd(c, src + 2 * i, 16);
        if ((A(1) & 0x100) && v >= 'A' && v <= 'Z')
          v += 32;
        if ((A(1) & 0x200) && v >= 'a' && v <= 'z')
          v -= 32;
        wr(c, dst + 2 * i, v, 16);
      }
    RET(n, 6);
  }
  case API_GetLastError:
    RET(last_error, 0);
  case API_SetUnhandledExceptionFilter:
    RET(0, 1);
  case API_IsBadReadPtr:
  case API_IsBadWritePtr:
    RET((uint64_t)A(0) + A(1) > c->mem_size, 2);
  case API_IsBadCodePtr:
    RET(0, 1);
  case API_GetTickCount:
    RET(lemon_lifecycle_ticks(), 0);
  case API_GetSystemInfo: {
    uint32_t p = A(0);
    memset(c->mem + p, 0, 36);
    put(c, p + 4, 4096);
    put(c, p + 8, 0x10000);
    put(c, p + 12, c->mem_size - 1);
    put(c, p + 16, 1);
    put(c, p + 20, 1);
    put(c, p + 24, 586);
    put(c, p + 28, 65536);
    OK(1);
  }
  case API_LoadStringA: {
    uint32_t id = A(1), p = find_resource(c, 6, (id >> 4) + 1);
    if (!p)
      RET(0, 4);
    p = 0x400000 + rd(c, p, 32);
    for (unsigned i = 0; i < (id & 15); i++)
      p += 2 + 2 * rd(c, p, 16);
    uint32_t n = rd(c, p, 16), cap = A(3), dst = A(2);
    if (!cap)
      RET(0, 4);
    if (n >= cap)
      n = cap - 1;
    for (unsigned i = 0; i < n; i++)
      wr(c, dst + i, rd(c, p + 2 + 2 * i, 16) & 255, 8);
    wr(c, dst + n, 0, 8);
    RET(n, 4);
  }
  case API_FindResourceA:
    RET(find_resource(c, A(2), A(1)), 3);
  case API_LoadResource:
    RET(0x400000 + rd(c, A(1), 32), 2);
  case API_LockResource:
    RET(A(0), 1);
  case API_GetKeyboardType:
    RET(A(0) == 0 ? 4 : A(0) == 2 ? 12 : 0, 1);
  case API_GetSystemTime:
  case API_GetLocalTime: {
    time_t now = time(NULL);
    struct tm tm;
    if (api == API_GetSystemTime)
      gmtime_r(&now, &tm);
    else
      localtime_r(&now, &tm);
    uint32_t p = A(0);
    int v[] = {tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_wday, tm.tm_mday,
               tm.tm_hour,        tm.tm_min,     tm.tm_sec,  0};
    for (int i = 0; i < 8; i++)
      wr(c, p + 2 * i, v[i], 16);
    RET(0, 1);
  }
  case API_SystemTimeToFileTime: {
    uint32_t p = A(0);
    struct tm tm = {0};
    tm.tm_year = rd(c, p, 16) - 1900;
    tm.tm_mon = rd(c, p + 2, 16) - 1;
    tm.tm_mday = rd(c, p + 6, 16);
    tm.tm_hour = rd(c, p + 8, 16);
    tm.tm_min = rd(c, p + 10, 16);
    tm.tm_sec = rd(c, p + 12, 16);
    uint64_t t = ((uint64_t)timegm(&tm) + 11644473600ULL) * 10000000ULL;
    wr(c, A(1), t, 64);
    OK(2);
  }
  case API_RegOpenKeyExA:
  case API_RegCreateKeyA:
  case API_RegCreateKeyExA: {
    uint32_t handle = 0, disp = 0;
    int create = api != API_RegOpenKeyExA;
    uint32_t result = registry_open(A(0), str(c, A(1)), create, &handle, &disp);
    if (!result) {
      put(c, A(api == API_RegCreateKeyA ? 2 : api == API_RegCreateKeyExA ? 7 : 4), handle);
      if (api == API_RegCreateKeyExA && A(8))
        put(c, A(8), disp);
    }
    RET(result, api == API_RegCreateKeyA ? 3 : api == API_RegCreateKeyExA ? 9 : 5);
  }
  case API_RegQueryValueExA: {
    const char *key = registry_key(A(0));
    if (!key)
      RET(6, 6);
    RegValue *v = registry_value(key, str(c, A(1)));
    if (!v || v->type == 0xffffffff)
      RET(2, 6);
    if (A(3))
      put(c, A(3), v->type);
    uint32_t cap = A(5) ? rd(c, A(5), 32) : 0;
    if (A(5))
      put(c, A(5), v->size);
    if (A(4)) {
      if (cap < v->size)
        RET(234, 6);
      if ((uint64_t)A(4) + v->size > c->mem_size)
        RET(87, 6);
      memcpy(c->mem + A(4), v->data, v->size);
    }
    RET(0, 6);
  }
  case API_RegSetValueExA:
    if ((uint64_t)A(4) + A(5) > c->mem_size)
      RET(87, 6);
    RET(registry_set(registry_key(A(0)), str(c, A(1)), A(3), c->mem + A(4), A(5)), 6);
  case API_RegCloseKey: {
    uint32_t h = A(0);
    if (h >= 0x300 && h < 0x400)
      reg_handles[h - 0x300].used = 0;
    RET(0, 1);
  }
  case API_GetProfileIntA: {
    char key[512];
    snprintf(key, sizeof(key), "PROFILE\\%s", str(c, A(0)));
    RegValue *v = registry_value(key, str(c, A(1)));
    RET(v && v->size ? (uint32_t)strtoul((const char *)v->data, NULL, 10) : A(2), 3);
  }
  case API_WriteProfileStringA: {
    char key[512];
    snprintf(key, sizeof(key), "PROFILE\\%s", str(c, A(0)));
    const char *value = str(c, A(2));
    RET(registry_set(key, str(c, A(1)), 1, value, strlen(value) + 1) == 0, 3);
  }
  case API_GetUserDefaultLangID:
    RET(0x409, 0);
  case API_GlobalMemoryStatus: {
    uint32_t p = A(0);
    put(c, p, 32);
    put(c, p + 4, 50);
    for (int i = 8; i < 32; i += 4)
      put(c, p + i, 0x10000000);
    OK(1);
  }
  case API_CreateMutexA:
    last_error = 0;
    RET(0x200, 3);
  case API_ReleaseMutex:
    OK(1);
  case API_RegisterWindowMessageA:
    RET(0xc000, 1);
  case API_lstrcpyA: {
    uint32_t dst = A(0);
    const char *s = str(c, A(1));
    memmove(c->mem + dst, s, strlen(s) + 1);
    RET(dst, 2);
  }
  case API_lstrcatA: {
    uint32_t dst = A(0);
    const char *s = str(c, A(1));
    size_t n = strlen(str(c, dst));
    memmove(c->mem + dst + n, s, strlen(s) + 1);
    RET(dst, 2);
  }
  case API_lstrlenA:
    RET(strlen(str(c, A(0))), 1);
  case API_lstrcmpiA:
    RET(strcasecmp(str(c, A(0)), str(c, A(1))), 2);
  case API_LoadLibraryA:
    RET(0x600000, 1);
  case API_GetProcAddress: {
    const char *s = str(c, A(1));
    for (unsigned i = 0; i < API_COUNT; i++)
      if (!strcmp(s, api_names[i]))
        RET(0xf0000000u + i * 16, 2);
    fprintf(stderr, "Unavailable dynamic API %s\n", s);
    RET(0, 2);
  }
  case API_ExitProcess:
  case API_TerminateProcess:
    if (api == API_TerminateProcess && A(0) != 0xffffffff) {
      last_error = 6;
      RET(0, 2);
    }
    c->exit_code = A(api == API_TerminateProcess ? 1 : 0);
    c->halted = 1;
    fprintf(stderr, "Original program exited with code %u\n", c->exit_code);
    return 0;
  default:
    fprintf(stderr, "UNIMPLEMENTED %s (%08x)\n", api_names[api], pc);
    fault(c, pc);
    return 0;
  }
}
/* Called only between runs, after the previous engine worker has returned. */
/* Reset all guest-owned handles before a new game session; disk saves survive. */
static void reset_platform(void) {
  game_reset();
  for (unsigned i = 0; i < 256; i++)
    if (files[i]) {
      lemon_save_close(files[i], 0);
      files[i] = NULL;
    }
  heap_next = 0x1000000;
  allocation_count = 0;
  memset(allocations, 0, sizeof(allocations));
  last_error = 0;
  active_window = command_line = environment_wide = environment_ansi = 0;
  text_editor = 0;
  memset(keyboard_state, 0, sizeof(keyboard_state));
  memset(api_counts, 0, sizeof(api_counts));
  memset(gdi, 0, sizeof(gdi));
  frame_count = 0;
  memset(screen, 0, sizeof(screen));
  memset(windows, 0, sizeof(windows));
  window_count = 0;
  memset(classes, 0, sizeof(classes));
  class_count = 0;
  pthread_mutex_lock(&message_lock);
  message_head = message_tail = 0;
  pthread_mutex_unlock(&message_lock);
  reg_count = 0;
  memset(reg_values, 0, sizeof(reg_values));
  memset(reg_handles, 0, sizeof(reg_handles));
}
/* Load the cold image at its original base and replace imports with adapter thunks. */
static int prepare_run(CPU *cpu, const char *input) {
  reset_platform();
  mkdir(save_dir, 0700);
  registry_load();
  gdi[0].kind = 1;
  CPU c = {0};
  c.mem_size = 0x10000000;
  c.mem = calloc(1, c.mem_size);
  c.limit = 100000000;
  c.esp = 0xe00000;
  c.ebp = c.esp;
  c.fcw = 0x37f;
  c.fsbase = 0x200000;
  if (!c.mem)
    return 2;
  FILE *f = fopen(input, "rb");
  if (!f) {
    perror(input);
    free(c.mem);
    return 2;
  }
  if (fread(c.mem + 0x400000, 1, 0x1aa000, f) != 0x1aa000) {
    fprintf(stderr, "short image\n");
    fclose(f);
    free(c.mem);
    return 2;
  }
  fclose(f);
  patch_imports(&c);
  lemon_game_configure(&c);
  put(&c, c.fsbase, 0xffffffff);
  push(&c, 0xeeeeeeee);
  *cpu = c;
  lemon_save_running(1);
  return 0;
}
/* Close resources before discarding guest memory; this also supports Play again. */
static void finish_run(CPU *c) {
  game_reset();
  lemon_audio_close();
  for (unsigned i = 0; i < 256; i++)
    if (files[i]) {
      lemon_save_close(files[i], 0);
      files[i] = NULL;
    }
  if (keyboard_sink)
    keyboard_sink(0, 0, 0, 0, 0);
  free(c->mem);
  c->mem = NULL;
  lemon_save_running(0);
}
int lemon_run(const char *input) {
  CPU c = {0};
  if (prepare_run(&c, input))
    return 2;
  int result = game_run(&c, 0x44fb6b, 0xeeeeeeee);
  fprintf(stderr, "native stopped result=%d fault=%08x steps=%u eax=%08x esp=%08x heap=%08x\n",
          result, c.fault, c.steps, c.eax, c.esp, heap_next);
  finish_run(&c);
  return result ? 1 : c.halted && c.exit_code ? 1 : 0;
}
#if !defined(LEMON_IOS) && !defined(LEMON_WEB)
int main(int argc, char **argv) { return lemon_run(argc > 1 ? argv[1] : "assets/cold-memory.bin"); }
#endif
