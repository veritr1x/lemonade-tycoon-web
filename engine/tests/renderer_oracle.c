/* Expose a block boundary only in the development-time oracle library. */
#include "../renderer.h"
int lemon_test_palette_span(CPU *c) { return lemon_palette_span(c); }
