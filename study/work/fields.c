// Loop over structs: several [base + displacement] accesses through one base per iteration.
// Used to look at the IR and code FEX produces for view addressing.
#include <stdio.h>
#include <stdlib.h>

struct item {
    long a, b, c, d;
};

__attribute__((noinline)) long walk(struct item *s, long n) {
    long sum = 0;
    for (long i = 0; i < n; i++) {
        s[i].a += s[i].b * 3;
        s[i].c = s[i].a ^ s[i].d;
        sum += s[i].c;
    }
    return sum;
}

int main(int argc, char **argv) {
    long n = argc > 1 ? atol(argv[1]) : 1000;
    struct item *s = calloc(n, sizeof *s);
    for (long i = 0; i < n; i++) s[i].b = i, s[i].d = i * 7;
    long t = 0;
    for (int r = 0; r < 10; r++) t += walk(s, n);
    printf("%ld\n", t);
    return 0;
}
