// Message passing and two classic shapes under x86-TSO, x86-64 only.
//
// Thread A writes data, then a flag; thread B waits for the flag, then reads the data. TSO forbids B seeing the
// new flag with old data. Before waiting, B reads the data once, so the old line sits in its cache: a load that is
// satisfied early then returns the old value. The variants differ in the instruction A uses for the data or the
// flag, or B uses to wait:
//
//   mp         data mov, flag mov, wait mov
//   vec        data movdqu                       (FEX default leaves vector accesses unordered)
//   rep        data rep stosq                    (FEX default leaves rep movs/stos unordered)
//   stack      data mov through rsp, in A's stack  (FEX never orders rsp-based accesses)
//   stackflag  flag mov through rsp, in A's stack
//   vecflag    flag movq from an xmm register
//   repflag    flag rep stosq (one qword)
//   vecwait    B waits with movq into an xmm register
//   lb         load buffering   A: r1 = x; y = 1   B: r2 = y; x = 1   (r1 = r2 = 1 forbidden)
//   sb         store buffering  A: x = 1; r1 = y   B: y = 1; r2 = x   (r1 = r2 = 0 allowed: sanity check)
//
// Usage: mp VARIANT [iterations]   prints the count of forbidden outcomes; exit status 1 if there were any.

#define _GNU_SOURCE
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SLOTS 64  // data slots in flight, one cache line each
#define WINDOW 32 // how far A may run ahead of B
#define LINE 64

static long iterations = 2000000;
enum { V_MP, V_VEC, V_REP, V_STACK, V_STACKFLAG, V_VECFLAG, V_REPFLAG, V_VECWAIT, V_LB, V_SB, NV };
static const char *const names[NV] = {"mp", "vec", "rep", "stack", "stackflag", "vecflag", "repflag", "vecwait",
                                      "lb", "sb"};
static int variant;

static volatile uint64_t flag_word __attribute__((aligned(LINE)));
static volatile uint64_t ack __attribute__((aligned(LINE)));
static volatile uint64_t *volatile stack_area;  // A's stack area (stack and stackflag variants)
static uint8_t *heap;                             // SLOTS lines of data
static long violations;

static inline void cpu_relax(void) { __asm__ volatile("pause"); }

static inline volatile uint64_t *slot_ptr(long s) {
    if (variant == V_STACK) return stack_area + 8 * s;  // one line per slot inside A's stack area
    return (volatile uint64_t *)(heap + s * LINE);
}

static inline volatile uint64_t *flag_ptr(void) {
    if (variant == V_STACKFLAG) return stack_area;
    return &flag_word;
}

// ---- thread A in C (heap data, flag in a global)
static void *thread_a(void *arg) {
    (void)arg;
    for (uint64_t i = 1; i <= (uint64_t)iterations; i++) {
        while (i - ack > WINDOW) cpu_relax();
        uint64_t *line = (uint64_t *)(heap + (i % SLOTS) * LINE);
        if (variant == V_VEC) {
            __asm__ volatile("movq %0, %%xmm0\n\t punpcklqdq %%xmm0, %%xmm0\n\t movdqu %%xmm0, (%1)"
                             : : "r"(i), "r"(line) : "xmm0", "memory");
        } else if (variant == V_REP) {
            uint64_t cnt = 8, *dst = line;
            __asm__ volatile("rep stosq" : "+D"(dst), "+c"(cnt) : "a"(i) : "memory");
        } else {
            __asm__ volatile("movq %0, (%1)" : : "r"(i), "r"(line) : "memory");
        }
        if (variant == V_VECFLAG) {
            __asm__ volatile("movq %1, %%xmm1\n\t movq %%xmm1, %0" : "=m"(flag_word) : "r"(i) : "xmm1", "memory");
        } else if (variant == V_REPFLAG) {
            uint64_t cnt = 1;
            volatile uint64_t *dst = &flag_word;
            __asm__ volatile("rep stosq" : "+D"(dst), "+c"(cnt) : "a"(i) : "memory");
        } else {
            __asm__ volatile("movq %1, %0" : "=m"(flag_word) : "r"(i) : "memory");
        }
    }
    return NULL;
}

// ---- thread A in assembly, for the variants that address A's own stack through rsp. The stack area is 1024
// bytes below rsp: 16 lines; in 'stack' the data slots are lines 0..15 (slot & 15), in 'stackflag' the flag is
// line 0 and the data goes to the heap.
static void *thread_a_stack(void *arg) {
    (void)arg;
    long n = iterations;
    if (variant == V_STACK) {
        __asm__ volatile(
            "mov %%rsp, %%r8\n\t"
            "sub $1088, %%rsp\n\t and $-64, %%rsp\n\t"
            "mov %%rsp, %[pub]\n\t"
            "mov $1, %%rcx\n"
            "2:\n\t mov %[ack], %%rax\n\t mov %%rcx, %%rdx\n\t sub %%rax, %%rdx\n\t cmp $8, %%rdx\n\t"
            "jbe 3f\n\t pause\n\t jmp 2b\n"
            "3:\n\t mov %%rcx, %%rdx\n\t and $15, %%rdx\n\t shl $6, %%rdx\n\t"
            "mov %%rcx, (%%rsp,%%rdx)\n\t"  // data through rsp
            "mov %%rcx, %[flag]\n\t"        // flag
            "inc %%rcx\n\t cmp %[n], %%rcx\n\t jbe 2b\n\t"
            "4:\n\t mov %[ack], %%rax\n\t cmp %[n], %%rax\n\t jae 5f\n\t pause\n\t jmp 4b\n"
            "5:\n\t mov %%r8, %%rsp\n\t"
            : [pub] "=m"(stack_area), [flag] "=m"(flag_word)
            : [ack] "m"(ack), [n] "r"(n)
            : "rax", "rcx", "rdx", "r8", "memory", "cc");
    } else {
        uint8_t *h = heap;
        __asm__ volatile(
            "mov %%rsp, %%r8\n\t"
            "sub $1088, %%rsp\n\t and $-64, %%rsp\n\t"
            "movq $0, (%%rsp)\n\t"
            "mov %%rsp, %[pub]\n\t"
            "mov $1, %%rcx\n"
            "2:\n\t mov %[ack], %%rax\n\t mov %%rcx, %%rdx\n\t sub %%rax, %%rdx\n\t cmp $32, %%rdx\n\t"
            "jbe 3f\n\t pause\n\t jmp 2b\n"
            "3:\n\t mov %%rcx, %%rdx\n\t and $63, %%rdx\n\t shl $6, %%rdx\n\t"
            "mov %%rcx, (%[h],%%rdx)\n\t"   // data in the heap
            "mov %%rcx, (%%rsp)\n\t"        // flag through rsp
            "inc %%rcx\n\t cmp %[n], %%rcx\n\t jbe 2b\n\t"
            "4:\n\t mov %[ack], %%rax\n\t cmp %[n], %%rax\n\t jae 5f\n\t pause\n\t jmp 4b\n"
            "5:\n\t mov %%r8, %%rsp\n\t"
            : [pub] "=m"(stack_area)
            : [ack] "m"(ack), [n] "r"(n), [h] "r"(h)
            : "rax", "rcx", "rdx", "r8", "memory", "cc");
    }
    return NULL;
}

static void *thread_b(void *arg) {
    (void)arg;
    if (variant == V_STACK || variant == V_STACKFLAG)
        while (stack_area == NULL) cpu_relax();
    long mask = variant == V_STACK ? 15 : SLOTS - 1;
    for (uint64_t i = 1; i <= (uint64_t)iterations; i++) {
        volatile uint64_t *d = slot_ptr(i & mask);
        uint64_t v, f;
        __asm__ volatile("movq (%1), %0" : "=r"(v) : "r"(d) : "memory");  // pull the old line in
        volatile uint64_t *fp = flag_ptr();
        do {
            if (variant == V_VECWAIT)
                __asm__ volatile("movq (%1), %%xmm2\n\t movq %%xmm2, %0" : "=r"(f) : "r"(fp) : "xmm2", "memory");
            else
                __asm__ volatile("movq (%1), %0" : "=r"(f) : "r"(fp) : "memory");
        } while (f < i);
        if (variant == V_REP) {
            v = ~0ull;
            for (int k = 0; k < 8; k++) {
                uint64_t w;
                __asm__ volatile("movq (%1), %0" : "=r"(w) : "r"(d + k) : "memory");
                if (w < v) v = w;
            }
        } else {
            __asm__ volatile("movq (%1), %0" : "=r"(v) : "r"(d) : "memory");
        }
        if (v < i) violations++;
        __asm__ volatile("movq %1, %0" : "=m"(ack) : "r"(i) : "memory");
    }
    return NULL;
}

// ---- lb and sb: rounds of BATCH iterations over separate lines, with a spin barrier between rounds.
#define BATCH 256
struct cell {
    volatile uint64_t v;
    char pad[LINE - 8];
};
static struct cell *xs, *ys;
static uint64_t *r1, *r2;
static volatile uint64_t round_go[2] __attribute__((aligned(LINE)));

static void sync_round(int me, uint64_t round) {
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
            uint64_t t;
            volatile uint64_t *x = &xs[k].v, *y = &ys[k].v;
            if (variant == V_LB) {  // A: r1 = x; y = 1   B: r2 = y; x = 1
                volatile uint64_t *ld = me ? y : x, *st = me ? x : y;
                __asm__ volatile("movq (%1), %0\n\t movq $1, (%2)" : "=&r"(t) : "r"(ld), "r"(st) : "memory");
            } else {  // A: x = 1; r1 = y   B: y = 1; r2 = x
                volatile uint64_t *st = me ? y : x, *ld = me ? x : y;
                __asm__ volatile("movq $1, (%1)\n\t movq (%2), %0" : "=&r"(t) : "r"(st), "r"(ld) : "memory");
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
        fprintf(stderr, "usage: mp VARIANT [iterations]; variants:");
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
        r1 = calloc(iterations, 8);
        r2 = calloc(iterations, 8);
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
    int on_stack = variant == V_STACK || variant == V_STACKFLAG;
    pthread_create(&a, NULL, on_stack ? thread_a_stack : thread_a, NULL);
    pthread_create(&b, NULL, thread_b, NULL);
    pthread_join(a, NULL);
    pthread_join(b, NULL);
    printf("%-9s iterations %ld forbidden %ld\n", names[variant], iterations, violations);
    return violations > 0;
}
