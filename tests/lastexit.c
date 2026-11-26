// A process ends when its last thread ends with the exit system call alone (not exit_group), as on Linux, also where
// the emulator runs threads of its own (FEX's disk cache has a writer thread): the main thread leaves with
// pthread_exit, the other thread ends with exit(7), whose status Linux gives the process; with "raw" a single thread
// ends with exit(7). Under tso-arm 0.4.6's first build the process stayed a zombie, the cache's writer left in it.
//   lastexit [raw]     exit status 7; hangs where the process outlives its threads
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static void *last(void *arg) {
    (void)arg;
    usleep(100000);
    printf("lastexit: the last thread ends with exit\n");
    fflush(stdout);
    syscall(SYS_exit, 7);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "raw")) {
        printf("lastexit: one thread ends with exit\n");
        fflush(stdout);
        syscall(SYS_exit, 7);
    }
    pthread_t t;
    pthread_create(&t, NULL, last, NULL);
    pthread_exit(NULL);
}
