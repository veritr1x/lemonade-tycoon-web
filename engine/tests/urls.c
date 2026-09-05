/* Execute the original browser helper with a recording native URL sink.
   This does not launch a browser or send a network request. */
#define LEMON_IOS
#include "../platform.c"
#include <assert.h>
static unsigned opened;
static int accept;
static char captured[256];
static int record_url(const char *url) {
  opened++;
  snprintf(captured, sizeof(captured), "%s", url);
  return accept;
}
static void original_browser(CPU *c, uint32_t url) {
  c->esp = 0xe00000;
  c->fault = c->steps = 0;
  c->limit = 100000;
  push(c, 0);
  push(c, url);
  push(c, 0xeeeeeeee);
  assert(game_run(c, 0x412d91, 0xeeeeeeee) == 0);
  assert(!c->fault && c->esp == 0xdffff8);
}
int main(void) {
  CPU c = {0};
  c.mem_size = 0x10000000;
  c.mem = calloc(1, c.mem_size);
  assert(c.mem);
  FILE *f = fopen("assets/cold-memory.bin", "rb");
  assert(f);
  assert(fread(c.mem + 0x400000, 1, 0x1aa000, f) == 0x1aa000);
  fclose(f);
  patch_imports(&c);
  lemon_url_configure(record_url);
  accept = 1;
  uint32_t url = text(&c, "https://example.invalid/lemonade?score=42");
  original_browser(&c, url);
  assert(opened == 1 && c.eax > 32);
  assert(!strcmp(captured, "https://example.invalid/lemonade?score=42"));
  accept = 0;
  original_browser(&c, url);
  assert(opened == 2 && c.eax <= 32 && !c.fault);
  original_browser(&c, text(&c, "C:\\Windows\\unavailable.exe"));
  assert(opened == 2 && c.eax <= 32);
  original_browser(&c, text(&c, "file:///private/example"));
  assert(opened == 2 && c.eax <= 32);
  lemon_url_configure(NULL);
  original_browser(&c, url);
  assert(opened == 2 && c.eax <= 32);
  free(c.mem);
  puts("PASS: original Windows-browser fallback reaches URL sink once; URL preserved; refusal, "
       "unsupported target and missing handler return failure without fault");
}
