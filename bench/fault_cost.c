// Cost of the operations a page-state transition needs, AArch64 Linux.
//   mprotect      one page of a shared mapping to PROT_NONE and back
//   fault         touching a PROT_NONE page; the SIGSEGV handler makes it accessible and returns
//   fault+2       as fault, but the handler also changes the page in a second view (two mprotect calls)
// Each with the other cores idle and with three threads spinning on other cores (they share the address space, so
// the TLB invalidations must reach them).
//
// Build: gcc -O2 -pthread -o fault_cost fault_cost.c      Run: ./fault_cost

#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define PAGES 4096
static long page;
static uint8_t *view_a, *view_b;
static volatile int stop;
static int second_view;

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void on_segv(int sig, siginfo_t *si, void *ctx) {
    (void)sig;
    (void)ctx;
    uint8_t *p = (uint8_t *)((uintptr_t)si->si_addr & ~(uintptr_t)(page - 1));
    mprotect(p, page, PROT_READ | PROT_WRITE);
    if (second_view) mprotect(view_b + (p - view_a), page, PROT_NONE);
}

static void *spinner(void *arg) {
    long cpu = (long)arg;
    cpu_set_t s;
    CPU_ZERO(&s);
    CPU_SET(cpu, &s);
    sched_setaffinity(0, sizeof s, &s);
    volatile uint64_t x = 0;
    while (!stop) x++;
    return NULL;
}

static void pin(int cpu) {
    cpu_set_t s;
    CPU_ZERO(&s);
    CPU_SET(cpu, &s);
    sched_setaffinity(0, sizeof s, &s);
}

static void measure(const char *label) {
    // mprotect pairs
    double t0 = now();
    for (int i = 0; i < PAGES; i++) {
        mprotect(view_a + i * page, page, PROT_NONE);
        mprotect(view_a + i * page, page, PROT_READ | PROT_WRITE);
    }
    double t1 = now();
    printf("  %-22s mprotect          %6.2f us per call\n", label, (t1 - t0) / (2.0 * PAGES) * 1e6);

    for (second_view = 0; second_view <= 1; second_view++) {
        for (int i = 0; i < PAGES; i++) view_a[i * page] = 1;  // populate
        mprotect(view_a, PAGES * page, PROT_NONE);
        if (second_view) mprotect(view_b, PAGES * page, PROT_READ | PROT_WRITE);
        t0 = now();
        for (int i = 0; i < PAGES; i++) view_a[i * page]++;  // each faults once
        t1 = now();
        printf("  %-22s fault%-12s %6.2f us per fault\n", label, second_view ? "+2 mprotect" : "+1 mprotect",
               (t1 - t0) / PAGES * 1e6);
        mprotect(view_a, PAGES * page, PROT_READ | PROT_WRITE);
    }
}

int main(void) {
    page = sysconf(_SC_PAGESIZE);
    int fd = memfd_create("views", 0);
    if (fd < 0 || ftruncate(fd, PAGES * page) != 0) return 1;
    view_a = mmap(NULL, PAGES * page, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    view_b = mmap(NULL, PAGES * page, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (view_a == MAP_FAILED || view_b == MAP_FAILED) return 1;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_segv;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    pin(0);
    printf("page %ld bytes, %d pages\n", page, PAGES);
    measure("single thread");
    pthread_t t[3];
    for (long i = 0; i < 3; i++) pthread_create(&t[i], NULL, spinner, (void *)(i + 1));
    usleep(10000);
    measure("3 threads spinning");
    stop = 1;
    for (int i = 0; i < 3; i++) pthread_join(t[i], NULL);
    return 0;
}
