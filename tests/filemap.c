// Private file mappings under the views (notes section 45): one the program cannot write is mapped from the file
// itself (shared, nothing copied) and must still behave as a private mapping. Each check prints a line; the last line
// is "filemap: all right" or "filemap: N wrong".
//   filemap [DIR]      (a scratch file in DIR, default /tmp)
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static int wrong;
static long page;

static void check(const char* what, int ok) {
    printf("%-58s %s\n", what, ok ? "ok" : "WRONG");
    if (!ok) {
        wrong++;
    }
}

// The file's byte at offset off, read with pread (not through any mapping)
static int file_byte(int fd, off_t off) {
    unsigned char b;
    return pread(fd, &b, 1, off) == 1 ? b : -1;
}

int main(int argc, char** argv) {
    page = sysconf(_SC_PAGESIZE);
    char path[512];
    snprintf(path, sizeof path, "%s/tso-arm-filemap-%d", argc > 1 ? argv[1] : "/tmp", getpid());
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        perror("open");
        return 2;
    }
    // 8 pages and a half: byte i of the file is i % 251
    const size_t len = 8 * page + page / 2;
    unsigned char* buf = malloc(len);
    for (size_t i = 0; i < len; i++) {
        buf[i] = (unsigned char)(i % 251);
    }
    if (write(fd, buf, len) != (ssize_t)len) {
        perror("write");
        return 2;
    }

    // Read-only private mapping of the whole file, a span past its end as ld.so maps a library
    const size_t span = 12 * page;
    unsigned char* m = mmap(NULL, span, PROT_READ, MAP_PRIVATE, fd, 0);
    if (m == MAP_FAILED) {
        perror("mmap");
        return 2;
    }
    check("read-only private mapping reads the file", memcmp(m, buf, len) == 0);
    check("the last page reads zeros past the file's end", m[len] == 0 && m[9 * page - 1] == 0);

    // Writable afterwards: the writes stay in this mapping, the file keeps its bytes
    if (mprotect(m, 4 * page, PROT_READ | PROT_WRITE) != 0) {
        perror("mprotect");
        return 2;
    }
    m[10] = 0xAA;
    m[3 * page + 7] = 0xBB;
    check("made writable: the mapping sees its writes", m[10] == 0xAA && m[3 * page + 7] == 0xBB);
    check("made writable: the file is unchanged", file_byte(fd, 10) == 10 % 251 && file_byte(fd, 3 * page + 7) == (3 * page + 7) % 251);
    check("made writable: the rest still reads the file", memcmp(m + 4 * page, buf + 4 * page, len - 4 * page) == 0);

    // A second read-only mapping: the file, not the first one's writes
    unsigned char* m2 = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
    check("a second private mapping reads the file", m2 != MAP_FAILED && memcmp(m2, buf, len) == 0);

    // Dropped pages of a read-only private mapping read the file again
    check("madvise(DONTNEED) on a read-only private mapping", madvise(m2, len, MADV_DONTNEED) == 0 && memcmp(m2, buf, len) == 0);

    // fork: the child makes its copy writable and writes; neither the parent's mapping nor the file sees it
    unsigned char* m3 = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
    pid_t pid = fork();
    if (pid == 0) {
        if (mprotect(m3, len, PROT_READ | PROT_WRITE) != 0) {
            _exit(3);
        }
        memset(m3, 0xCC, 2 * page);
        _exit(m3[0] == 0xCC && m3[page] == 0xCC ? 0 : 4);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    check("fork: the child writes its own copy", WIFEXITED(st) && WEXITSTATUS(st) == 0);
    check("fork: the parent's mapping keeps the file's bytes", memcmp(m3, buf, len) == 0);
    check("fork: the file keeps its bytes", file_byte(fd, 0) == 0 && file_byte(fd, page) == page % 251);

    // Writable private mapping from the start (a library's data): a copy as well
    unsigned char* w = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
    w[5] = 0xDD;
    check("writable private mapping: its writes stay in it", w[5] == 0xDD && file_byte(fd, 5) == 5);

    // Executable private mapping (code)
    unsigned char* x = mmap(NULL, len, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
    check("executable private mapping reads the file", x != MAP_FAILED && memcmp(x, buf, len) == 0);

    // mremap of a read-only private mapping to a larger size, moved
    unsigned char* r = mmap(NULL, 2 * page, PROT_READ, MAP_PRIVATE, fd, 0);
    unsigned char* r2 = mremap(r, 2 * page, 4 * page, MREMAP_MAYMOVE);
    check("mremap of a read-only private mapping keeps its bytes", r2 != MAP_FAILED && memcmp(r2, buf, 2 * page) == 0);

    struct stat sb;
    fstat(fd, &sb);
    check("the file's size is unchanged", sb.st_size == (off_t)len);
    close(fd);
    unlink(path);
    if (wrong) {
        printf("filemap: %d wrong\n", wrong);
        return 1;
    }
    printf("filemap: all right\n");
    return 0;
}
