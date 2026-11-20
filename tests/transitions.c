// What a call costs across the border of translated code: guest code calling a small function translated ahead of
// time (FEX -> bridge -> host code), and a translated function calling small guest code through a function pointer
// (host code -> FEX's callback -> guest code). tests/transitions.sh builds the library with just the function named.
//   transitions in N        guest loop calling into(i) N times
//   transitions out N       out_loop(N) calling the guest function back() N times through a pointer
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

__attribute__((noinline)) long into(long x) { return x * 3 + 1; }
__attribute__((noinline)) long back(long x) { return x ^ (x >> 3); }

long (*volatile fp)(long) = back;

__attribute__((noinline)) long out_loop(long n)
{
    long s = 0;
    for (long i = 0; i < n; i++)
        s += fp(i);
    return s;
}

int main(int argc, char **argv)
{
    if (argc < 3)
        return 2;
    long n = atol(argv[2]), s = 0;
    if (!strcmp(argv[1], "in")) {
        for (long i = 0; i < n; i++)
            s += into(i);
    } else {
        s = out_loop(n);
    }
    printf("%ld\n", s);
    return 0;
}
