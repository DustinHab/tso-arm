// A loop that waits for its signal handler: a timer's SIGALRM sets the flag the loop reads, round after round.
// tests/ci.sh runs it as FEX translates it, where the deferred signal comes in at the loop's branch back, and with
// the loop's function translated ahead of time, which has no such points: a signal there is delivered at once
// (notes section 54). A signal that waited for a point that never came left the loop running for good.
// Then a loop of register arithmetic only, laid out as Go lays out its loops (a jump to the condition at the bottom,
// the body a block of its own without a memory access), with a timer every millisecond: the handler must come in
// while the loop runs, not only after it (a version of the patches had no point to deliver at in such a loop).
//   sigspin [ROUNDS]       exit status 0 when every loop ended and the timer came in during the register loop
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

static volatile int Flag;
static volatile int Ticks;

static void on_alarm(int sig) {
    (void)sig;
    Flag = 1;
    Ticks++;
}

// the loop translated ahead of time in tests/ci.sh: no calls, one load and a branch back per round
__attribute__((noinline)) unsigned long spin(volatile int* flag) {
    unsigned long n = 0;
    while (!*flag) {
        n++;
    }
    return n;
}

__attribute__((noinline)) static unsigned long register_loop(unsigned long n) {
    unsigned long a = 1, i = 0;
    __asm__ volatile("jmp 2f\n"
                     "1: add %1, %0\n"
                     "   rol $3, %0\n"
                     "   inc %1\n"
                     "2: cmp %2, %1\n"
                     "   jb 1b\n"
                     : "+r"(a), "+r"(i)
                     : "r"(n)
                     : "cc");
    return a;
}

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char** argv) {
    const int rounds = argc > 1 ? atoi(argv[1]) : 50;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_alarm;
    sigaction(SIGALRM, &sa, NULL);
    unsigned long total = 0;
    for (int r = 0; r < rounds; r++) {
        Flag = 0;
        struct itimerval t = {{0, 0}, {0, 2000}};
        setitimer(ITIMER_REAL, &t, NULL);
        total += spin(&Flag);
    }
    printf("sigspin: %d loops, each ended by its handler (%lu rounds of waiting)\n", rounds, total);

    // the register loop: long enough for at least 50 ms
    unsigned long n = 1UL << 22;
    double took = 0;
    int during = 0;
    for (;;) {
        struct itimerval t = {{0, 1000}, {0, 1000}};
        Ticks = 0;
        setitimer(ITIMER_REAL, &t, NULL);
        const double start = now();
        const unsigned long v = register_loop(n);
        during = Ticks;
        took = now() - start;
        struct itimerval off = {{0, 0}, {0, 0}};
        setitimer(ITIMER_REAL, &off, NULL);
        if (v == 0) { // never: keeps the result
            printf("?\n");
        }
        if (took >= 0.05 || n >= (1UL << 40)) {
            break;
        }
        n *= 4;
    }
    const int want = (int)(took * 1000 / 4);
    if (during < want) {
        printf("sigspin: register loop of %.0f ms: the 1 ms timer came in %d times during it, at least %d expected\n", took * 1000,
               during, want);
        return 1;
    }
    printf("sigspin: register loop of %.0f ms, the 1 ms timer came in during it\n", took * 1000);
    return 0;
}
