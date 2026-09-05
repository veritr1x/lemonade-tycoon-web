#define LEMON_IOS
#include "../game_config.h"
#include <assert.h>

static uint32_t call(CPU *cpu, uint32_t address) {
  cpu->esp = 0xe00000;
  cpu->fault = cpu->steps = 0;
  cpu->limit = 100000;
  push(cpu, 0xeeeeeeee);
  assert(game_run(cpu, address, 0xeeeeeeee) == 0);
  assert(cpu->esp == 0xe00000);
  return cpu->eax;
}
int main(void) {
  CPU cpu = {0};
  cpu.mem_size = 0x1000000;
  cpu.mem = calloc(1, cpu.mem_size);
  FILE *image = fopen("assets/cold-memory.bin", "rb");
  assert(image);
  assert(fread(cpu.mem + 0x400000, 1, 0x1aa000, image) == 0x1aa000);
  fclose(image);
  /* Start from expired trial data. Execute the actual compiled original
     initialization, HUD query, expiry check and eight hours of minute ticks. */
  wr(&cpu, 0x57f99c, 1, 32);
  wr(&cpu, 0x474628, 0, 32);
  lemon_game_configure(&cpu);
  call(&cpu, 0x426296);
  assert(call(&cpu, 0x4264bc) == 0);
  assert(call(&cpu, 0x4263dd) == 0);
  for (int minute = 0; minute < 480; minute++)
    assert((call(&cpu, 0x4261cd) & 255) == 0);
  assert(rd(&cpu, 0x474628, 32) == 0);
  assert(rd(&cpu, 0x57f99c, 32) == 0);
  puts("PASS: native full-game startup, no trial HUD, expired data accepted, 480 original minute "
       "checks without expiry");
  free(cpu.mem);
}
