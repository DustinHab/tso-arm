// unshare(CLONE_NEWUSER) from a program with one thread: Linux lets only a process without other threads enter a new
// user namespace (EINVAL otherwise, checked before the permission), and FEX's disk cache writer is a thread of FEX's
// in every process: Steam's check of user namespaces failed with the cache on.
//   userns           one thread: allowed, or not permitted here (EPERM, EACCES: AppArmor's restriction), not EINVAL
//   userns thread    with a second thread: EINVAL, as natively
// Exit status 1 if the result is not the one expected.
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int fds[2];

static void* waiter(void* arg) {
    char c;
    return read(fds[0], &c, 1) == 1 ? NULL : arg;
}

int main(int argc, char** argv) {
    const int thread = argc > 1 && !strcmp(argv[1], "thread");
    pthread_t t;
    if (thread && (pipe(fds) != 0 || pthread_create(&t, NULL, waiter, NULL) != 0)) {
        perror("userns: second thread");
        return 2;
    }
    const int r = unshare(CLONE_NEWUSER);
    const int e = errno;
    printf("userns: unshare(CLONE_NEWUSER)%s: %s\n", thread ? " with a second thread" : "", r == 0 ? "ok" : strerror(e));
    if (thread) {
        if (write(fds[1], "x", 1) == 1)
            pthread_join(t, NULL);
        return r != 0 && e == EINVAL ? 0 : 1;
    }
    return r == 0 || e == EPERM || e == EACCES ? 0 : 1;
}
