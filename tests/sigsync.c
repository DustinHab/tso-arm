// The numbers of synchronous signals sent by another thread (pthread_kill, as a debugger, a profiler or a crash
// reporter sends them) to a thread that runs a loop: the handler gets them, the program goes on. A version of FEX's
// patches blocked such a signal on the host while it waited for the thread's next exact point, and the fault that
// delivers it there came in blocked: the kernel ended the process (notes section 54).
// Sent without pauses (SIGSYNC_GAP_US=0; default 50 µs between two), each one comes in while FEX still handles the
// one before: FEX's handlers leave these numbers open for faults of FEX's own, and FEX built a second guest frame in
// the middle of the first (or of a sigreturn).
//   sigsync [ROUNDS [SIGNAL...]]   exit status 0 when every signal number reached its handler (default: SIGSEGV,
//                                  SIGBUS, SIGILL, SIGTRAP and SIGFPE)
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int Signals[16] = {SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE};
static int NSIG_SENT = 5;
static volatile int Count[65];
static volatile int Stop;

static void on_signal(int sig) {
    Count[sig]++;
}

static void* spin(void* arg) {
    (void)arg;
    volatile unsigned long n = 0;
    while (!Stop) {
        n++;
    }
    return NULL;
}

int main(int argc, char** argv) {
    const int rounds = argc > 1 ? atoi(argv[1]) : 200;
    const int gap = getenv("SIGSYNC_GAP_US") ? atoi(getenv("SIGSYNC_GAP_US")) : 50;
    if (argc > 2) {
        NSIG_SENT = 0;
        for (int i = 2; i < argc && NSIG_SENT < 16; i++) {
            Signals[NSIG_SENT++] = atoi(argv[i]);
        }
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    for (int i = 0; i < NSIG_SENT; i++) {
        sigaction(Signals[i], &sa, NULL);
    }
    pthread_t t;
    pthread_create(&t, NULL, spin, NULL);
    for (int r = 0; r < rounds; r++) {
        for (int i = 0; i < NSIG_SENT; i++) {
            pthread_kill(t, Signals[i]);
            if (gap > 0) {
                usleep(gap);
            }
        }
    }
    usleep(10000);
    Stop = 1;
    pthread_join(t, NULL);
    int missing = 0;
    for (int i = 0; i < NSIG_SENT; i++) {
        if (Count[Signals[i]] == 0) {
            printf("sigsync: %s never reached its handler\n", strsignal(Signals[i]));
            missing++;
        }
    }
    if (missing) {
        return 1;
    }
    if (argc > 2) {
        printf("sigsync: %d signals sent %d times each to a running thread, all handled\n", NSIG_SENT, rounds);
    } else {
        printf("sigsync: SIGSEGV, SIGBUS, SIGILL, SIGTRAP and SIGFPE sent %d times each to a running thread, all handled\n", rounds);
    }
    return 0;
}
