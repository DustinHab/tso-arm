// Synchronous signals' numbers sent without pauses by three threads (pthread_kill, as profilers and crash reporters
// send them) to a thread that keeps FEX translating: it writes a new function to fresh memory and calls it, again
// and again. A signal that comes in while FEX translates waits as a frame of FEX's deferral, and the next ones come in
// during FEX's handler for that one, each queueing a frame of its own in the middle of the one before. A frame queued
// so was once counted before it was written: delivered as signal 0, it marked signal 64 pending, and FEX sent that to
// the thread, which ended the process ("Real-time signal 30"; notes section 69). Not in the CI yet: FEX still ends
// it with SIGSEGV or hangs, a fault of its own while it sets up the guest's frame (notes section 69).
//   sigdefer [FUNCTIONS [SENDERS]]   exit status 0 when every function returned its number and every signal number
//                                    reached its handler (default 3000 functions, 3 sending threads; 0: none)
#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static const int Signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE};
#define NSIGNALS (int)(sizeof Signals / sizeof Signals[0])
static volatile int Count[65];
static volatile int Stop;
static pthread_t Target;

static void on_signal(int sig) {
    Count[sig]++;
}

static void* sender(void* arg) {
    int i = (int)(intptr_t)arg;
    while (!Stop) {
        pthread_kill(Target, Signals[i % NSIGNALS]);
        i++;
    }
    return NULL;
}

int main(int argc, char** argv) {
    const int functions = argc > 1 ? atoi(argv[1]) : 3000;
    const int senders = argc > 2 ? atoi(argv[2]) : 3;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    for (int i = 0; i < NSIGNALS; i++)
        sigaction(Signals[i], &sa, NULL);
    Target = pthread_self();
    pthread_t s[8];
    for (int i = 0; i < senders && i < 8; i++)
        pthread_create(&s[i], NULL, sender, (void*)(intptr_t)i);
    int wrong = 0;
    for (int n = 0; n < functions; n++) {
        // mov eax, n; ret: new code at a new address each time, so FEX translates each one
        uint8_t* code = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (code == MAP_FAILED) {
            perror("mmap");
            return 1;
        }
        code[0] = 0xb8;
        memcpy(code + 1, &n, 4);
        code[5] = 0xc3;
        int (*fn)(void) = (int (*)(void))code;
        wrong += fn() != n;
        munmap(code, 4096);
    }
    Stop = 1;
    for (int i = 0; i < senders && i < 8; i++)
        pthread_join(s[i], NULL);
    int missing = 0;
    long total = 0;
    for (int i = 0; i < NSIGNALS; i++) {
        missing += senders > 0 && Count[Signals[i]] == 0;
        total += Count[Signals[i]];
    }
    printf("sigdefer: %d functions translated, %d wrong, %ld signals handled, %d numbers never%s\n", functions, wrong, total,
           missing, wrong || missing ? " (wrong)" : "");
    return wrong || missing;
}
