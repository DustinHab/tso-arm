// Code that changes while the program runs, with a second thread running (the views awake): the main thread writes
// `mov $N, %eax; ret` over the same bytes again and again and calls them, and then a second thread writes the code
// that the main thread calls, handing it over through a flag. Every call must return the N just written: a stale
// translation of the bytes before returns an older N.
// Last line "smc: N rewrites, M handed over, all right"; exit status 1 at the first wrong value.
#define _GNU_SOURCE
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static unsigned char *code;
static atomic_int stop, turn;
static atomic_uint handed;

static void put(unsigned char *p, uint32_t n)
{
    p[0] = 0xb8; // mov $n, %eax
    memcpy(p + 1, &n, 4);
    p[5] = 0xc3; // ret
}

static void *spinner(void *arg)
{
    (void)arg;
    volatile uint64_t x = 0;
    while (!atomic_load(&stop))
        x++;
    return 0;
}

// the second part: this thread writes, the main thread runs what it wrote
static void *writer(void *arg)
{
    unsigned rounds = *(unsigned *)arg;
    for (unsigned i = 1; i <= rounds; i++) {
        while (atomic_load(&turn) != 1)
            ;
        put(code + 64, 1000000 + i);
        atomic_store(&handed, i);
        atomic_store(&turn, 0);
    }
    return 0;
}

int main(int argc, char **argv)
{
    unsigned n = argc > 1 ? (unsigned)atoi(argv[1]) : 2000;
    code = mmap(0, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (code == MAP_FAILED)
        return 1;
    pthread_t t;
    pthread_create(&t, 0, spinner, 0);
    for (unsigned i = 1; i <= n; i++) {
        put(code, i);
        uint32_t got = ((uint32_t(*)(void))code)();
        if (got != i) {
            printf("smc: rewrite %u returned %u\n", i, got);
            return 1;
        }
    }
    atomic_store(&stop, 1);
    pthread_join(t, 0);
    pthread_create(&t, 0, writer, &n);
    for (unsigned i = 1; i <= n; i++) {
        atomic_store(&turn, 1);
        while (atomic_load(&turn) != 0)
            ;
        uint32_t got = ((uint32_t(*)(void))(code + 64))();
        if (got != 1000000 + i) {
            printf("smc: handed over %u returned %u\n", i, got);
            return 1;
        }
    }
    pthread_join(t, 0);
    printf("smc: %u rewrites, %u handed over, all right\n", n, n);
    return 0;
}
