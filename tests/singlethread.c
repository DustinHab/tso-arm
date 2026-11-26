// Whether a program sees its own threads in /proc/self/task, and no others, as Chromium's zygote checks before it
// forks (sandbox::ThreadHelpers::IsSingleThreaded: the directory's link count is 3, "." and ".." and one task).
// Under FEX a thread of FEX's own counted as well: the writer of its disk cache made Steam's steamwebhelper (Chromium)
// stop at "CHECK(sandbox::ThreadHelpers::IsSingleThreaded())" in every zygote. The count is taken with stat, with
// fstatat from a descriptor of /proc as Chromium does, and with statx, alone and with a second thread.
//   singlethread          prints the tasks it sees; exit status 1 where one count is not the program's
#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

static int fds[2];

static void* waiter(void* arg) {
    char c;
    (void)arg;
    return read(fds[0], &c, 1) == 1 ? NULL : arg;
}

// the tasks each way sees, -1 where it failed
static int counts(long* got) {
    struct stat st;
    got[0] = stat("/proc/self/task/", &st) == 0 ? (long)st.st_nlink - 2 : -1;
    int proc = open("/proc", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    got[1] = proc >= 0 && fstatat(proc, "self/task/", &st, 0) == 0 ? (long)st.st_nlink - 2 : -1;
    if (proc >= 0)
        close(proc);
    struct statx sx;
    got[2] = statx(AT_FDCWD, "/proc/self/task", 0, STATX_NLINK, &sx) == 0 ? (long)sx.stx_nlink - 2 : -1;
    return 3;
}

static int check(const char* what, long want) {
    static const char* how[] = {"stat", "fstatat", "statx"};
    long got[3];
    int n = counts(got), bad = 0;
    printf("singlethread: %s:", what);
    for (int i = 0; i < n; i++) {
        printf(" %s %ld", how[i], got[i]);
        bad |= got[i] != want;
    }
    printf("%s\n", bad ? " (wrong)" : "");
    return bad;
}

int main(void) {
    int bad = check("one thread", 1);
    pthread_t t;
    if (pipe(fds) != 0 || pthread_create(&t, NULL, waiter, NULL) != 0) {
        perror("singlethread: second thread");
        return 2;
    }
    bad |= check("two threads", 2);
    if (write(fds[1], "x", 1) == 1)
        pthread_join(t, NULL);
    return bad;
}
