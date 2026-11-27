// posix_spawn from a program whose other threads translate new code all the while (each writes a small function
// into a page of its own and calls it, which FEX throws away and translates again every time). glibc's posix_spawn
// starts the child with clone(CLONE_VM | CLONE_VFORK) on a stack of its own; under FEX that child ran on its
// parent's memory, and its unlocking after the fork released the locks the parent held for it, with the parent's
// other threads going on: FEX's lookup cache and the decoder's pool broke in the parent (Slack's renderer: null
// pointers inside FEX, delivered to the guest's SIGSEGV handler, every thread then waiting for a lock).
//   spawnvm [N]      N children (default 200), each /proc/self/exe started again; exit status 1 on a child that did
//                    not exit with 0 or a function that returned the wrong value
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;
static atomic_int stop;
static atomic_long calls, wrong;

static void* writer(void* arg) {
    unsigned char* page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (page == MAP_FAILED) {
        atomic_fetch_add(&wrong, 1);
        return NULL;
    }
    uint32_t v = (uint32_t)(uintptr_t)arg * 1000003u;
    while (!atomic_load(&stop)) {
        // mov eax, imm32; ret
        page[0] = 0xb8;
        memcpy(page + 1, &v, 4);
        page[5] = 0xc3;
        uint32_t (*f)(void) = (uint32_t (*)(void))page;
        if (f() != v) {
            atomic_fetch_add(&wrong, 1);
        }
        atomic_fetch_add(&calls, 1);
        v++;
    }
    munmap(page, 4096);
    return NULL;
}

int main(int argc, char** argv) {
    if (argc > 1 && !strcmp(argv[1], "child")) {
        return 0;
    }
    int n = argc > 1 ? atoi(argv[1]) : 200;
    pthread_t t[4];
    for (long i = 0; i < 4; i++) {
        pthread_create(&t[i], NULL, writer, (void*)(i + 1));
    }
    int bad = 0;
    for (int i = 0; i < n; i++) {
        char* args[] = {argv[0], "child", NULL};
        pid_t pid;
        int e = posix_spawn(&pid, "/proc/self/exe", NULL, NULL, args, environ);
        if (e) {
            printf("spawnvm: posix_spawn %d: %s\n", i, strerror(e));
            bad = 1;
            break;
        }
        int st = 0;
        if (waitpid(pid, &st, 0) != pid || !WIFEXITED(st) || WEXITSTATUS(st) != 0) {
            printf("spawnvm: child %d: status %#x\n", i, st);
            bad = 1;
            break;
        }
    }
    // a program that is not there: an error from posix_spawn, or (where the child's copy of memory keeps the error
    // from the parent) a child that exits with 127
    char* none[] = {"/nonexistent/spawnvm", NULL};
    pid_t pid;
    int e = posix_spawn(&pid, none[0], NULL, NULL, none, environ);
    int st = 0;
    const char* missing = e == ENOENT ? "ENOENT" : "?";
    if (!e) {
        waitpid(pid, &st, 0);
        missing = WIFEXITED(st) && WEXITSTATUS(st) == 127 ? "a child exiting with 127" : "?";
    }
    if (missing[0] == '?') {
        printf("spawnvm: a missing program: posix_spawn %d, status %#x\n", e, st);
        bad = 1;
    }
    atomic_store(&stop, 1);
    for (int i = 0; i < 4; i++) {
        pthread_join(t[i], NULL);
    }
    if (atomic_load(&wrong)) {
        printf("spawnvm: %ld of %ld calls returned a wrong value\n", atomic_load(&wrong), atomic_load(&calls));
        bad = 1;
    }
    if (!bad) {
        printf("spawnvm: %d children exited with 0 while 4 threads rewrote and called their code %ld times; a missing "
               "program: %s\n", n, atomic_load(&calls), missing);
    }
    return bad;
}
