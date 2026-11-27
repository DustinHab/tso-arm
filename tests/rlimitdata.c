// A program that limits its own data (RLIMIT_DATA, as Chromium does for its renderers: 8 GB) and then starts
// threads. Under FEX the host's limit counted FEX's own memory as well (some 3.6 GB at a process's start, some 400 MB
// for each thread's lookup cache and heap): the mapping of a new thread's lookup cache failed, and the thread ran
// with its L1 cache in nothing (Slack's renderer jumped to 0x10003f07 and the like). FEX keeps the guest's limit for
// the guest now, and getrlimit gives it back.
//   rlimitdata      exit status 1 if a thread did not do its work or the limit read back is another
#define _GNU_SOURCE
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>

#define THREADS 16
#define EACH (32UL << 20)

static void* work(void* arg) {
    uintptr_t n = (uintptr_t)arg;
    unsigned char* p = mmap(NULL, EACH, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        return (void*)1;
    }
    uint64_t sum = 0;
    for (size_t i = 0; i < EACH; i += 4096) {
        p[i] = (unsigned char)(i >> 12) + (unsigned char)n;
        sum += p[i];
    }
    munmap(p, EACH);
    return sum ? NULL : (void*)1;
}

int main(void) {
    struct rlimit want = {2UL << 30, 2UL << 30};
    if (setrlimit(RLIMIT_DATA, &want) != 0) {
        perror("rlimitdata: setrlimit");
        return 1;
    }
    struct rlimit got;
    getrlimit(RLIMIT_DATA, &got);
    pthread_t t[THREADS];
    int started = 0, done = 0;
    for (uintptr_t i = 0; i < THREADS; i++) {
        if (pthread_create(&t[i], NULL, work, (void*)i) == 0) {
            started++;
        }
    }
    for (int i = 0; i < started; i++) {
        void* r;
        pthread_join(t[i], &r);
        done += r == NULL;
    }
    // raising the hard limit again needs CAP_SYS_RESOURCE: as for any process, unless it is root
    struct rlimit up = {RLIM_INFINITY, RLIM_INFINITY};
    const int raised = setrlimit(RLIMIT_DATA, &up) == 0;
    printf("rlimitdata: limit %lu MB read back as %lu MB, %d of %d threads did their work, raising it again %s\n",
           (unsigned long)(want.rlim_cur >> 20), (unsigned long)(got.rlim_cur >> 20), done, THREADS,
           raised ? "allowed" : "refused");
    return got.rlim_cur == want.rlim_cur && got.rlim_max == want.rlim_max && done == THREADS ? 0 : 1;
}
