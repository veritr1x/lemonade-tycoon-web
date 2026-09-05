#include "runtime.h"
int game_run(CPU *c, uint32_t pc, uint32_t stop) {
  uint32_t trace[32][5] = {{0}}, index = 0;
  while (pc != stop && !c->fault && !c->halted) {
    if (c->limit && c->steps >= c->limit) {
      fault(c, pc);
      break;
    }
    uint32_t *n = trace[index++ % 32];
    n[0] = pc;
    n[1] = c->eax;
    n[2] = c->ecx;
    n[3] = c->esp;
    n[4] = c->esi;
    pc = game_dispatch(c, pc);
  }
  if (c->fault) {
    fprintf(stderr, "Native trace before fault %08x:\n", c->fault);
    for (unsigned i = index > 32 ? index - 32 : 0; i < index; i++) {
      uint32_t *n = trace[i % 32];
      fprintf(stderr, " pc=%08x eax=%08x ecx=%08x esp=%08x esi=%08x\n", n[0], n[1], n[2], n[3],
              n[4]);
    }
  }
  return c->fault ? -1 : 0;
}

__attribute__((weak)) uint32_t native_api(CPU *c, uint32_t pc) {
  fault(c, pc);
  return 0;
}
__attribute__((weak)) void native_text_focus(CPU *c, uint32_t editor, int active) {}
