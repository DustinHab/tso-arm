// Mappings x86 makes readable although the program did not ask for it: a file mapped shared with PROT_WRITE alone,
// anonymous memory with PROT_WRITE alone, and a file mapped with PROT_EXEC alone. x86's page tables cannot express
// write-only or execute-only, so programs read them (and read-modify-write them). wineserver writes to a file it
// maps with PROT_WRITE alone; under the page protocol its first access went to it as a fault and it stopped.
// A second thread runs throughout so that the views are awake.
//   writeonly        prints "writeonly: ... all right", exit status 1 on a wrong value
#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static volatile int stop;
static void *spin(void *arg) {
    (void)arg;
    while (!stop) __asm__ volatile("pause");
    return NULL;
}

int main(void) {
    pthread_t t;
    pthread_create(&t, NULL, spin, NULL);
    char path[] = "/tmp/writeonly-XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0 || ftruncate(fd, 8192) != 0) return 2;
    unlink(path);
    int bad = 0;

    // a file, shared, PROT_WRITE alone: written, read, and incremented in place
    volatile unsigned *w = mmap(NULL, 8192, PROT_WRITE, MAP_SHARED, fd, 0);
    if (w == MAP_FAILED) return 2;
    for (int i = 0; i < 2048; i++) w[i] = i * 3u;
    for (int i = 0; i < 2048; i++) __asm__ volatile("addl $1, %0" : "+m"(w[i]));  // read-modify-write
    for (int i = 0; i < 2048; i++) bad += w[i] != i * 3u + 1;
    unsigned v;
    if (pread(fd, &v, 4, 4 * 100) != 4 || v != 301) bad++;

    // anonymous memory, PROT_WRITE alone, and made PROT_WRITE alone by mprotect
    volatile unsigned *a = mmap(NULL, 4096, PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    a[7] = 77;
    bad += a[7] != 77;
    volatile unsigned *b = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    b[9] = 99;
    mprotect((void *)b, 4096, PROT_WRITE);
    b[9] += 1;
    bad += b[9] != 100;

    // the same file with PROT_EXEC alone: read
    volatile unsigned *x = mmap(NULL, 8192, PROT_EXEC, MAP_SHARED, fd, 0);
    if (x != MAP_FAILED) bad += x[100] != 301;

    stop = 1;
    pthread_join(t, NULL);
    printf("writeonly: a shared file and anonymous memory written with PROT_WRITE alone, read-modify-written, a file read with PROT_EXEC alone: %s\n",
           bad ? "WRONG" : "all right");
    return bad != 0;
}
