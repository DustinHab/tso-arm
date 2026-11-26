// Mappings larger than the page protocol's guest window (16 GB), as Chromium's allocator makes at its start (32 GB
// reserved without access, PartitionAlloc's pools) and V8 and Oilpan after it: they have to work, with what a program
// does in them. Under the page protocol such a mapping starts the fallback to full ordering and is made outside the
// window (notes section 64).
//   bigmap [threads]   with "threads", four threads run before the mapping is made (the views awake) and count in it
// Prints one line per check; exit status 1 if one failed.
#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define GB (1ULL << 30)
#define MB (1ULL << 20)

static int bad;

static void check(int ok, const char* what) {
    printf("bigmap: %s: %s\n", what, ok ? "ok" : "WRONG");
    bad |= !ok;
}

// threads that count in a word of the big mapping, with atomics, and in one of their own with plain stores
static volatile uint64_t* shared_word;
static volatile int go, stop;
static uint64_t own[4][8];

static void* worker(void* arg) {
    uint64_t* mine = own[(intptr_t)arg];
    while (!go)
        __atomic_fetch_add(&mine[0], 1, __ATOMIC_RELAXED);
    for (int i = 0; i < 1000000; i++) {
        __atomic_fetch_add(shared_word, 1, __ATOMIC_SEQ_CST);
        mine[1]++;
    }
    while (!stop)
        ;
    return NULL;
}

int main(int argc, char** argv) {
    const int threads = argc > 1 && !strcmp(argv[1], "threads");
    pthread_t t[4];
    if (threads) {
        for (intptr_t i = 0; i < 4; i++)
            pthread_create(&t[i], NULL, worker, (void*)i);
        // until each has run for a while (its block translated through the views)
        for (int i = 0; i < 4; i++)
            while (__atomic_load_n(&own[i][0], __ATOMIC_RELAXED) < 100000)
                ;
    }

    // 32 GB reserved without access (PartitionAlloc's glued pools)
    const uint64_t size = 32 * GB;
    uint8_t* p = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    check(p != MAP_FAILED, "32 GB reserved");
    if (p == MAP_FAILED)
        return 1;

    // a part made writable far into it, written and read back
    uint8_t* q = p + 20 * GB;
    check(mprotect(q, 4 * MB, PROT_READ | PROT_WRITE) == 0, "4 MB of it made writable");
    for (uint64_t i = 0; i < 4 * MB; i += 4096)
        q[i] = (uint8_t)(i >> 12);
    int same = 1;
    for (uint64_t i = 0; i < 4 * MB; i += 4096)
        same &= q[i] == (uint8_t)(i >> 12);
    check(same, "written and read back");

    // discarded pages read as zero (PartitionAlloc's decommit)
    check(madvise(q, MB, MADV_DONTNEED) == 0 && q[0] == 0 && q[4096] == 0 && q[MB] == (uint8_t)(MB >> 12), "MADV_DONTNEED: zeros");

    // a fork: the child has a copy of its own
    q[2 * MB] = 7;
    pid_t c = fork();
    if (c == 0) {
        int ok = q[2 * MB] == 7;
        q[2 * MB] = 9;
        _exit(ok && q[2 * MB] == 9 ? 0 : 1);
    }
    int st = 0;
    waitpid(c, &st, 0);
    check(WIFEXITED(st) && WEXITSTATUS(st) == 0 && q[2 * MB] == 7, "fork: the child's copy, the parent's unchanged");

    // part of it unmapped and mapped again at the same place (an allocator trimming and reusing)
    check(munmap(p + 8 * GB, 4 * GB) == 0, "4 GB in its middle unmapped");
    uint8_t* r = mmap(p + 8 * GB, 2 * MB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    check(r == p + 8 * GB && (r[0] = 5, r[2 * MB - 1] = 6, r[0] == 5), "mapped there again, fixed");

    // grown with mremap
    uint8_t* g = mmap(NULL, 2 * MB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (g != MAP_FAILED) {
        g[0] = 3;
        uint8_t* h = mremap(g, 2 * MB, 64 * MB, MREMAP_MAYMOVE);
        check(h != MAP_FAILED && h[0] == 3 && (h[64 * MB - 1] = 4, h[64 * MB - 1] == 4), "mremap: grown to 64 MB");
    }

    // code in it (a JIT), rewritten: the new code runs (self-modifying code outside the window)
    uint8_t* code = p + 24 * GB;
    if (mprotect(code, 4096, PROT_READ | PROT_WRITE | PROT_EXEC) == 0) {
        static const uint8_t ret1[] = {0xb8, 1, 0, 0, 0, 0xc3}; // mov eax, 1; ret
        memcpy(code, ret1, sizeof ret1);
        int a = ((int (*)(void))code)();
        code[1] = 2; // mov eax, 2
        int b = ((int (*)(void))code)();
        check(a == 1 && b == 2, "code in it, rewritten, runs anew");
    } else {
        check(0, "code in it (mprotect)");
    }

    if (threads) {
        // the threads count in it: none of their increments lost
        shared_word = (volatile uint64_t*)(q + 3 * MB);
        *shared_word = 0;
        __atomic_store_n(&go, 1, __ATOMIC_SEQ_CST);
        for (int i = 0; i < 4; i++)
            while (__atomic_load_n(&own[i][1], __ATOMIC_RELAXED) < 1000000)
                ;
        check(__atomic_load_n(shared_word, __ATOMIC_SEQ_CST) == 4000000, "four threads counted in it, none lost");
        stop = 1;
        for (int i = 0; i < 4; i++)
            pthread_join(t[i], NULL);
    }
    printf("bigmap: %s\n", bad ? "FAILED" : "all ok");
    return bad;
}
