// Makes the main thread's stack shared (another thread writes a variable on it), then runs ordinary library code
// on that stack and prints a checksum. Under the page protocol every stack access is then an escalated (ordered)
// instruction; the checksum must match the native run.
//   sharedstack [rounds]
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *poke(void *p) {
    *(volatile long *)p += 1;
    return NULL;
}

static int cmp(const void *a, const void *b) {
    long x = *(const long *)a, y = *(const long *)b;
    return (x > y) - (x < y);
}

static uint64_t mix(uint64_t h, uint64_t v) {
    h ^= v;
    h *= 0x100000001b3ULL;
    return h;
}

__attribute__((noinline)) static uint64_t deep(int n, uint64_t h) {
    volatile char pad[40];
    for (int i = 0; i < 40; i++)
        pad[i] = (char)(n + i);
    if (n == 0)
        return h;
    return deep(n - 1, mix(h, pad[n % 40]));
}

static uint64_t work(int rounds) {
    uint64_t h = 1469598103934665603ULL;
    for (int r = 0; r < rounds; r++) {
        char text[512];
        long arr[64];
        struct { char name[128]; double d; long l[6]; } a, b;
        memset(text, 0, sizeof text);
        int n = snprintf(text, sizeof text, "round %d %5.3f %s %lx", r, r * 1.25, "abcdefghijklmnopqrstuvwxyz", (long)r * 77777);
        for (int i = 0; i < n; i++)
            h = mix(h, (unsigned char)text[i]);
        for (int i = 0; i < 64; i++)
            arr[i] = (long)((i * 7919 + r * 104729) % 1000) - 500;
        qsort(arr, 64, sizeof arr[0], cmp);
        for (int i = 0; i < 64; i++)
            h = mix(h, (uint64_t)arr[i]);
        memset(&a, r & 0xff, sizeof a);
        strcpy(a.name, text + (r % 20));
        a.d = r / 3.0;
        b = a;
        h = mix(h, (uint64_t)strlen(b.name));
        h = mix(h, (uint64_t)(b.d * 1000));
        memmove(text + 3, text, 200);
        for (int i = 0; i < 210; i++)
            h = mix(h, (unsigned char)text[i]);
        h = deep(30 + r % 17, h);
    }
    return h;
}

static long dummy;

// pthread_create at many stack depths, so that its frame meets the shared page at every offset
__attribute__((noinline)) static int create_at(int depth) {
    volatile char pad[64];
    pad[0] = (char)depth;
    if (depth > 0)
        return create_at(depth - 1) + pad[0] * 0;
    pthread_t t;
    int rc = pthread_create(&t, NULL, poke, (void *)&dummy);
    if (rc == 0)
        pthread_join(t, NULL);
    return rc;
}

int main(int argc, char **argv) {
    int rounds = argc > 1 ? atoi(argv[1]) : 2000;
    volatile long shared = 0;
    pthread_t t;
    pthread_create(&t, NULL, poke, (void *)&shared);
    pthread_join(t, NULL);
    int failed = 0;
    for (int d = 0; d < 80; d++) {
        int rc = create_at(d);
        if (rc) {
            printf("create at depth %d: %s\n", d, strerror(rc));
            failed++;
        }
    }
    uint64_t h = work(rounds);
    printf("shared %ld checksum %016llx, failed creates %d\n", shared, (unsigned long long)h, failed);
    return failed != 0;
}
