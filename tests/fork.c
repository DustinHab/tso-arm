// fork() without exec. Under the page protocol guest memory is shared memory (one object, mapped again into the
// views), which a forked child would go on sharing with its parent. Checks:
//  - the child's writes to a global, the heap, a large buffer and the stack stay in the child
//  - the same while other threads run (their views do not exist in the child), and the child can start threads
//  - memory the guest mapped shared stays shared with the child
//  - read-only memory made writable after the fork, on either side, stays separate
//  - vfork, and many forks in a row (the time per fork)
// Last line "fork: ... all right" or the number of failures; exit status 1 on a failure.
//   fork [forks in a row, default 50]
#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int global = 1;
static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        fflush(stdout);
        failures++;
    }
}

// 0 if the child exited with status 0
static int child_status(pid_t p)
{
    int s = 0;
    if (p < 0 || waitpid(p, &s, 0) != p)
        return -1;
    return WIFEXITED(s) ? WEXITSTATUS(s) : 128 + WTERMSIG(s);
}

static void separate(void)
{
    volatile int stack = 1;
    int *heap = malloc(sizeof *heap);
    char *big = malloc(1 << 22);
    *heap = 1;
    memset(big, 1, 1 << 22);
    pid_t p = fork();
    if (p == 0) {
        // what the parent wrote before the fork, then writes of its own
        int before = global == 1 && *heap == 1 && stack == 1;
        for (int i = 0; i < 1 << 22; i += 4093)
            before = before && big[i] == 1;
        global = 2;
        *heap = 2;
        big[123457] = 2;
        stack = 2;
        _exit(!before ? 5 : global == 2 && *heap == 2 && big[123457] == 2 && stack == 2 ? 0 : 3);
    }
    int st = child_status(p);
    check(st != 5, "the child does not see what the parent wrote before the fork");
    check(st == 0 || st == 5, "the child of a fork failed");
    check(global == 1 && *heap == 1 && big[123457] == 1 && stack == 1, "the child's writes reached the parent");
    free(big);
    free(heap);
}

static atomic_int stop;

static void *worker(void *arg)
{
    volatile long *mine = arg;
    while (!atomic_load(&stop))
        (*mine)++;
    return NULL;
}

static void with_threads(void)
{
    enum { T = 3, Stride = 512 }; // a page per thread
    pthread_t t[T];
    long *counters = calloc((T + 1) * Stride, sizeof(long));
    for (int i = 0; i < T; i++)
        pthread_create(&t[i], NULL, worker, &counters[i * Stride]);
    usleep(20000);
    pid_t p = fork();
    if (p == 0) {
        // the only thread here: the other threads' pages are this process's now, and it can start a thread
        counters[0] = -5;
        counters[Stride] = -5;
        atomic_store(&stop, 0);
        pthread_t c;
        if (pthread_create(&c, NULL, worker, &counters[T * Stride]) != 0)
            _exit(4);
        usleep(10000);
        atomic_store(&stop, 1);
        pthread_join(c, NULL);
        _exit(counters[0] == -5 && counters[Stride] == -5 && counters[T * Stride] > 0 ? 0 : 3);
    }
    check(child_status(p) == 0, "the child of a process with threads failed");
    atomic_store(&stop, 1);
    for (int i = 0; i < T; i++)
        pthread_join(t[i], NULL);
    check(counters[0] > 0 && counters[Stride] > 0 && counters[T * Stride] == 0,
          "the child's writes to the threads' memory reached the parent");
    free(counters);
    atomic_store(&stop, 0);
}

static void shared_memory(void)
{
    volatile int *sh = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    *sh = 1;
    pid_t p = fork();
    if (p == 0) {
        *sh = 2;
        _exit(0);
    }
    check(child_status(p) == 0, "the child writing shared memory failed");
    check(*sh == 2, "memory mapped shared is not shared with the child");
    munmap((void *)sh, 4096);
}

static void read_only(void)
{
    volatile char *ro = mmap(NULL, 8192, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    memset((void *)ro, 1, 8192);
    mprotect((void *)ro, 8192, PROT_READ);
    int to_child[2], to_parent[2];
    if (pipe(to_child) || pipe(to_parent)) {
        check(0, "pipe");
        return;
    }
    char c;
    pid_t p = fork();
    if (p == 0) {
        // the parent wrote first: this side still sees the old contents, and its own write stays here
        close(to_child[1]);
        close(to_parent[0]);
        if (read(to_child[0], &c, 1) != 1)
            _exit(4);
        int ok = ro[0] == 1;
        mprotect((void *)ro, 8192, PROT_READ | PROT_WRITE);
        ro[4096] = 3;
        ok = ok && ro[4096] == 3 && ro[0] == 1;
        if (write(to_parent[1], "x", 1) != 1)
            _exit(4);
        _exit(ok ? 0 : 3);
    }
    // a child that died closes its ends, and the reads below return
    close(to_child[0]);
    close(to_parent[1]);
    mprotect((void *)ro, 8192, PROT_READ | PROT_WRITE);
    ro[0] = 2;
    if (write(to_child[1], "x", 1) != 1 || read(to_parent[0], &c, 1) != 1)
        check(0, "pipe to the child");
    check(child_status(p) == 0, "the parent's write to memory made writable after the fork reached the child");
    check(ro[4096] == 1 && ro[0] == 2, "the child's write to memory made writable after the fork reached the parent");
    munmap((void *)ro, 8192);
    close(to_child[1]);
    close(to_parent[0]);
}

static void with_vfork(void)
{
    pid_t p = vfork();
    if (p == 0)
        _exit(0);
    check(child_status(p) == 0, "the child of a vfork failed");
}

static double many(int n)
{
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    for (int i = 0; i < n; i++) {
        pid_t p = fork();
        if (p == 0)
            _exit(0);
        if (child_status(p) != 0) {
            check(0, "a child of many forks failed");
            return 0;
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &b);
    return ((b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6) / (n ? n : 1);
}

int main(int argc, char **argv)
{
    int n = argc > 1 ? atoi(argv[1]) : 50;
    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGPIPE, SIG_IGN); // a child that died: its pipe reports it, without killing the parent
    separate();
    with_threads();
    shared_memory();
    read_only();
    with_vfork();
    double ms = many(n);
    if (failures)
        printf("fork: %d failures\n", failures);
    else
        printf("fork: separate memory, with threads, shared memory shared, read-only memory copied when made writable, "
               "vfork, %d forks at %.2f ms each: all right\n",
               n, ms);
    return failures != 0;
}
