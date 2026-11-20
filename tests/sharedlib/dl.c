// Loads libhot.so with dlopen, runs its functions, unloads it with dlclose and loads it again: FEX takes the
// library's translated functions when the guest maps it and gives them up when the guest unmaps it (tests/ci.sh).
// Prints the results, which are the same with and without the translations.
//   dl [rounds, default 3]
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t step(uint64_t x)
{
    return x * 6364136223846793005ULL + 1442695040888963407ULL;
}

int main(int argc, char **argv)
{
    int rounds = argc > 1 ? atoi(argv[1]) : 3;
    size_t n = 1 << 22;
    uint8_t *buf = malloc(n);
    for (size_t i = 0; i < n; ++i)
        buf[i] = (uint8_t)(i * 131 + (i >> 9));
    uint64_t total = 0;
    for (int r = 0; r < rounds; ++r) {
        void *lib = dlopen("libhot.so", RTLD_NOW);
        if (!lib) {
            printf("dlopen: %s\n", dlerror());
            return 1;
        }
        uint64_t (*sum)(const uint8_t *, size_t, uint64_t) = (uint64_t(*)(const uint8_t *, size_t, uint64_t))dlsym(lib, "hot_sum");
        uint64_t (*apply)(uint64_t (*)(uint64_t), uint64_t, int) = (uint64_t(*)(uint64_t (*)(uint64_t), uint64_t, int))dlsym(lib, "hot_apply");
        if (!sum || !apply)
            return 1;
        for (int k = 0; k < 4; ++k)
            total += sum(buf, n, (uint64_t)(r * 4 + k));
        total += apply(step, total, 1000);
        dlclose(lib);
    }
    printf("dl: %d rounds of dlopen, calls, dlclose: %016llx\n", rounds, (unsigned long long)total);
    return 0;
}
