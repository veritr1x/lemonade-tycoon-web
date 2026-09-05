#ifndef LEMON_RENDERER_H
#define LEMON_RENDERER_H
#include "runtime.h"

/* Finish the original 16-bit row-copy loop at 0x434001, after its first
 * pixel has been written. The common case copies consecutive, non-overlapping
 * pixels. A bulk copy avoids translating seven instructions for every pixel.
 * Strided/overlapping copies, invalid memory, and short instruction budgets
 * fall back to the unchanged original instructions without modifying state.
 * tools/lift_game.py verifies the original loop's bytes before adding the hook. */
static inline int lemon_copy_span(CPU *c) {
  uint64_t count = c->ebp, source = c->ebx, destination = (uint64_t)c->edx + 2;
  if (c->fault || c->halted || !count || c->eax != 2 || c->edi != 1)
    return 0;
  uint64_t bytes = 2 * (count - 1), steps = 7 * count - 3;
  if ((uint64_t)c->steps + steps > c->limit || (uint64_t)c->steps + steps > UINT32_MAX ||
      source + bytes > c->mem_size || destination + bytes > c->mem_size ||
      source + bytes > UINT32_MAX || destination + bytes > UINT32_MAX)
    return 0;
  if (source != destination && source < destination + bytes && destination < source + bytes)
    return 0;
  if (bytes && source != destination)
    memcpy(c->mem + destination, c->mem + source, bytes);

  // Match the loop's registers, flags, and instruction count at 0x434009.
  // The last ADD cannot carry after the bounds checks; DEC 1 yields zero.
  c->ebx = source + bytes;
  c->edx = destination + bytes;
  c->ecx = 2;
  c->ebp = 0;
  c->cf = c->af = c->sf = c->of = 0;
  c->zf = c->pf = 1;
  c->steps += steps;
  return 1;
}

/* Color-keyed sprite row at 0x4346b5. A palette maps each visible 16-bit pixel;
 * transparent pixels leave the destination unchanged. Cache only descriptors
 * that cannot be changed by this row's writes. Aliased or strided input falls
 * back to the original loop. The conservative budget permits every pixel to
 * be visible; the recorded step count still matches the actual branch path. */
static inline int lemon_palette_span(CPU *c) {
  uint64_t count = c->eax, source = c->ebx, destination = c->edi, stack = c->esp;
  uint64_t bytes = count * 2, maximum_steps = count * 13;
  if (c->fault || c->halted || !count || c->ecx != 2 ||
      (uint64_t)c->steps + maximum_steps > c->limit ||
      (uint64_t)c->steps + maximum_steps > UINT32_MAX || stack + 0x24 > c->mem_size ||
      stack + 0x24 > UINT32_MAX || source + bytes > c->mem_size ||
      destination + bytes > c->mem_size || source + bytes > UINT32_MAX ||
      destination + bytes > UINT32_MAX)
    return 0;
  uint32_t palette = rd(c, stack + 0x14, 32);
  if (rd(c, stack + 0x20, 32) != 1 || (uint64_t)palette + 131072 > c->mem_size ||
      (uint64_t)palette + 131072 > UINT32_MAX ||
      (source < destination + bytes && destination < source + bytes) ||
      (stack + 0x10 < destination + bytes && destination < stack + 0x24) ||
      ((uint64_t)palette < destination + bytes && destination < (uint64_t)palette + 131072))
    return 0;
  uint16_t transparent = rd(c, stack + 0x10, 16);
  unsigned visible = 0;
  for (uint64_t i = 0; i < count; i++) {
    uint16_t value;
    memcpy(&value, c->mem + source + i * 2, sizeof(value));
    if (value != transparent) {
      memcpy(c->mem + destination + i * 2, c->mem + palette + value * 2, sizeof(value));
      visible++;
    }
  }
  c->ebx = source + bytes;
  c->edi = destination + bytes;
  c->eax = 0;
  c->edx = 2;
  if (visible)
    c->ebp = palette;
  c->cf = c->af = c->sf = c->of = 0;
  c->zf = c->pf = 1;
  c->steps += count * 9 + visible * 4;
  return 1;
}
#endif
