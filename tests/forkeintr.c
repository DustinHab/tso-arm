// A fork leaves the program's other threads alone: their system calls go on as if nothing happened. Under the page
// protocol, after a fallback to full ordering, a fork holds the other threads with a signal of FEX's own until the
// child has its copy of guest memory; a blocking call it interrupted must not come back with EINTR, which the
// program never asked for (it has no signal handlers). Two threads wait in poll and nanosleep (calls the kernel does
// not restart after a handler, whatever SA_RESTART says) and one in read on a pipe, while the main thread forks.
//   forkeintr [forks]     prints "forkeintr: N forks, E calls interrupted", exit status 1 if E > 0
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile int stop;
static volatile int interrupted;
static int pipefd[2];

static void *poller(void *arg) {
    (void)arg;
    while (!stop) {
        if (poll(NULL, 0, 20) == -1 && errno == EINTR) __atomic_add_fetch(&interrupted, 1, __ATOMIC_RELAXED);
    }
    return NULL;
}

static void *sleeper(void *arg) {
    (void)arg;
    while (!stop) {
        struct timespec t = {0, 20000000};
        if (nanosleep(&t, NULL) == -1 && errno == EINTR) __atomic_add_fetch(&interrupted, 1, __ATOMIC_RELAXED);
    }
    return NULL;
}

static void *reader(void *arg) {
    (void)arg;
    char c;
    for (;;) {
        ssize_t n = read(pipefd[0], &c, 1);
        if (n == -1 && errno == EINTR) {
            __atomic_add_fetch(&interrupted, 1, __ATOMIC_RELAXED);
            continue;
        }
        if (n <= 0 || c == 'q') return NULL;
    }
}

int main(int argc, char **argv) {
    int forks = argc > 1 ? atoi(argv[1]) : 50;
    if (pipe(pipefd) != 0) return 2;
    pthread_t t[3];
    pthread_create(&t[0], NULL, poller, NULL);
    pthread_create(&t[1], NULL, sleeper, NULL);
    pthread_create(&t[2], NULL, reader, NULL);
    struct timespec settle = {0, 50000000};
    nanosleep(&settle, NULL);
    for (int i = 0; i < forks; i++) {
        pid_t p = fork();
        if (p == 0) _exit(0);
        int st;
        waitpid(p, &st, 0);
        struct timespec gap = {0, 2000000};
        nanosleep(&gap, NULL);
    }
    stop = 1;
    if (write(pipefd[1], "q", 1) != 1) return 2;
    for (int i = 0; i < 3; i++) pthread_join(t[i], NULL);
    printf("forkeintr: %d forks, %d calls interrupted\n", forks, interrupted);
    return interrupted > 0;
}
