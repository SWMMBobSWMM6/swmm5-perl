/* mkexact.c - test vectors, computed by C on this machine, for what the Perl port does with doubles outside the
   transcendental functions: the math.h functions EPA calls that are exact in every library (sqrt, floor, ceil,
   fabs), the C operations the runtime and the generated code reproduce by hand (negation, the (float) cast, the
   (int) and (long) casts), the three operations Perl may carry out on integers when both operands are integral
   (a*b, a+b, a-b: the sign of a zero result), pow with two integral arguments (Perl's own integer power), and a/b
   with zero divisors among them (Perl's / dies on one; the runtime's rt_fdiv0 answers for C), in the
   record format of tools/libm/test/mkvectors.c (name\0, n:u32, then n x (args..., result) as raw doubles; for d2i
   and d2l the result slot holds the integer's 64 bits).
   gcc -O2 -fno-builtin -o mkexact mkexact.c -lm && ./mkexact N out.bin
   (Adapted from php/test/mkexact.c.) Written by Claude (Anthropic) for Robert Dickinson; see ../README.md. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
static uint64_t s = 0x2545F4914F6CDD1Dull;
static uint64_t xr(void){ s ^= s<<13; s ^= s>>7; s ^= s<<17; return s; }
static double asd(uint64_t u){ double d; memcpy(&d,&u,8); return d; }
static double uni(double a, double b){ return a + (b-a) * ((double)(xr()>>11) / 9007199254740992.0); }
static double lgu(int e0, int e1){ uint64_t r = xr(); return asd((r & 0x800fffffffffffffull) | ((uint64_t)(1023 + e0 + (int)((r>>52) % (uint64_t)(e1-e0))) << 52)); }
static double anyd(void){ return asd(xr()); }
/* volatile keeps gcc from folding or reordering the operations under test */
static double neg(double x) { volatile double v = x; return -v; }
static double f32(double x) { volatile double v = x; volatile float f = (float)v; return (double)f; }
static double d2i(double x) { volatile double v = x; int64_t r = (int)v; double d; memcpy(&d, &r, 8); return d; }
static double d2l(double x) { volatile double v = x; int64_t r = (long)v; double d; memcpy(&d, &r, 8); return d; }
static double (*fn[8])(double) = {sqrt, floor, ceil, fabs, neg, f32, d2i, d2l};
static const char *names[8] = {"sqrt", "floor", "ceil", "fabs", "neg", "f32", "d2i", "d2l"};
static double mul(double a, double b) { volatile double x = a, y = b; return x * y; }
static double add(double a, double b) { volatile double x = a, y = b; return x + y; }
static double sub(double a, double b) { volatile double x = a, y = b; return x - y; }
static double dvd(double a, double b) { volatile double x = a, y = b; return x / y; }
static double (*fn2[5])(double, double) = {mul, add, sub, pow, dvd};
static const char *names2[5] = {"mul", "add", "sub", "powi", "div"};
/* an integral double, often zero (of either sign), small, or beyond 2**53 */
static double intd(void) {
  uint64_t r = xr();
  switch (r % 8) {
  case 0: return 0.0;
  case 1: return -0.0;
  case 2: return (double)(int64_t)(r >> 40) - 8388608.0;
  case 3: return (double)((int64_t)(r >> 3) % 2000001 - 1000000);
  case 4: return ldexp((double)(int)(r >> 54) - 512.0, (int)((r >> 20) % 70));    /* up to about 2**79 */
  case 5: return (double)((int64_t)(r >> 10) % 41 - 20);
  case 6: return uni(-2, 2);                                                       /* not integral */
  default: return lgu(-20, 70);
  }
}
int main(int argc, char **argv) {
  long n = atol(argv[1]);
  double sp[] = {0.0, -0.0, 1.0, -1.0, INFINITY, -INFINITY, NAN, -NAN, 0.5, -0.5, 0.49999999999999994, -0.49999999999999994,
    1e-310, -1e-310, 4503599627370495.5, -4503599627370495.5, 4503599627370496.0, 9007199254740993.0, 1e300, -1e300,
    asd(0x7ff0000000000123ull), asd(0xfff8000000000456ull), 2.5, -2.5, 1.5, -1.5, 0.9999999999999999, -0.9999999999999999,
    2147483647.0, 2147483647.9, 2147483648.0, -2147483648.0, -2147483648.9, -2147483649.0, 9.2233720368547758e18,
    -9.2233720368547758e18, 3.4028234663852886e38, 3.4028235677973366e38, 3.4028235677973362e38, 1.401298464324817e-45,
    7.006492321624085e-46, 7.006492321624087e-46, 1.1754942106924411e-38, 4.9e-324, 8.64e9};
  int nsp = sizeof sp / sizeof *sp;
  FILE *o = fopen(argv[2], "wb");
  for (int f = 0; f < 8; f++) {
    uint32_t m = (uint32_t)(n + nsp);
    fwrite(names[f], 1, strlen(names[f]) + 1, o); fwrite(&m, 4, 1, o);
    for (int i = 0; i < nsp; i++) { double r[2] = {sp[i], fn[f](sp[i])}; fwrite(r, 8, 2, o); }
    for (long i = 0; i < n; i++) {
      double x;
      switch (i % 6) {
      case 0: x = anyd(); break;                         /* any bit pattern: NaN payloads, subnormals, huge */
      case 1: x = uni(-1000, 1000); break;
      case 2: x = lgu(-60, 60); break;                  /* signed, wide range */
      case 3: x = (double)(int64_t)uni(-1e6, 1e6) + ((xr() & 1) ? 0.0 : 0.5); break;   /* integers and halves */
      case 4: x = lgu(-160, 140); break;                /* around the float range and its edges */
      default: x = uni(-2, 2) * ldexp(1.0, (int)(xr() % 70)); break;
      }
      if (f == 3 || f == 4) { if (i % 7 == 0) x = 0.0; if (i % 7 == 1) x = -0.0; }
      double r[2] = {x, fn[f](x)};
      fwrite(r, 8, 2, o);
    }
  }
  for (int f = 0; f < 5; f++) {
    uint32_t m = (uint32_t)n;
    fwrite(names2[f], 1, strlen(names2[f]) + 1, o); fwrite(&m, 4, 1, o);
    for (long i = 0; i < n; i++) {
      double a = intd(), b = intd();
      if (f == 3) { b = (double)(int)(xr() % 64); if (i % 5 == 0) a = (double)(int64_t)(xr() % 41) - 20.0; }   /* integral powers */
      if (f == 4 && i % 9 == 0) a = sp[4 + (i / 9) % 4];                             /* inf, -inf, NaN, -NaN */
      double r[3] = {a, b, fn2[f](a, b)};
      fwrite(r, 8, 3, o);
    }
  }
  fclose(o);
  return 0;
}
