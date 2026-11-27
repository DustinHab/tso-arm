// The registers a function keeps (rbx, rbp, r12 to r15) across asynchronous signals that come in anywhere: in
// translated code, in system calls, in FEX's own code while it translates (another thread maps, writes, calls and
// unmaps code all the while), at a rate of a profiler's (SIGPROF every 100 microseconds, as V8's sampling
// profiler sends them). V8 keeps the base of its compressed pointers in r14: where a signal's return gave r14 another
// value, V8 called compressed pointers without their base (Slack's renderer, which profiles itself, jumped to
// 0x10003f07 and the like).
//   sigregs [SECONDS]   default 10; exit status 1 if a register held another value after a signal
#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static atomic_int stop;
static atomic_long signals, compiled;
static volatile uint64_t sink;

static void on_prof(int sig) {
    (void)sig;
    // caller-saved registers in use here, as any handler's code has them
    uint64_t x = 0;
    for (int i = 0; i < 16; i++) {
        x = x * 6364136223846793005ULL + (uint64_t)i;
    }
    sink += x;
    atomic_fetch_add_explicit(&signals, 1, memory_order_relaxed);
}

// keeps FEX translating: a page mapped, written, called and unmapped again, over and over
static void* compiler(void* arg) {
    (void)arg;
    uint32_t v = 1;
    while (!atomic_load(&stop)) {
        unsigned char* page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (page == MAP_FAILED) {
            break;
        }
        page[0] = 0xb8; // mov eax, imm32; ret
        memcpy(page + 1, &v, 4);
        page[5] = 0xc3;
        sink += ((uint32_t (*)(void))page)();
        munmap(page, 4096);
        atomic_fetch_add_explicit(&compiled, 1, memory_order_relaxed);
        v++;
    }
    return NULL;
}

// sets the six kept registers to known values, works (arithmetic, a getpid system call every 64 rounds), and gives
// back what the registers hold at the end: io[0] the seed, io[1..6] the registers (rdi holds io throughout)
static void round_trip(uint64_t seed, uint64_t out[6]) {
    uint64_t io[7] = {seed};
    __asm__ volatile(
        "push %%rbp\n"
        "mov 0(%%rdi), %%rbx\n"
        "lea 1(%%rbx), %%rbp\n"
        "lea 2(%%rbx), %%r12\n"
        "lea 3(%%rbx), %%r13\n"
        "lea 4(%%rbx), %%r14\n"
        "lea 5(%%rbx), %%r15\n"
        "mov $4096, %%ecx\n"
        "1:\n"
        "imul $0x5851f42d, %%rsi, %%rsi\n"
        "add %%rcx, %%rsi\n"
        "test $63, %%ecx\n"
        "jnz 2f\n"
        "push %%rcx\n"
        "push %%rsi\n"
        "mov $39, %%eax\n"
        "syscall\n"
        "pop %%rsi\n"
        "pop %%rcx\n"
        "2:\n"
        "dec %%ecx\n"
        "jnz 1b\n"
        "mov %%rbx, 8(%%rdi)\n"
        "mov %%rbp, 16(%%rdi)\n"
        "mov %%r12, 24(%%rdi)\n"
        "mov %%r13, 32(%%rdi)\n"
        "mov %%r14, 40(%%rdi)\n"
        "mov %%r15, 48(%%rdi)\n"
        "pop %%rbp\n"
        :
        : "D"(io)
        : "rax", "rbx", "rcx", "rdx", "rsi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "memory", "cc");
    memcpy(out, io + 1, 6 * sizeof(uint64_t));
}

int main(int argc, char** argv) {
    int secs = argc > 1 ? atoi(argv[1]) : 10;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_prof;
    sa.sa_flags = SA_RESTART;
    sigaction(SIGPROF, &sa, NULL);
    pthread_t t;
    pthread_create(&t, NULL, compiler, NULL);
    struct itimerval it = {{0, 100}, {0, 100}};
    setitimer(ITIMER_PROF, &it, NULL);

    static const char* names[6] = {"rbx", "rbp", "r12", "r13", "r14", "r15"};
    long rounds = 0, bad = 0;
    time_t end = time(NULL) + secs;
    while (time(NULL) < end && bad < 5) {
        uint64_t seed = 0x0123456789ab0000ULL + (uint64_t)rounds * 0x10;
        uint64_t out[6];
        round_trip(seed, out);
        for (int i = 0; i < 6; i++) {
            if (out[i] != seed + (uint64_t)i) {
                printf("sigregs: round %ld: %s %#lx, not %#lx\n", rounds, names[i], (unsigned long)out[i],
                       (unsigned long)(seed + (uint64_t)i));
                bad++;
            }
        }
        rounds++;
    }
    struct itimerval off = {{0, 0}, {0, 0}};
    setitimer(ITIMER_PROF, &off, NULL);
    atomic_store(&stop, 1);
    pthread_join(t, NULL);
    printf("sigregs: %ld rounds, %ld signals, %ld translations of new code, %ld registers wrong\n", rounds,
           atomic_load(&signals), atomic_load(&compiled), bad);
    return bad != 0;
}
