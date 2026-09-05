#define LEMON_IOS
#include "../platform.c"
#include <assert.h>
int game_run(CPU *c, uint32_t pc, uint32_t stop) { abort(); }
static uint32_t invoke(CPU *c, API api, int n, const uint32_t *a) {
  c->esp = 0xe00000;
  put(c, c->esp, 0x12345678);
  for (int i = 0; i < n; i++)
    put(c, c->esp + 4 + i * 4, a[i]);
  uint32_t next = native_api(c, 0xf0000000 + api * 16);
  assert(next == 0x12345678);
  assert(c->esp == 0xe00004 + 4 * n);
  assert(!c->fault);
  return c->eax;
}
#define CALL(api, ...)                                                                             \
  invoke(&c, API_##api, sizeof((uint32_t[]){__VA_ARGS__}) / 4, (uint32_t[]){__VA_ARGS__})
int main(void) {
  char temp[] = "/tmp/lemon-platform-XXXXXX";
  save_dir = mkdtemp(temp);
  assert(save_dir);
  CPU c = {0};
  c.mem_size = 0x10000000;
  c.mem = calloc(1, c.mem_size);
  uint32_t key = text(&c, "Software\\LemonadeTest"), name = text(&c, "Counter"),
           value = alloc(&c, 4), handle_out = alloc(&c, 4), size = alloc(&c, 4),
           type = alloc(&c, 4), dest = alloc(&c, 8), disp = alloc(&c, 4);
  put(&c, value, 12345);
  assert(CALL(RegCreateKeyExA, 0x80000001, key, 0, 0, 0, 0, 0, handle_out, disp) == 0);
  uint32_t h = rd(&c, handle_out, 32);
  assert(rd(&c, disp, 32) == 1);
  assert(CALL(RegSetValueExA, h, name, 0, 4, value, 4) == 0);
  assert(CALL(RegCloseKey, h) == 0);
  reg_count = 0;
  memset(reg_values, 0, sizeof(reg_values));
  registry_load();
  assert(CALL(RegOpenKeyExA, 0x80000001, key, 0, 0, handle_out) == 0);
  h = rd(&c, handle_out, 32);
  put(&c, size, 2);
  put(&c, dest, 0xfeedbeef);
  assert(CALL(RegQueryValueExA, h, name, 0, type, dest, size) == 234);
  assert(rd(&c, dest, 32) == 0xfeedbeef);
  assert(rd(&c, size, 32) == 4);
  assert(CALL(RegQueryValueExA, h, name, 0, type, dest, size) == 0);
  assert(rd(&c, dest, 32) == 12345 && rd(&c, type, 32) == 4);
  uint32_t app = text(&c, "TrialTest"), strvalue = text(&c, "58");
  assert(CALL(GetProfileIntA, app, name, 59) == 59);
  assert(CALL(WriteProfileStringA, app, name, strvalue) == 1);
  reg_count = 0;
  registry_load();
  assert(CALL(GetProfileIntA, app, name, 59) == 58);
  uint32_t a = CALL(HeapAlloc, 1, 8, 128);
  memset(c.mem + a, 0x5a, 128);
  uint32_t b = CALL(HeapReAlloc, 1, 8, a, 256);
  for (int i = 0; i < 128; i++)
    assert(c.mem[b + i] == 0x5a);
  assert(CALL(HeapSize, 1, 0, b) == 256);
  assert(CALL(HeapFree, 1, 0, b) == 1);
  uint32_t before = heap_next;
  for (int i = 0; i < 10000; i++) {
    uint32_t p = CALL(HeapAlloc, 1, 8, 128);
    assert(p);
    assert(CALL(HeapFree, 1, 0, p) == 1);
  }
  assert(heap_next == before);
  /* A guest process exit must not return into the original CRT or become a fault. */
  c.esp = 0xe00000;
  put(&c, c.esp, 0x12345678);
  put(&c, c.esp + 4, 7);
  assert(native_api(&c, 0xf0000000 + API_ExitProcess * 16) == 0);
  assert(c.halted && c.exit_code == 7 && !c.fault && c.esp == 0xe00000);
  c.halted = c.exit_code = 0;
  assert(CALL(TerminateProcess, 0x1234, 9) == 0);
  assert(!c.halted && last_error == 6);
  c.esp = 0xe00000;
  put(&c, c.esp + 4, 0xffffffff);
  put(&c, c.esp + 8, 9);
  assert(native_api(&c, 0xf0000000 + API_TerminateProcess * 16) == 0);
  assert(c.halted && c.exit_code == 9 && !c.fault);
  /* A new engine run discards guest addresses/handles, then reloads disk state. */
  command_line = 123;
  environment_wide = 456;
  environment_ansi = 789;
  new_window(0, 0, 0);
  post(0, 1, 0, 0);
  reset_platform();
  assert(!command_line && !environment_wide && !environment_ansi);
  assert(!allocation_count && heap_next == 0x1000000 && !window_count && !message_tail);
  assert(!reg_count);
  registry_load();
  assert(reg_count);
  printf("PASS: persistence, buffer sizes, realloc, 10000 allocation/free cycles, guest exit, "
         "restart reset (%s)\n",
         temp);
  free(c.mem);
  return 0;
}
