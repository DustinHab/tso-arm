// Message passing under x86-TSO, x86-64 only.
//
// Thread A writes data, then a flag; thread B waits for the flag, then reads the data. TSO forbids B seeing the
// new flag with old data. An Arm translator that leaves either A's two stores or B's two loads unordered lets it
// happen. The variants differ only in how A writes the data:
//
//   mp        mov to a heap buffer
//   vec       16-byte movdqu to a heap buffer
//   rep       rep stosb (64 bytes) to a heap buffer
//   stack     mov to A's own stack, addressed through rsp, read by B through a published pointer
//   lb        load buffering: A: r1 = x; y = 1   B: r2 = y; x = 1   (r1 = r2 = 1 forbidden)
//   sb        store buffering: A: x = 1; r1 = y  B: y = 1; r2 = x   (r1 = r2 = 0 allowed on x86: sanity check)
//
// Usage: mp VARIANT [iterations]      prints iterations, violations; exit status 1 if a forbidden outcome was seen.

#define _GNU_SOURCE
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SLOTS 64       // data slots in flight
#define WINDOW 32      // how far A may run ahead of B
#define LINE 64

static long iterations = 2000000;
static int variant;
enum { V_MP, V_VEC, V_REP, V_STACK, V_LB, V_SB };

static volatile uint64_t flag __attribute__((aligned(LINE)));
static volatile uint64_t ack __attribute__((aligned(LINE)));
static volatile uint64_t *volatile stack_slots;  // published by A in the stack variant
static uint8_t *heap;                              // SLOTS lines of data
static long violations;

static inline void pause(void) { __asm__ volatile("pause"); }

// A's data store for iteration i into slot s. Plain x86 stores, as the guest program would issue them.
static inline void store_data(uint64_t i, long s) {
    uint8_t *line = heap + s * LINE;
    switch (variant) {
    case V_MP:
        __asm__ volatile("movq %0, (%1)" : : "r"(i), "r"(line) : "memory");
        break;
    case V_VEC: {
        __asm__ volatile("movq %0, %%xmm0\n\t punpcklqdq %%xmm0, %%xmm0\n\t movdqu %%xmm0, (%1)"
                         : : "r"(i), "r"(line) : "xmm0", "memory");
        break;
    }
    case V_REP: {
        // 64 bytes of the low byte of i, then i itself in the first 8 bytes via a second rep stos
        uint64_t cnt = 8, *dst = (uint64_t *)line;
        __asm__ volatile("rep stosq" : "+D"(dst), "+c"(cnt) : "a"(i) : "memory");
        break;
    }
    }
}

static inline uint64_t load_data(long s) {
    uint8_t *line = heap + s * LINE;
    uint64_t v;
    if (variant == V_REP) {
        // all eight words must be at least as new as the flag; return the oldest
        uint64_t m = ~0ull;
        for (int k = 0; k < 8; k++) {
            __asm__ volatile("movq (%1), %0" : "=r"(v) : "r"(line + 8 * k) : "memory");
            if (v < m) m = v;
        }
        return m;
    }
    __asm__ volatile("movq (%1), %0" : "=r"(v) : "r"(line) : "memory");
    return v;
}

static void *thread_a(void *arg) {
    (void)arg;
    if (variant == V_STACK) {
        // Data lives in this thread's stack below rsp and is written through rsp; the whole loop is one asm block
        // so that the compiler cannot move rsp in between.
        long n = iterations;
        __asm__ volatile(
            "sub $1024, %%rsp\n\t"
            "mov %%rsp, %[pub]\n\t"
            "mov $1, %%rcx\n"                      // i
            "1:\n"
            "2:\n\t mov %[ack], %%rax\n\t mov %%rcx, %%rdx\n\t sub %%rax, %%rdx\n\t cmp $32, %%rdx\n\t"
            "jbe 3f\n\t pause\n\t jmp 2b\n"
            "3:\n\t"
            "mov %%rcx, %%rdx\n\t and $63, %%rdx\n\t"
            "mov %%rcx, (%%rsp,%%rdx,8)\n\t"       // data, rsp-based
            "mov %%rcx, %[flag]\n\t"               // flag
            "inc %%rcx\n\t cmp %[n], %%rcx\n\t jbe 1b\n\t"
            // wait for B before the stack area goes away
            "4:\n\t mov %[ack], %%rax\n\t cmp %[n], %%rax\n\t jae 5f\n\t pause\n\t jmp 4b\n"
            "5:\n\t add $1024, %%rsp\n\t"
            : [pub] "=m"(stack_slots), [flag] "=m"(flag)
            : [ack] "m"(ack), [n] "r"(n)
            : "rax", "rcx", "rdx", "memory", "cc");
        return NULL;
    }
    for (uint64_t i = 1; i <= (uint64_t)iterations; i++) {
        while (i - ack > WINDOW) pause();
        store_data(i, i % SLOTS);
        __asm__ volatile("movq %1, %0" : "=m"(flag) : "r"(i) : "memory");
    }
    return NULL;
}

static void *thread_b(void *arg) {
    (void)arg;
    if (variant == V_STACK)
        while (stack_slots == NULL) pause();
    for (uint64_t i = 1; i <= (uint64_t)iterations; i++) {
        uint64_t f;
        do {
            __asm__ volatile("movq %1, %0" : "=r"(f) : "m"(flag) : "memory");
        } while (f < i);
        uint64_t v;
        if (variant == V_STACK)
            __asm__ volatile("movq (%1), %0" : "=r"(v) : "r"(stack_slots + (i & 63)) : "memory");
        else
            v = load_data(i % SLOTS);
        if (v < i) violations++;
        __asm__ volatile("movq %1, %0" : "=m"(ack) : "r"(i) : "memory");
    }
    return NULL;
}

// ---- lb and sb: both threads run the same number of rounds over arrays of separate lines, synchronised by a
// sense-reversing spin barrier every round of BATCH iterations.

#define BATCH 256
struct cell { volatile uint64_t v; char pad[LINE - 8]; };
static struct cell *xs, *ys;
static uint64_t *r1, *r2;
static volatile uint64_t round_go[2] __attribute__((aligned(LINE)));

static void sync_round(int me, uint64_t round) {
    __atomic_store_n(&round_go[me], round, __ATOMIC_SEQ_CST);
    while (__atomic_load_n(&round_go[1 - me], __ATOMIC_SEQ_CST) < round) pause();
}

static void *thread_pair(void *arg) {
    int me = (int)(long)arg;
    long rounds = iterations / BATCH;
    for (long r = 0; r < rounds; r++) {
        if (me == 0) {
            for (int k = 0; k < BATCH; k++) xs[k].v = ys[k].v = 0;
        }
        sync_round(me, 2 * r + 1);
        for (int k = 0; k < BATCH; k++) {
            uint64_t t;
            volatile uint64_t *mine = me ? &ys[k].v : &xs[k].v, *other = me ? &xs[k].v : &ys[k].v;
            if (variant == V_LB) {
                // load other's location... LB: A: r1 = x; y = 1   B: r2 = y; x = 1
                volatile uint64_t *ld = me ? &ys[k].v : &xs[k].v, *st = me ? &xs[k].v : &ys[k].v;
                __asm__ volatile("movq (%1), %0\n\t movq $1, (%2)" : "=&r"(t) : "r"(ld), "r"(st) : "memory");
            } else {
                // SB: A: x = 1; r1 = y   B: y = 1; r2 = x
                __asm__ volatile("movq $1, (%1)\n\t movq (%2), %0" : "=&r"(t) : "r"(mine), "r"(other) : "memory");
            }
            (me ? r2 : r1)[r * BATCH + k] = t;
        }
        sync_round(me, 2 * r + 2);
    }
    return NULL;
}

int main(int argc, char **argv) {
    static const char *const names[] = {"mp", "vec", "rep", "stack", "lb", "sb"};
    if (argc < 2) {
        fprintf(stderr, "usage: mp mp|vec|rep|stack|lb|sb [iterations]\n");
        return 2;
    }
    variant = -1;
    for (int k = 0; k < 6; k++)
        if (strcmp(argv[1], names[k]) == 0) variant = k;
    if (variant < 0) return 2;
    if (argc > 2) iterations = atol(argv[2]);

    pthread_t a, b;
    if (variant == V_LB || variant == V_SB) {
        iterations = iterations / BATCH * BATCH;
        xs = aligned_alloc(LINE, BATCH * sizeof *xs);
        ys = aligned_alloc(LINE, BATCH * sizeof *ys);
        r1 = calloc(iterations, 8);
        r2 = calloc(iterations, 8);
        pthread_create(&a, NULL, thread_pair, (void *)0);
        pthread_create(&b, NULL, thread_pair, (void *)1);
        pthread_join(a, NULL);
        pthread_join(b, NULL);
        long both = 0;
        for (long k = 0; k < iterations; k++)
            if (variant == V_LB ? (r1[k] == 1 && r2[k] == 1) : (r1[k] == 0 && r2[k] == 0)) both++;
        printf("%s iterations %ld %s %ld\n", names[variant], iterations,
               variant == V_LB ? "forbidden(r1=r2=1)" : "allowed(r1=r2=0)", both);
        return variant == V_LB && both > 0;
    }
    heap = aligned_alloc(LINE, SLOTS * LINE);
    memset(heap, 0, SLOTS * LINE);
    pthread_create(&a, NULL, thread_a, NULL);
    pthread_create(&b, NULL, thread_b, NULL);
    pthread_join(a, NULL);
    pthread_join(b, NULL);
    printf("%s iterations %ld violations %ld\n", names[variant], iterations, violations);
    return violations > 0;
}
