// A read-only private mapping of a file another mapping writes, as Wine's processes map the session memory that
// wineserver fills: what is written through the shared mapping is seen through the private one, also where the
// file grew after the private mapping was made (pages past the file's end then). Under the page protocol the part
// of a private file mapping past the file's end was memory of its own, zeros for good.
//   filegrow     prints "filegrow: ...: all seen" or what was not seen, exit status 1 then
#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define PAGE 4096
#define PAGES 16

static void *idle(void *arg) {
    (void)arg;
    pause();
    return NULL;
}

int main(void) {
    // a second thread, so that the page protocol is awake (as it is in Wine's processes)
    pthread_t t;
    pthread_create(&t, NULL, idle, NULL);
    char path[] = "/tmp/filegrow-XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) return 2;
    unlink(path);
    if (ftruncate(fd, 2 * PAGE) != 0) return 2;
    unsigned *writer = mmap(NULL, PAGES * PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    const volatile unsigned *reader = mmap(NULL, PAGES * PAGE, PROT_READ, MAP_PRIVATE, fd, 0);
    if (writer == MAP_FAILED || reader == MAP_FAILED) return 2;
    int wrong = 0;
    // within the file as it was
    writer[PAGE / 4] = 0x1111;
    if (reader[PAGE / 4] != 0x1111) {
        printf("filegrow: within the file: read %#x, written 0x1111\n", reader[PAGE / 4]);
        wrong++;
    }
    // the file grows; written past its old end
    if (ftruncate(fd, PAGES * PAGE) != 0) return 2;
    for (int p = 2; p < PAGES; p++) writer[p * PAGE / 4 + 1] = 0x2000 + p;
    for (int p = 2; p < PAGES; p++) {
        if (reader[p * PAGE / 4 + 1] != 0x2000u + p) {
            if (!wrong) printf("filegrow: page %d past the old end: read %#x, written %#x\n", p, reader[p * PAGE / 4 + 1], 0x2000 + p);
            wrong++;
        }
    }
    // written again, within the old end and past it
    writer[PAGE / 4] = 0x3333;
    writer[10 * PAGE / 4 + 1] = 0x4444;
    if (reader[PAGE / 4] != 0x3333 || reader[10 * PAGE / 4 + 1] != 0x4444) {
        printf("filegrow: rewritten: read %#x and %#x\n", reader[PAGE / 4], reader[10 * PAGE / 4 + 1]);
        wrong++;
    }
    if (!wrong) printf("filegrow: written through a shared mapping, read through a private one, the file grown: all seen\n");
    return wrong > 0;
}
