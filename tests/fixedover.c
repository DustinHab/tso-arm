// A mapping made with MAP_FIXED over memory that two threads read: afterwards both read the new mapping. Under the
// page protocol each thread reads through views of its own, and a view that had mapped the old memory went on
// showing it to its thread.
//   fixedover     prints "fixedover: ...: all seen" or what was not, exit status 1 then
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define PAGE 4096
#define PAGES 8

static volatile unsigned *mem;
static volatile int phase;
static volatile unsigned seen;

static void *reader(void *arg) {
    (void)arg;
    while (phase < 1) ;
    seen = mem[PAGE / 4 * 3];  // the old memory, read by this thread: into its views
    __atomic_store_n(&phase, 2, __ATOMIC_RELEASE);
    while (__atomic_load_n(&phase, __ATOMIC_ACQUIRE) < 3) ;
    seen = mem[PAGE / 4 * 3];  // the new mapping
    __atomic_store_n(&phase, 4, __ATOMIC_RELEASE);
    return NULL;
}

int main(void) {
    pthread_t t;
    pthread_create(&t, NULL, reader, NULL);
    unsigned *old = mmap(NULL, PAGES * PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (old == MAP_FAILED) return 2;
    for (int i = 0; i < PAGES * PAGE / 4; i++) old[i] = 0x1111;
    mem = old;
    __atomic_store_n(&phase, 1, __ATOMIC_RELEASE);
    while (__atomic_load_n(&phase, __ATOMIC_ACQUIRE) < 2) ;
    const unsigned before = seen;
    // a new anonymous mapping over it, filled anew
    unsigned *now = mmap(old, PAGES * PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (now != old) return 2;
    for (int i = 0; i < PAGES * PAGE / 4; i++) now[i] = 0x2222;
    __atomic_store_n(&phase, 3, __ATOMIC_RELEASE);
    while (__atomic_load_n(&phase, __ATOMIC_ACQUIRE) < 4) ;
    pthread_join(t, NULL);
    if (before == 0x1111 && seen == 0x2222) {
        printf("fixedover: a mapping made over memory another thread read: it reads the new one, all seen\n");
        return 0;
    }
    printf("fixedover: the other thread read %#x before and %#x after (0x1111, 0x2222 written)\n", before, seen);
    return 1;
}
