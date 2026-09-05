#include "../runtime.h"
#include <assert.h>
static unsigned calls;
uint32_t game_dispatch(CPU *c, uint32_t pc) {
  calls++;
  if (pc == 1) {
    assert(game_run(c, 2, 99) == 0);
    return 3;
  }
  if (pc == 2) {
    c->halted = 1;
    c->exit_code = 0;
    return 0;
  }
  if (pc == 4) {
    fault(c, 4);
    return 0;
  }
  assert(!"Execution continued after process exit");
  return 0;
}
int main(void) {
  CPU c = {0};
  assert(game_run(&c, 1, 99) == 0);
  assert(c.halted && !c.fault && calls == 2);
  c = (CPU){0};
  assert(game_run(&c, 4, 99) == -1);
  assert(c.fault == 4 && !c.halted);
  puts("PASS: process exit unwinds nested runtime calls without dispatching more instructions; "
       "faults remain failures");
}
