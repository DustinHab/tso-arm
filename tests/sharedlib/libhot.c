// A shared library whose functions the CI translates ahead of time (tests/ci.sh): a hot loop over a buffer that
// calls another function of the library, and one that calls back into the program through a pointer.
#include <stddef.h>
#include <stdint.h>

__attribute__((noinline)) static uint64_t mix(uint64_t h, uint8_t b)
{
    h ^= b;
    h *= 0x100000001b3ULL;
    return h ^ (h >> 29);
}

uint64_t hot_sum(const uint8_t *p, size_t n, uint64_t seed)
{
    uint64_t h = seed ^ 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i)
        h = mix(h, p[i]);
    return h;
}

uint64_t hot_apply(uint64_t (*f)(uint64_t), uint64_t x, int times)
{
    for (int i = 0; i < times; ++i)
        x = f(x) + (uint64_t)i;
    return x;
}
