// getenv NAME: prints the value of the environment variable NAME as the program sees it ("(unset)" without one), to
// check what tso-arm sets for a program (FEX_MAXINST for Chromium's family)
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    const char *v = getenv(argv[1]);
    printf("%s\n", v ? v : "(unset)");
    return 0;
}
