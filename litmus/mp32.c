// Message passing and two classic shapes under x86-TSO, for 32-bit x86 programs (gcc -m32).
//
// The same tests as mp.c with 32-bit accesses: thread A writes data, then a flag; thread B waits for the flag, then
// reads the data, which TSO forbids it to see old once the flag is new. Before waiting, B reads the data once, so the
// old line sits in its cache.
//
//   mp    data movl, flag movl, wait movl
//   vec   data movdqu
//   rep   data rep stosl
//   lb    load buffering   A: r1 = x; y = 1   B: r2 = y; x = 1   (r1 = r2 = 1 forbidden)
//   sb    store buffering  A: x = 1; r1 = y   B: y = 1; r2 = x   (r1 = r2 = 0 allowed: sanity check)
//
// Usage: mp32 VARIANT [iterations]   prints the count of forbidden outcomes; exit status 1 if there were any.

#define _GNU_SOURCE
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SLOTS 64
#define WINDOW 32
#define LINE 64

static long iterations = 2000000;
enum { V_MP, V_VEC, V_REP, V_LB, V_SB, NV };
static const char *const names[NV] = {"mp", "vec", "rep", "lb", "sb"};
static int variant;

static volatile uint32_t flag_word __attribute__((aligned(LINE)));
static volatile uint32_t ack __attribute__((aligned(LINE)));
static uint8_t *heap;
static long violations;

static inline void cpu_relax(void) { __asm__ volatile("pause"); }

static void *thread_a(void *arg) {
    (void)arg;
    for (uint32_t i = 1; i <= (uint32_t)iterations; i++) {
        while (i - ack > WINDOW) cpu_relax();
        uint32_t *line = (uint32_t *)(heap + (i % SLOTS) * LINE);
        if (variant == V_VEC) {
            __asm__ volatile("movd %0, %%xmm0\n\t pshufd $0, %%xmm0, %%xmm0\n\t movdqu %%xmm0, (%1)"
                             : : "r"(i), "r"(line) : "xmm0", "memory");
        } else if (variant == V_REP) {
            uint32_t cnt = 16, *dst = line;
            __asm__ volatile("rep stosl" : "+D"(dst), "+c"(cnt) : "a"(i) : "memory");
        } else {
            __asm__ volatile("movl %0, (%1)" : : "r"(i), "r"(line) : "memory");
        }
        __asm__ volatile("movl %1, %0" : "=m"(flag_word) : "r"(i) : "memory");
    }
    return NULL;
}

static void *thread_b(void *arg) {
    (void)arg;
    for (uint32_t i = 1; i <= (uint32_t)iterations; i++) {
        volatile uint32_t *d = (volatile uint32_t *)(heap + (i % SLOTS) * LINE);
        uint32_t v, f;
        __asm__ volatile("movl (%1), %0" : "=r"(v) : "r"(d) : "memory");
        do {
            __asm__ volatile("movl (%1), %0" : "=r"(f) : "r"(&flag_word) : "memory");
        } while (f < i);
        if (variant == V_REP) {
            v = ~0u;
            for (int k = 0; k < 16; k++) {
                uint32_t w;
                __asm__ volatile("movl (%1), %0" : "=r"(w) : "r"(d + k) : "memory");
                if (w < v) v = w;
            }
        } else {
            __asm__ volatile("movl (%1), %0" : "=r"(v) : "r"(d) : "memory");
        }
        if (v < i) violations++;
        __asm__ volatile("movl %1, %0" : "=m"(ack) : "r"(i) : "memory");
    }
    return NULL;
}

#define BATCH 256
struct cell {
    volatile uint32_t v;
    char pad[LINE - 4];
};
static struct cell *xs, *ys;
static uint32_t *r1, *r2;
static volatile uint32_t round_go[2] __attribute__((aligned(LINE)));

static void sync_round(int me, uint32_t round) {
    __atomic_store_n(&round_go[me], round, __ATOMIC_SEQ_CST);
    while (__atomic_load_n(&round_go[1 - me], __ATOMIC_SEQ_CST) < round) cpu_relax();
}

static void *thread_pair(void *arg) {
    int me = (int)(long)arg;
    long rounds = iterations / BATCH;
    for (long r = 0; r < rounds; r++) {
        if (me == 0)
            for (int k = 0; k < BATCH; k++) xs[k].v = ys[k].v = 0;
        sync_round(me, 2 * r + 1);
        for (int k = 0; k < BATCH; k++) {
            uint32_t t;
            volatile uint32_t *x = &xs[k].v, *y = &ys[k].v;
            if (variant == V_LB) {
                volatile uint32_t *ld = me ? y : x, *st = me ? x : y;
                __asm__ volatile("movl (%1), %0\n\t movl $1, (%2)" : "=&r"(t) : "r"(ld), "r"(st) : "memory");
            } else {
                volatile uint32_t *st = me ? y : x, *ld = me ? x : y;
                __asm__ volatile("movl $1, (%1)\n\t movl (%2), %0" : "=&r"(t) : "r"(st), "r"(ld) : "memory");
            }
            (me ? r2 : r1)[r * BATCH + k] = t;
        }
        sync_round(me, 2 * r + 2);
    }
    return NULL;
}

int main(int argc, char **argv) {
    variant = -1;
    if (argc >= 2)
        for (int k = 0; k < NV; k++)
            if (strcmp(argv[1], names[k]) == 0) variant = k;
    if (variant < 0) {
        fprintf(stderr, "usage: mp32 VARIANT [iterations]; variants:");
        for (int k = 0; k < NV; k++) fprintf(stderr, " %s", names[k]);
        fprintf(stderr, "\n");
        return 2;
    }
    if (argc > 2) iterations = atol(argv[2]);

    pthread_t a, b;
    if (variant == V_LB || variant == V_SB) {
        iterations = iterations / BATCH * BATCH;
        xs = aligned_alloc(LINE, BATCH * sizeof *xs);
        ys = aligned_alloc(LINE, BATCH * sizeof *ys);
        r1 = calloc(iterations, 4);
        r2 = calloc(iterations, 4);
        pthread_create(&a, NULL, thread_pair, (void *)0);
        pthread_create(&b, NULL, thread_pair, (void *)1);
        pthread_join(a, NULL);
        pthread_join(b, NULL);
        long both = 0;
        for (long k = 0; k < iterations; k++)
            if (variant == V_LB ? (r1[k] == 1 && r2[k] == 1) : (r1[k] == 0 && r2[k] == 0)) both++;
        printf("%-9s iterations %ld %s %ld\n", names[variant], iterations,
               variant == V_LB ? "forbidden" : "allowed", both);
        return variant == V_LB && both > 0;
    }
    heap = aligned_alloc(LINE, SLOTS * LINE);
    memset(heap, 0, SLOTS * LINE);
    pthread_create(&a, NULL, thread_a, NULL);
    pthread_create(&b, NULL, thread_b, NULL);
    pthread_join(a, NULL);
    pthread_join(b, NULL);
    printf("%-9s iterations %ld forbidden %ld\n", names[variant], iterations, violations);
    return violations > 0;
}
