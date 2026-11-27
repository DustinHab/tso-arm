// A program that maps a page of its own code once more below itself, at an address that changes from run to run,
// with mremap(MREMAP_DONTUNMAP) as V8 does with its builtins (Chrome, Node.js), then runs code of its own it has not
// run before (64 functions of a few blocks each). FEX reckoned every section of the program from its lowest mapping,
// which then was the copy: the disk cache's offsets of the program's code changed with the copy's address, and a
// second run found nothing (notes section 72).
//   remapcode     prints "remapcode: copy at ADDR, result N", exit status 2 if the copy could not be made
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#ifndef MREMAP_DONTUNMAP
#define MREMAP_DONTUNMAP 4
#endif

#define F(n)                                                                                                           \
    __attribute__((noinline)) static unsigned long f##n(unsigned long x) {                                            \
        for (int i = 0; i < 3; i++) {                                                                                 \
            if (x & (1ul << (n % 11)))                                                                                \
                x = x * 5 + n;                                                                                        \
            else                                                                                                      \
                x ^= x >> (n % 5 + 1);                                                                                \
        }                                                                                                             \
        return x;                                                                                                     \
    }
#define F8(a) F(a##0) F(a##1) F(a##2) F(a##3) F(a##4) F(a##5) F(a##6) F(a##7)
F8(1) F8(2) F8(3) F8(4) F8(5) F8(6) F8(7) F8(8)
#define C(n) x = f##n(x);
#define C8(a) C(a##0) C(a##1) C(a##2) C(a##3) C(a##4) C(a##5) C(a##6) C(a##7)

__attribute__((noinline)) static int copied(int v) { return v * 7 + 1; }

int main(void) {
    const uintptr_t page = (uintptr_t)&copied & ~(uintptr_t)4095;
    // below the program (linked at 0x400000), somewhere else in every run
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    uintptr_t at = 0x100000 + (uintptr_t)((ts.tv_nsec / 1000 + getpid()) % 32) * 0x10000;
    void *r = mmap((void *)at, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (r == MAP_FAILED) return 2;
    void *c = mremap((void *)page, 4096, 4096, MREMAP_MAYMOVE | MREMAP_FIXED | MREMAP_DONTUNMAP, r);
    if (c == MAP_FAILED || mprotect(c, 4096, PROT_READ | PROT_EXEC) != 0) return 2;
    unsigned long x = 54321 + (unsigned long)copied(3);
    C8(1) C8(2) C8(3) C8(4) C8(5) C8(6) C8(7) C8(8)
    printf("remapcode: copy at %p, result %lu\n", c, x);
    return 0;
}
