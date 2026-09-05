#ifndef LEMONADE_NATIVE_RUNTIME_H
#define LEMONADE_NATIVE_RUNTIME_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
/* Original addresses are data offsets only. Code is ahead-of-time compiled C;
   there is no instruction decoder or executable x86 memory at runtime. */
typedef struct {
  uint32_t eax, ecx, edx, ebx, esp, ebp, esi, edi;
  uint32_t cf, pf, af, zf, sf, of, df;
  uint32_t fsbase, fault, steps, limit;
  double fp[8];
  int top;
  uint16_t fcw, fsw;
  uint8_t *mem;
  size_t mem_size;
  uint32_t halted, exit_code;
} CPU;
static inline void fault(CPU *c, uint32_t pc) { c->fault = pc; }
static inline uint64_t rd(CPU *c, uint32_t a, int bits) {
  uint64_t v = 0;
  size_t n = bits / 8;
  if ((uint64_t)a + n > c->mem_size) {
    fault(c, a);
    return 0;
  }
  memcpy(&v, c->mem + a, n);
  return v;
}
static inline void wr(CPU *c, uint32_t a, uint64_t v, int bits) {
  size_t n = bits / 8;
  if ((uint64_t)a + n > c->mem_size) {
    fault(c, a);
    return;
  }
  memcpy(c->mem + a, &v, n);
}
static inline uint32_t mask(int n) { return n == 32 ? UINT32_MAX : ((1u << n) - 1); }
static inline int32_t sx(uint32_t x, int n) {
  return n == 32 ? (int32_t)x : ((int32_t)(x << (32 - n))) >> (32 - n);
}
static inline void zsp(CPU *c, uint32_t x, int n) {
  x &= mask(n);
  c->zf = x == 0;
  c->sf = (x >> (n - 1)) & 1;
  c->pf = !__builtin_parity(x & 255);
}
static inline uint32_t alu(CPU *c, uint32_t a, uint32_t b, int n, int op) {
  uint32_t m = mask(n), r;
  uint64_t wide;
  uint32_t carry = c->cf;
  a &= m;
  b &= m;
  switch (op) {
  case 0:
  case 2:
    wide = (uint64_t)a + b + (op == 2 ? carry : 0);
    r = wide & m;
    c->cf = (wide >> n) & 1;
    c->of = ((~(a ^ b) & (a ^ r)) >> (n - 1)) & 1;
    c->af = ((a ^ b ^ r) >> 4) & 1;
    break;
  case 1:
  case 3:
    wide = (uint64_t)b + (op == 3 ? carry : 0);
    r = (a - wide) & m;
    c->cf = (uint64_t)a < wide;
    c->of = (((a ^ b) & (a ^ r)) >> (n - 1)) & 1;
    c->af = ((a ^ b ^ r) >> 4) & 1;
    break;
  case 4:
    r = a & b;
    c->cf = c->of = 0;
    break;
  case 5:
    r = a | b;
    c->cf = c->of = 0;
    break;
  default:
    r = a ^ b;
    c->cf = c->of = 0;
    break;
  }
  zsp(c, r, n);
  return r;
}
static inline uint32_t shift(CPU *c, uint32_t a, uint32_t b, int n, int op) {
  uint32_t r = a & mask(n);
  b &= 31;
  if (!b)
    return r;
  if (op == 3 || op == 4) {
    b %= n;
    if (!b)
      return r;
    uint64_t v = r;
    if (op == 3) {
      r = ((v << b) | (v >> (n - b))) & mask(n);
      c->cf = r & 1;
      c->of = ((r >> (n - 1)) ^ c->cf) & 1;
    } else {
      r = ((v >> b) | (v << (n - b))) & mask(n);
      c->cf = (r >> (n - 1)) & 1;
      c->of = ((r >> (n - 1)) ^ (r >> (n - 2))) & 1;
    }
    return r;
  }
  for (uint32_t k = 0; k < b; k++) {
    if (op == 0) {
      c->cf = (r >> (n - 1)) & 1;
      r = (r << 1) & mask(n);
    } else {
      c->cf = r & 1;
      r = op == 2 ? ((uint32_t)(sx(r, n) >> 1) & mask(n)) : r >> 1;
    }
  }
  c->of = op == 0 ? (((r >> (n - 1)) ^ c->cf) & 1) : op == 1 ? ((a >> (n - 1)) & 1) : 0;
  zsp(c, r, n);
  return r;
}
static inline void push(CPU *c, uint32_t v) {
  c->esp -= 4;
  wr(c, c->esp, v, 32);
}
static inline uint32_t pop(CPU *c) {
  uint32_t v = rd(c, c->esp, 32);
  c->esp += 4;
  return v;
}
static inline double fr(CPU *c, int i) { return c->fp[(c->top + i) & 7]; }
static inline void fw(CPU *c, int i, double v) { c->fp[(c->top + i) & 7] = v; }
static inline void fpush(CPU *c, double v) {
  c->top = (c->top + 7) & 7;
  fw(c, 0, v);
}
static inline void fpop(CPU *c) { c->top = (c->top + 1) & 7; }
static inline double rdf(CPU *c, uint32_t a, int bits) {
  uint64_t v = rd(c, a, bits);
  if (bits == 32) {
    uint32_t u = v;
    float f;
    memcpy(&f, &u, 4);
    return f;
  }
  double d;
  memcpy(&d, &v, 8);
  return d;
}
static inline void wrf(CPU *c, uint32_t a, double v, int bits) {
  if (bits == 32) {
    float f = v;
    uint32_t u;
    memcpy(&u, &f, 4);
    wr(c, a, u, 32);
  } else {
    uint64_t u;
    memcpy(&u, &v, 8);
    wr(c, a, u, 64);
  }
}
uint32_t native_api(CPU *c, uint32_t pc);
uint32_t game_dispatch(CPU *c, uint32_t pc);
int game_run(CPU *c, uint32_t pc, uint32_t stop);
void native_text_focus(CPU *c, uint32_t editor, int active);
#endif
