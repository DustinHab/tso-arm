// x87 arithmetic (long double) and its conversions in the C library. FEX keeps the x87 register stack in the
// thread's context and addresses it there when the stack top is not known within a block; those accesses are not
// guest memory and must not go through the views. Prints the results: the same in every mode.
//   x87 [iterations, default 100000]
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    int n = argc > 1 ? atoi(argv[1]) : 100000;
    long double s = 0, p = 1;
    for (int i = 1; i <= n; i++) {
        s += 1.0L / i;
        p *= 1.0L + 1.0L / ((long double)i * i);
    }
    long double pi = strtold("3.14159265358979323846264338327950288", NULL);
    char text[128];
    snprintf(text, sizeof text, "%.18Lg %.18Lg %.18Lg", s, p, pi * 2);
    printf("x87: %s\n", text);
    return 0;
}
