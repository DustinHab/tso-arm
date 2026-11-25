// A writable private mapping of a file without a name, as Wine maps wineserver's sections (on Linux private and
// writable on purpose, even read-only views): until the process writes it, it reads the file as it is, what another
// mapping writes there later included; the process's own writes stay its own, the file keeps its bytes, and a
// forked child's writes stay the child's. Under the page protocol such a mapping was copied when it was made.
//   cowmap     prints "cowmap: ...: all right" or the first thing that was not, exit status 1 then
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define PAGE 4096
#define PAGES 8

static void *idle(void *arg) {
    (void)arg;
    pause();
    return NULL;
}

static int bad(const char *what) {
    printf("cowmap: %s\n", what);
    return 1;
}

int main(void) {
    // a second thread, so that the page protocol is awake (as it is in Wine's processes)
    pthread_t t;
    pthread_create(&t, NULL, idle, NULL);
    char path[] = "/tmp/cowmap-XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) return 2;
    unlink(path);  // a file without a name, as wineserver's
    if (ftruncate(fd, PAGES * PAGE) != 0) return 2;
    volatile unsigned *w = mmap(NULL, PAGES * PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    volatile unsigned *p = mmap(NULL, PAGES * PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
    if (w == MAP_FAILED || p == MAP_FAILED) return 2;
    w[0] = 0x1111;
    if (p[0] != 0x1111) return bad("written through the shared mapping first: not seen");
    // read-only now, as Wine makes a read-only view after mapping it
    if (mprotect((void *)p, PAGES * PAGE, PROT_READ) != 0) return 2;
    for (int i = 0; i < PAGES; i++) w[i * PAGE / 4 + 1] = 0x2000u + i;
    for (int i = 0; i < PAGES; i++) {
        if (p[i * PAGE / 4 + 1] != 0x2000u + i) return bad("written later through the shared mapping: not seen through the private one");
    }
    // a forked child writes its copy: neither the parent's mapping nor the file sees it
    if (mprotect((void *)p, PAGES * PAGE, PROT_READ | PROT_WRITE) != 0) return 2;
    pid_t c = fork();
    if (c == 0) {
        p[2] = 0xdead;
        _exit(p[2] == 0xdead ? 0 : 1);
    }
    int st;
    waitpid(c, &st, 0);
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) return bad("the child's write to its private mapping");
    if (p[2] != 0 || w[2] != 0) return bad("the child's write reached the parent's mapping or the file");
    // the kernel writes into it first, for a system call (read from a pipe): the bytes arrive, the file keeps its own
    int pfd[2];
    const unsigned word = 0x5555;
    if (pipe(pfd) != 0 || write(pfd[1], &word, sizeof(word)) != sizeof(word)) return 2;
    if (read(pfd[0], (void *)&p[5 * PAGE / 4], sizeof(word)) != sizeof(word)) return bad("read into the private mapping failed");
    if (p[5 * PAGE / 4] != 0x5555) return bad("read into the private mapping: the bytes did not arrive");
    if (w[5 * PAGE / 4] != 0) return bad("read into the private mapping reached the file");
    // its own write: its own, the file keeps its bytes
    p[3] = 0x3333;
    if (p[3] != 0x3333) return bad("its own write is not seen");
    if (w[3] != 0) return bad("its own write to the private mapping reached the file");
    unsigned v = 0;
    if (pread(fd, &v, sizeof(v), 3 * sizeof(unsigned)) != sizeof(v) || v != 0) return bad("its own write reached the file (read)");
    if (p[0] != 0x1111 || p[PAGE / 4 + 1] != 0x2001) return bad("its earlier contents changed at its own write");
    printf("cowmap: a private writable mapping of a file without a name reads what is written to the file until it writes itself: all right\n");
    return 0;
}
