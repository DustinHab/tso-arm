// A program that closes every descriptor from 3 up at its start (close_range, as programs that clean up what they
// inherited do: bubblewrap, which Steam's check of user namespaces runs), then opens files of its own, which get the
// lowest free numbers, and runs code FEX has not translated yet. FEX's own descriptors (its disk cache's files, the
// root file system's directory, its server's socket) must survive that and nothing of FEX's may reach the program's
// files: FEX's cache writer wrote its stores into whatever had their numbers, or waited a second for each store at the
// exit when nothing had.
//   closeall          prints one line; exit status 1 if a file of its own got bytes it did not write
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define FILES 16

static int cmp(const void* a, const void* b) {
    const double x = *(const double*)a, y = *(const double*)b;
    return (x > y) - (x < y);
}

int main(void) {
    if (syscall(SYS_close_range, 3U, ~0U, 0U) != 0) {
        perror("closeall: close_range");
        return 2;
    }
    char dir[] = "/tmp/closeall-XXXXXX";
    if (!mkdtemp(dir)) {
        perror("closeall: mkdtemp");
        return 2;
    }
    int fds[FILES];
    char path[64];
    for (int i = 0; i < FILES; i++) {
        snprintf(path, sizeof path, "%s/f%d", dir, i);
        fds[i] = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    }
    // code the program has not run before: formatting, parsing and sorting doubles
    double v[512];
    char buf[64];
    double sum = 0;
    for (int i = 0; i < 512; i++) {
        // (no libm: static linking with it fails with Ubuntu 22.04's cross C library)
        snprintf(buf, sizeof buf, "%.17g", (i * 7919 % 1000) * 1.001 + i / 7.0);
        v[i] = strtod(buf, NULL);
    }
    qsort(v, 512, sizeof v[0], cmp);
    for (int i = 0; i < 512; i++)
        sum += v[i] * (i & 1 ? 1 : -1);
    // time for FEX's cache writer, at the lowest priority, to write what it queued
    usleep(300000);
    long foreign = 0;
    for (int i = 0; i < FILES; i++) {
        struct stat st;
        if (fds[i] >= 0 && fstat(fds[i], &st) == 0)
            foreign += st.st_size;
        close(fds[i]);
        snprintf(path, sizeof path, "%s/f%d", dir, i);
        unlink(path);
    }
    rmdir(dir);
    printf("closeall: %d files of its own after close_range, %ld bytes in them it did not write (%.3f)\n", FILES, foreign, sum);
    return foreign != 0;
}
