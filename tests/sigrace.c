// Signals that meet each other, as CPython's test_signal sends them (FEX without the tso-arm patches crashes in both):
//  at once: a timer of 1 to 11 microseconds (SIGALRM) and kill(SIGUSR1) together, one handler for both that writes
//    a byte to a pipe (Python's wakeup descriptor); the second signal comes in while FEX still handles the first.
//    Every signal must arrive.
//  changing: a thread raises SIGUSR1 in a loop while the main thread switches its action between a handler and
//    SIG_IGN; a signal delivered while its action changes must find either one, whole.
//   sigrace [ROUNDS [alt]]     alt: the handlers on an alternate signal stack
// Last line "sigrace: N at once, M handled while changing"; exit status 1 if a signal was lost.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

// a count per signal: one signal's handler can come in while the other's runs (that is the test), but not while
// its own does (the signal is blocked there), so neither count can lose an increment
static volatile sig_atomic_t usr1, alrm;
static int wfd;
#define got (usr1 + alrm)

static void handler(int sig)
{
    int e = errno;
    char c = (char)sig;
    if (sig == SIGUSR1)
        usr1 = usr1 + 1;
    else
        alrm = alrm + 1;
    (void)!write(wfd, &c, 1);
    errno = e;
}

static void set(int sig, void (*h)(int))
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = h;
    sa.sa_flags = SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, 0);
}

static volatile int stop;
static volatile long raised;

static void *raiser(void *arg)
{
    (void)arg;
    while (!stop) {
        raise(SIGUSR1);
        raised++;
    }
    return 0;
}

int main(int argc, char **argv)
{
    int n = argc > 1 ? atoi(argv[1]) : 20000;
    int p[2];
    if (pipe(p))
        return 1;
    wfd = p[1];
    fcntl(p[0], F_SETFL, O_NONBLOCK);
    fcntl(p[1], F_SETFL, O_NONBLOCK);
    // "alt": the handlers run on an alternate signal stack, as Python's do (faulthandler sets one up), the second
    // signal's frame below the first one's there
    static char altstack[1 << 16];
    if (argc > 2 && !strcmp(argv[2], "alt")) {
        stack_t ss = {.ss_sp = altstack, .ss_size = sizeof(altstack), .ss_flags = 0};
        sigaltstack(&ss, 0);
    }
    set(SIGUSR1, handler);
    set(SIGALRM, handler);
    unsigned s = 12345;
    char buf[256];
    for (int i = 0; i < n; i++) {
        s = s * 1103515245 + 12345;
        struct itimerval t = {{0, 0}, {0, 1 + (s >> 16) % 10}};
        setitimer(ITIMER_REAL, &t, 0);
        kill(getpid(), SIGUSR1);
        struct timespec d = {0, 10000};
        for (int k = 0; (usr1 <= i || alrm <= i) && k < 200000; k++)
            nanosleep(&d, 0);
        if (usr1 <= i || alrm <= i) {
            printf("sigrace: lost a signal in round %d of %d: SIGUSR1 %d, SIGALRM %d times\n", i, n, (int)usr1,
                   (int)alrm);
            return 1;
        }
        (void)!read(p[0], buf, sizeof(buf));
    }
    long atonce = got;

    usr1 = alrm = 0;
    pthread_t t;
    pthread_create(&t, 0, raiser, 0);
    for (int i = 0; i < 20 * n || raised < 100 || got < 1; i++) {
        set(SIGUSR1, handler);
        set(SIGUSR1, SIG_IGN);
        if ((i & 255) == 0)
            (void)!read(p[0], buf, sizeof(buf));
    }
    stop = 1;
    pthread_join(t, 0);
    printf("sigrace: %ld at once, %ld handled while changing\n", atonce, (long)got);
    return 0;
}
