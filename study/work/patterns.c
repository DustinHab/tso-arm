// Small multithreaded x86-64 programs with known sharing, to check the page-state study.
//   patterns private   each thread fills and sums its own buffer
//   patterns table     threads read a table filled before they started, write their own results
//   patterns shared    threads increment counters in one shared array (racy, on purpose)
//   patterns queue     one producer, one consumer, ring buffer with C11 atomics
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define THREADS 4
#define ROUNDS 20

static uint64_t *table;
static uint64_t *shared_counters;
static uint64_t results[THREADS * 8];

static void *w_private(void *arg) {
    long id = (long)arg;
    size_t n = 1 << 18;
    uint64_t *buf = malloc(n * sizeof *buf), s = 0;
    for (int r = 0; r < ROUNDS; r++) {
        for (size_t i = 0; i < n; i++) buf[i] = i * r + id;
        for (size_t i = 0; i < n; i++) s += buf[i];
    }
    results[id * 8] = s;
    free(buf);
    return NULL;
}

static void *w_table(void *arg) {
    long id = (long)arg;
    size_t n = 1 << 16;
    uint64_t *out = malloc(n * sizeof *out), s = 0;
    for (int r = 0; r < ROUNDS; r++)
        for (size_t i = 0; i < n; i++) out[i] = table[(i * 7 + id + r) & (n - 1)] * 3;
    for (size_t i = 0; i < n; i++) s += out[i];
    results[id * 8] = s;
    free(out);
    return NULL;
}

static void *w_shared(void *arg) {
    long id = (long)arg;
    uint64_t x = id + 1;
    for (int i = 0; i < ROUNDS * (1 << 16); i++) {
        x ^= x << 13, x ^= x >> 7, x ^= x << 17;
        shared_counters[x & ((1 << 16) - 1)]++;
    }
    return NULL;
}

#define QN 1024
static _Atomic uint64_t q_head, q_tail;
static uint64_t q_items[QN];

static void *w_producer(void *arg) {
    (void)arg;
    for (uint64_t i = 0; i < ROUNDS * (1 << 16); i++) {
        uint64_t h = atomic_load_explicit(&q_head, memory_order_relaxed);
        while (h - atomic_load_explicit(&q_tail, memory_order_acquire) == QN) {
        }
        q_items[h % QN] = i;
        atomic_store_explicit(&q_head, h + 1, memory_order_release);
    }
    return NULL;
}

static void *w_consumer(void *arg) {
    (void)arg;
    uint64_t s = 0;
    for (uint64_t i = 0; i < ROUNDS * (1 << 16); i++) {
        uint64_t t = atomic_load_explicit(&q_tail, memory_order_relaxed);
        while (atomic_load_explicit(&q_head, memory_order_acquire) == t) {
        }
        s += q_items[t % QN];
        atomic_store_explicit(&q_tail, t + 1, memory_order_release);
    }
    results[0] = s;
    return NULL;
}

int main(int argc, char **argv) {
    const char *what = argc > 1 ? argv[1] : "private";
    pthread_t t[THREADS];
    if (strcmp(what, "queue") == 0) {
        pthread_create(&t[0], NULL, w_producer, NULL);
        pthread_create(&t[1], NULL, w_consumer, NULL);
        pthread_join(t[0], NULL);
        pthread_join(t[1], NULL);
    } else {
        void *(*fn)(void *) = w_private;
        if (strcmp(what, "table") == 0) {
            table = malloc((1 << 16) * sizeof *table);
            for (int i = 0; i < 1 << 16; i++) table[i] = i * 2654435761u;
            fn = w_table;
        } else if (strcmp(what, "shared") == 0) {
            shared_counters = calloc(1 << 16, sizeof *shared_counters);
            fn = w_shared;
        }
        for (long i = 0; i < THREADS; i++) pthread_create(&t[i], NULL, fn, (void *)i);
        for (long i = 0; i < THREADS; i++) pthread_join(t[i], NULL);
    }
    uint64_t s = 0;
    for (int i = 0; i < THREADS; i++) s += results[i * 8];
    printf("%s %llu\n", what, (unsigned long long)s);
    return 0;
}
