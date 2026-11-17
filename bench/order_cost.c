// Cost of ordered memory accesses on the host core, AArch64 only.
//
// Compares plain loads/stores with the two ways a translator can give them x86 (TSO) ordering:
//   rcpc  load -> ldapr, store -> stlr
//   dmb   load -> ldr; dmb ishld, store -> dmb ishst; str
// (and ldar, the sequentially consistent load, for comparison).
//
// Part 1 runs on 8 cache lines in L1 and reports processor cycles per access (PMU, user mode).
// Part 2 walks buffers of increasing size, sequentially and at random, and reports cycles per element.
//
// Build: gcc -O2 -mcpu=cortex-a76 -o order_cost order_cost.c      Run: ./order_cost [cpu]

#define _GNU_SOURCE
#include <linux/perf_event.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static int cycles_fd = -1;

static void cycles_open(void) {
    struct perf_event_attr a;
    memset(&a, 0, sizeof a);
    a.type = PERF_TYPE_HARDWARE;
    a.size = sizeof a;
    a.config = PERF_COUNT_HW_CPU_CYCLES;
    a.exclude_kernel = 1;
    a.exclude_hv = 1;
    cycles_fd = syscall(SYS_perf_event_open, &a, 0, -1, -1, 0);
    if (cycles_fd < 0) {
        perror("perf_event_open");
        exit(1);
    }
}

static uint64_t cycles(void) {
    uint64_t v;
    if (read(cycles_fd, &v, sizeof v) != sizeof v) exit(1);
    return v;
}

// ---------------------------------------------------------------------------------------------------------------
// Part 1: L1-resident kernels. Eight addresses on eight different cache lines in a0..a7.

#define ADDR8 [a0] "r"(p[0]), [a1] "r"(p[1]), [a2] "r"(p[2]), [a3] "r"(p[3]), \
              [a4] "r"(p[4]), [a5] "r"(p[5]), [a6] "r"(p[6]), [a7] "r"(p[7])
#define CLOBBERS "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", \
                 "v0", "v1", "v2", "v3", "memory", "cc"

#define KERNEL(name, body)                                                     \
    static void name(uint64_t *const *p, long n) {                             \
        __asm__ volatile("1:\n" body "subs %[n], %[n], #1\n b.ne 1b\n"         \
                         : [n] "+r"(n) : ADDR8 : CLOBBERS);                     \
    }

#define EACH8(op) \
    op(x9, a0) op(x10, a1) op(x11, a2) op(x12, a3) op(x13, a4) op(x14, a5) op(x15, a6) op(x16, a7)
#define EACH4(op) op(x9, a0, a4) op(x10, a1, a5) op(x11, a2, a6) op(x12, a3, a7)

#define LDR(r, a) "ldr " #r ", [%[" #a "]]\n"
#define LDAPR(r, a) "ldapr " #r ", [%[" #a "]]\n"
#define LDAR(r, a) "ldar " #r ", [%[" #a "]]\n"
#define LDR_DMB(r, a) "ldr " #r ", [%[" #a "]]\n dmb ishld\n"
#define STR(r, a) "str " #r ", [%[" #a "]]\n"
#define STLR(r, a) "stlr " #r ", [%[" #a "]]\n"
#define DMB_STR(r, a) "dmb ishst\n str " #r ", [%[" #a "]]\n"
#define LDRQ(r, a) "ldr q0, [%[" #a "]]\n"
#define LDRQ_DMB(r, a) "ldr q0, [%[" #a "]]\n dmb ishld\n"
#define STRQ(r, a) "str q0, [%[" #a "]]\n"
#define DMB_STRQ(r, a) "dmb ishst\n str q0, [%[" #a "]]\n"

// load, add, store to another line (typical translated read-modify-write of a value)
#define MIX_PLAIN(r, a, b) "ldr " #r ", [%[" #a "]]\n add " #r ", " #r ", #1\n str " #r ", [%[" #b "]]\n"
#define MIX_RCPC(r, a, b) "ldapr " #r ", [%[" #a "]]\n add " #r ", " #r ", #1\n stlr " #r ", [%[" #b "]]\n"
#define MIX_DMB(r, a, b) \
    "ldr " #r ", [%[" #a "]]\n dmb ishld\n add " #r ", " #r ", #1\n dmb ishst\n str " #r ", [%[" #b "]]\n"
// store followed by a load from another line (TSO allows this pair to be reordered)
#define SL_PLAIN(r, a, b) "str " #r ", [%[" #a "]]\n ldr x17, [%[" #b "]]\n"
#define SL_RCPC(r, a, b) "stlr " #r ", [%[" #a "]]\n ldapr x17, [%[" #b "]]\n"
#define SL_RCSC(r, a, b) "stlr " #r ", [%[" #a "]]\n ldar x17, [%[" #b "]]\n"
// 16-byte copy
#define CPYQ_PLAIN(r, a, b) "ldr q0, [%[" #a "]]\n str q0, [%[" #b "]]\n"
#define CPYQ_DMB(r, a, b) "ldr q0, [%[" #a "]]\n dmb ishld\n dmb ishst\n str q0, [%[" #b "]]\n"

KERNEL(k_ldr, EACH8(LDR))
KERNEL(k_ldapr, EACH8(LDAPR))
KERNEL(k_ldar, EACH8(LDAR))
KERNEL(k_ldr_dmb, EACH8(LDR_DMB))
KERNEL(k_str, EACH8(STR))
KERNEL(k_stlr, EACH8(STLR))
KERNEL(k_dmb_str, EACH8(DMB_STR))
KERNEL(k_mix_plain, EACH4(MIX_PLAIN))
KERNEL(k_mix_rcpc, EACH4(MIX_RCPC))
KERNEL(k_mix_dmb, EACH4(MIX_DMB))
KERNEL(k_ldrq, EACH8(LDRQ))
KERNEL(k_ldrq_dmb, EACH8(LDRQ_DMB))
KERNEL(k_strq, EACH8(STRQ))
KERNEL(k_dmb_strq, EACH8(DMB_STRQ))
KERNEL(k_cpyq_plain, EACH4(CPYQ_PLAIN))
KERNEL(k_cpyq_dmb, EACH4(CPYQ_DMB))

#undef CLOBBERS
#define CLOBBERS "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "memory", "cc"
KERNEL(k_sl_plain, EACH4(SL_PLAIN))
KERNEL(k_sl_rcpc, EACH4(SL_RCPC))
KERNEL(k_sl_rcsc, EACH4(SL_RCSC))

// Dependent loads around a ring of eight lines (load-to-use latency).
#define CHASE(name, insn)                                                          \
    static void name(uint64_t *const *p, long n) {                                 \
        uint64_t *x = p[0];                                                        \
        __asm__ volatile("1:\n" insn insn insn insn insn insn insn insn            \
                         "subs %[n], %[n], #1\n b.ne 1b\n"                         \
                         : [n] "+r"(n), [x] "+r"(x) : : "memory", "cc");             \
    }
CHASE(k_chase_ldr, "ldr %[x], [%[x]]\n")
CHASE(k_chase_ldapr, "ldapr %[x], [%[x]]\n")
CHASE(k_chase_ldar, "ldar %[x], [%[x]]\n")

struct l1test {
    const char *name;
    void (*fn)(uint64_t *const *, long);
    int accesses;  // memory accesses per loop iteration
};

static const struct l1test l1tests[] = {
    {"load      ldr", k_ldr, 8},
    {"load      ldapr", k_ldapr, 8},
    {"load      ldar", k_ldar, 8},
    {"load      ldr; dmb ishld", k_ldr_dmb, 8},
    {"store     str", k_str, 8},
    {"store     stlr", k_stlr, 8},
    {"store     dmb ishst; str", k_dmb_str, 8},
    {"ld+add+st plain", k_mix_plain, 8},
    {"ld+add+st ldapr/stlr", k_mix_rcpc, 8},
    {"ld+add+st dmb", k_mix_dmb, 8},
    {"st->ld    str, ldr", k_sl_plain, 8},
    {"st->ld    stlr, ldapr", k_sl_rcpc, 8},
    {"st->ld    stlr, ldar", k_sl_rcsc, 8},
    {"vec load  ldr q", k_ldrq, 8},
    {"vec load  ldr q; dmb ishld", k_ldrq_dmb, 8},
    {"vec store str q", k_strq, 8},
    {"vec store dmb ishst; str q", k_dmb_strq, 8},
    {"vec copy  plain", k_cpyq_plain, 8},
    {"vec copy  dmb", k_cpyq_dmb, 8},
    {"chase     ldr", k_chase_ldr, 8},
    {"chase     ldapr", k_chase_ldapr, 8},
    {"chase     ldar", k_chase_ldar, 8},
};

static double best_of(void (*fn)(uint64_t *const *, long), uint64_t *const *p, long n, int runs) {
    double best = 1e30;
    fn(p, n / 10 + 1);  // warm up
    for (int r = 0; r < runs; r++) {
        uint64_t t0 = cycles();
        fn(p, n);
        uint64_t t1 = cycles();
        double c = (double)(t1 - t0) / (double)n;
        if (c < best) best = c;
    }
    return best;
}

static void part1(void) {
    static uint64_t lines[8 * 8 + 8] __attribute__((aligned(64)));
    uint64_t *p[8];
    for (int i = 0; i < 8; i++) p[i] = &lines[i * 8];
    for (int i = 0; i < 8; i++) *p[i] = (uint64_t)p[(i + 1) % 8];  // ring for the chase kernels
    const long n = 2000000;

    printf("Part 1: L1, cycles per access (best of 7, %ld iterations of 8 accesses)\n\n", n);
    double base = 0;
    for (size_t i = 0; i < sizeof l1tests / sizeof l1tests[0]; i++) {
        const struct l1test *t = &l1tests[i];
        // the chase kernels change the ring; restore it
        for (int k = 0; k < 8; k++) *p[k] = (uint64_t)p[(k + 1) % 8];
        double c = best_of(t->fn, p, n, 7) / t->accesses;
        if (i == 0 || strncmp(t->name, l1tests[i - 1].name, 10) != 0) base = c;
        printf("  %-28s %7.2f   x%.2f\n", t->name, c, c / base);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Part 2: sequential copy and random gather/scatter over buffers of increasing size.

// copy n 8-byte elements src -> dst
#define COPY(name, ld, st, pre_st)                                                   \
    static void name(uint64_t *dst, const uint64_t *src, long n) {                  \
        __asm__ volatile("1:\n" ld " x9, [%[s]]\n add %[s], %[s], #8\n" pre_st       \
                         st " x9, [%[d]]\n add %[d], %[d], #8\n"                     \
                         "subs %[n], %[n], #1\n b.ne 1b\n"                          \
                         : [n] "+r"(n), [s] "+r"(src), [d] "+r"(dst) : : "x9", "memory", "cc"); \
    }
COPY(c_plain, "ldr", "str", "")
COPY(c_rcpc, "ldapr", "stlr", "")
COPY(c_dmb, "ldr", "str", "dmb ishld\n dmb ishst\n")

// sum of buf[idx[i]]: two loads per element, the second at a random place
#define GATHER(name, ld, after)                                                              \
    static uint64_t name(const uint64_t *buf, const uint32_t *idx, long n) {                  \
        uint64_t sum = 0;                                                                     \
        __asm__ volatile("1:\n" ld " w10, [%[i]]\n" after "add %[i], %[i], #4\n"              \
                         "add x12, %[b], x10, lsl #3\n" ld " x11, [x12]\n" after              \
                         "add %[sum], %[sum], x11\n subs %[n], %[n], #1\n b.ne 1b\n"          \
                         : [n] "+r"(n), [i] "+r"(idx), [sum] "+r"(sum) : [b] "r"(buf)          \
                         : "x10", "x11", "x12", "memory", "cc");                              \
        return sum;                                                                           \
    }
GATHER(g_plain, "ldr", "")
GATHER(g_rcpc, "ldapr", "")
GATHER(g_dmb, "ldr", "dmb ishld\n")

// buf[idx[i]] = i: one sequential load, one store at a random place
#define SCATTER(name, ld, ld_after, st, pre_st)                                              \
    static void name(uint64_t *buf, const uint32_t *idx, long n) {                            \
        __asm__ volatile("1:\n" ld " w10, [%[i]]\n" ld_after "add %[i], %[i], #4\n"           \
                         "add x12, %[b], x10, lsl #3\n" pre_st st " %[n], [x12]\n"           \
                         "subs %[n], %[n], #1\n b.ne 1b\n"                                  \
                         : [n] "+r"(n), [i] "+r"(idx) : [b] "r"(buf)                           \
                         : "x10", "x12", "memory", "cc");                                     \
    }
SCATTER(s_plain, "ldr", "", "str", "")
SCATTER(s_rcpc, "ldapr", "", "stlr", "")
SCATTER(s_dmb, "ldr", "dmb ishld\n", "str", "dmb ishst\n")

static uint64_t rng = 0x9e3779b97f4a7c15ull;
static uint32_t next_random(void) {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return (uint32_t)(rng >> 16);
}

static void part2(void) {
    static const long sizes[] = {16 << 10, 256 << 10, 2 << 20, 64 << 20};
    static const char *const size_names[] = {"16 KB", "256 KB", "2 MB", "64 MB"};
    const long max_elems = (64 << 20) / 8;
    const long total = 8 << 20;  // elements processed per measurement
    uint64_t *a = aligned_alloc(4096, max_elems * 8);
    uint64_t *b = aligned_alloc(4096, max_elems * 8);
    uint32_t *idx = aligned_alloc(4096, total * 4);
    if (!a || !b || !idx) exit(1);
    memset(a, 1, max_elems * 8);
    memset(b, 2, max_elems * 8);

    printf("\nPart 2: cycles per element (best of 3, %ld elements per run)\n\n", total);
    printf("  %-8s %-8s %8s %8s %8s   %6s %6s\n", "buffer", "kernel", "plain", "rcpc", "dmb", "rcpc", "dmb");
    volatile uint64_t sink = 0;
    for (int s = 0; s < 4; s++) {
        long elems = sizes[s] / 8;
        for (long i = 0; i < total; i++) idx[i] = next_random() % elems;
        double r[3][3];
        for (int v = 0; v < 3; v++) {
            for (int k = 0; k < 3; k++) r[v][k] = 1e30;
            for (int run = 0; run < 3; run++) {
                uint64_t t0, t1;
                // copy: repeat passes over the buffer until 'total' elements are done
                t0 = cycles();
                for (long done = 0; done < total; done += elems) {
                    if (v == 0) c_plain(b, a, elems);
                    if (v == 1) c_rcpc(b, a, elems);
                    if (v == 2) c_dmb(b, a, elems);
                }
                t1 = cycles();
                if ((double)(t1 - t0) / total < r[v][0]) r[v][0] = (double)(t1 - t0) / total;
                t0 = cycles();
                if (v == 0) sink += g_plain(a, idx, total);
                if (v == 1) sink += g_rcpc(a, idx, total);
                if (v == 2) sink += g_dmb(a, idx, total);
                t1 = cycles();
                if ((double)(t1 - t0) / total < r[v][1]) r[v][1] = (double)(t1 - t0) / total;
                t0 = cycles();
                if (v == 0) s_plain(b, idx, total);
                if (v == 1) s_rcpc(b, idx, total);
                if (v == 2) s_dmb(b, idx, total);
                t1 = cycles();
                if ((double)(t1 - t0) / total < r[v][2]) r[v][2] = (double)(t1 - t0) / total;
            }
        }
        static const char *const kn[] = {"copy", "gather", "scatter"};
        for (int k = 0; k < 3; k++)
            printf("  %-8s %-8s %8.2f %8.2f %8.2f   x%5.2f x%5.2f\n", size_names[s], kn[k], r[0][k], r[1][k],
                   r[2][k], r[1][k] / r[0][k], r[2][k] / r[0][k]);
    }
    (void)sink;
}

int main(int argc, char **argv) {
    int cpu = argc > 1 ? atoi(argv[1]) : 3;
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof set, &set) != 0) perror("sched_setaffinity");
    cycles_open();
    printf("cpu %d\n\n", cpu);
    part1();
    part2();
    return 0;
}
