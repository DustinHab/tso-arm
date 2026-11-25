// Memory another process writes, mapped the way Wine maps wineserver's session memory: the writer (a process of its
// own, as wineserver is: started anew with execve, so that it begins with one thread, as wineserver does) maps a file
// shared and writable, grows it and maps each new part on its own; the reader reserves address space first and maps
// the file read-only and shared over it with MAP_FIXED, a block at a time, and reads what the writer put there after
// each step. With "threads", a second thread of the reader reads as well (its own views under the page protocol);
// without, the reader has one thread, as Wine's explorer.exe.
//   sharedmap [threads]     prints "sharedmap: ...: all seen" or what was not seen, exit status 1 then
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#define BLOCK (64 * 1024)
#define BLOCKS 6

static int sock;
static volatile unsigned *view[BLOCKS];
static volatile int wrong;

static void ask(int step) {
    char c = (char)step;
    if (write(sock, &c, 1) != 1 || read(sock, &c, 1) != 1) exit(2);
}

// the writer: block 0 exists; each request makes block `step` (growing the file) and writes its words
static int writer(int fd, int s) {
    unsigned *map[BLOCKS] = {0};
    map[0] = mmap(NULL, BLOCK, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map[0] == MAP_FAILED) return 2;
    for (;;) {
        char c;
        if (read(s, &c, 1) != 1) return 0;
        int b = c;
        if (b > 0 && !map[b]) {
            if (ftruncate(fd, (off_t)(b + 1) * BLOCK) != 0) return 2;
            map[b] = mmap(NULL, BLOCK, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)b * BLOCK);
            if (map[b] == MAP_FAILED) return 2;
        }
        for (int i = 0; i < BLOCK / 4; i += 1024) map[b][i] = 0x10000u * (b + 1) + (unsigned)i;
        if (write(s, &c, 1) != 1) return 2;
    }
}

static int check(int b) {
    for (int i = 0; i < BLOCK / 4; i += 1024) {
        if (view[b][i] != 0x10000u * (b + 1) + (unsigned)i) return 0;
    }
    return 1;
}

static volatile int go = -1;
static void *second(void *arg) {
    (void)arg;
    for (int done = -1; done < BLOCKS - 1;) {
        int g = go;
        if (g > done) {
            if (!check(g)) wrong++;
            done = g;
            __atomic_store_n(&go, -2 - g, __ATOMIC_RELEASE);
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc == 4 && !strcmp(argv[1], "writer")) return writer(atoi(argv[2]), atoi(argv[3]));
    const int threads = argc > 1 && !strcmp(argv[1], "threads");
    char path[] = "/tmp/sharedmap-XXXXXX";
    int fd = mkstemp(path);
    int sv[2];
    if (fd < 0) return 2;
    unlink(path);
    if (ftruncate(fd, BLOCK) != 0 || socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) return 2;
    pid_t w = fork();
    if (w == 0) {
        close(sv[0]);
        char a[16], b[16];
        snprintf(a, sizeof(a), "%d", fd);
        snprintf(b, sizeof(b), "%d", sv[1]);
        execl("/proc/self/exe", argv[0], "writer", a, b, (char *)NULL);
        _exit(3);
    }
    close(sv[1]);
    sock = sv[0];
    pthread_t t;
    if (threads) pthread_create(&t, NULL, second, NULL);
    // address space reserved for all blocks, as Wine reserves a view before it maps a section into it
    char *base = mmap(NULL, BLOCKS * BLOCK, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    for (int b = 0; b < BLOCKS; b++) {
        ask(b);
        view[b] = mmap(base + (size_t)b * BLOCK, BLOCK, PROT_READ, MAP_SHARED | MAP_FIXED, fd, (off_t)b * BLOCK);
        if (view[b] == MAP_FAILED) return 2;
        if (!check(b)) {
            printf("sharedmap: block %d: read %#x, written %#x\n", b, view[b][1024], 0x10000u * (b + 1) + 1024);
            wrong++;
        }
        if (threads) {
            go = b;
            while (__atomic_load_n(&go, __ATOMIC_ACQUIRE) != -2 - b) ;
        }
        // written again after the mapping: seen as well
        ask(b);
        if (!check(b)) wrong++;
    }
    if (threads) pthread_join(t, NULL);
    close(sock);
    waitpid(w, NULL, 0);
    if (!wrong)
        printf("sharedmap: %d blocks another process wrote, mapped read-only over reserved space, read by %d thread%s: all seen\n",
               BLOCKS, threads ? 2 : 1, threads ? "s" : "");
    else
        printf("sharedmap: %d reads did not see what the writer wrote\n", wrong);
    return wrong > 0;
}
