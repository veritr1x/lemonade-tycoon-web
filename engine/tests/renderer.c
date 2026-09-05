#include "../renderer.h"
#include <assert.h>

static void declined(CPU c) {
  CPU before = c;
  uint8_t memory[4096];
  memcpy(memory, c.mem, sizeof(memory));
  assert(!lemon_copy_span(&c));
  assert(!memcmp(&c, &before, sizeof(c)));
  assert(!memcmp(c.mem, memory, sizeof(memory)));
}
static void declined_palette(CPU c) {
  CPU before = c;
  uint8_t *memory = malloc(1 << 18);
  memcpy(memory, c.mem, 1 << 18);
  assert(!lemon_palette_span(&c));
  assert(!memcmp(&c, &before, sizeof(c)));
  assert(!memcmp(c.mem, memory, 1 << 18));
  free(memory);
}
int main(void) {
  uint8_t memory[4096];
  for (unsigned i = 0; i < sizeof(memory); i++)
    memory[i] = (uint8_t)i;
  CPU c = {.mem = memory,
           .mem_size = sizeof(memory),
           .eax = 2,
           .edi = 1,
           .ebx = 101,
           .edx = 1001,
           .ebp = 32,
           .limit = 221};
  CPU base = c;
  assert(lemon_copy_span(&c));
  assert(c.steps == 221 && c.ebx == 163 && c.edx == 1065 && c.ebp == 0);
  assert(!memcmp(memory + 101, memory + 1003, 62));
  assert(memory[1002] == (uint8_t)1002 && memory[1065] == (uint8_t)1065);

  c = base;
  c.limit--;
  declined(c); // Preserve the exact instruction-limit trap.
  c = base;
  c.steps = UINT32_MAX - 100;
  c.limit = UINT32_MAX;
  declined(c);
  c = base;
  c.ebp = 0;
  declined(c);
  c = base;
  c.ebp = UINT32_MAX;
  declined(c);
  c = base;
  c.eax = 4;
  declined(c); // Non-contiguous source/destination.
  c = base;
  c.edi = 2;
  declined(c);
  c = base;
  c.edx = 101;
  declined(c); // Forward-overlap must retain scalar ordering.
  c = base;
  c.edx = 95;
  declined(c);
  c = base;
  c.ebx = 4090;
  declined(c);
  c = base;
  c.edx = 4090;
  declined(c);
  c = base;
  c.edx = UINT32_MAX;
  declined(c);
  c = base;
  c.fault = 1;
  declined(c);
  c = base;
  c.halted = 1;
  declined(c);
  c = base;
  c.edx = c.ebx - 2;
  assert(lemon_copy_span(&c)); // Identical spans.
  c = base;
  c.ebp = 1;
  c.limit = 4;
  assert(lemon_copy_span(&c));
  assert(c.steps == 4 && c.ebx == base.ebx && c.edx == base.edx + 2);
  uint8_t *pixels = calloc(1, 1 << 18);
  CPU keyed = {.mem = pixels,
               .mem_size = 1 << 18,
               .eax = 32,
               .ecx = 2,
               .ebx = 256,
               .edi = 8192,
               .esp = 128,
               .limit = 416};
  wr(&keyed, keyed.esp + 0x10, 0xffff, 16);
  wr(&keyed, keyed.esp + 0x14, 32768, 32);
  wr(&keyed, keyed.esp + 0x20, 1, 32);
  for (unsigned i = 0; i < 65536; i++)
    wr(&keyed, 32768 + 2 * i, i ^ 0xaaaa, 16);
  for (unsigned i = 0; i < 32; i++)
    wr(&keyed, 256 + 2 * i, i % 2 ? i : 0xffff, 16);
  c = keyed;
  assert(lemon_palette_span(&c));
  assert(c.steps == 352 && c.ebp == 32768 && c.eax == 0 && c.edx == 2);
  for (unsigned i = 0; i < 32; i++)
    assert(rd(&c, 8192 + i * 2, 16) == (i % 2 ? i ^ 0xaaaa : 0));
  c = keyed;
  c.limit--;
  declined_palette(c);
  c = keyed;
  c.eax = 0;
  declined_palette(c);
  c = keyed;
  c.eax = UINT32_MAX;
  declined_palette(c);
  c = keyed;
  c.ecx = 4;
  declined_palette(c);
  c = keyed;
  c.edi = 258;
  declined_palette(c);
  c = keyed;
  c.edi = 32768;
  declined_palette(c);
  c = keyed;
  c.edi = c.esp + 0x10;
  declined_palette(c);
  c = keyed;
  c.esp = UINT32_MAX - 2;
  declined_palette(c);
  c = keyed;
  c.ebx = (1 << 18) - 1;
  declined_palette(c);
  c = keyed;
  c.edi = (1 << 18) - 1;
  declined_palette(c);
  c = keyed;
  wr(&c, c.esp + 0x20, 2, 32);
  declined_palette(c);
  wr(&c, c.esp + 0x20, 1, 32);
  wr(&c, c.esp + 0x14, UINT32_MAX, 32);
  declined_palette(c);
  free(pixels);
  puts("PASS: renderer span bounds, overlap ordering, instruction budgets and fallback state");
}
