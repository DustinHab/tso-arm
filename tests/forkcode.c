// A forked child that runs code its parent never runs (64 functions of a few blocks each), for FEX's disk cache:
// a child writes what it translates as well, and a second run finds the child's code (Chromium's renderers and GPU
// process are forks of its zygote: notes section 72).
//   forkcode     prints "forkcode: the child's result N", exit status 1 if the child did not end with 0
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define F(n)                                                                                                           \
    __attribute__((noinline)) static unsigned long f##n(unsigned long x) {                                            \
        for (int i = 0; i < 3; i++) {                                                                                 \
            if (x & (1ul << (n % 13)))                                                                                \
                x = x * 3 + n;                                                                                        \
            else                                                                                                      \
                x ^= x >> (n % 7 + 1);                                                                                \
        }                                                                                                             \
        return x;                                                                                                     \
    }
#define F8(a) F(a##0) F(a##1) F(a##2) F(a##3) F(a##4) F(a##5) F(a##6) F(a##7)
F8(1) F8(2) F8(3) F8(4) F8(5) F8(6) F8(7) F8(8)
#define C(n) x = f##n(x);
#define C8(a) C(a##0) C(a##1) C(a##2) C(a##3) C(a##4) C(a##5) C(a##6) C(a##7)

int main(void) {
    pid_t p = fork();
    if (p == 0) {
        unsigned long x = 12345;
        C8(1) C8(2) C8(3) C8(4) C8(5) C8(6) C8(7) C8(8)
        char b[64];
        int n = snprintf(b, sizeof(b), "forkcode: the child's result %lu\n", x);
        if (n > 0) (void)!write(1, b, (size_t)n);
        _exit(0);
    }
    int st = 0;
    if (p < 0 || waitpid(p, &st, 0) != p) return 2;
    return WIFEXITED(st) && WEXITSTATUS(st) == 0 ? 0 : 1;
}
