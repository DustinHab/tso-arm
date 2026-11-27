// What Chromium's sandbox does to take a process's access to files (sandbox::Credentials::DropFileSystemAccess): in a
// user namespace of its own, a child made with clone(CLONE_FS), which shares the process's root, changes the root to
// its own /proc/self/fdinfo/ and ends; the process is left with an empty directory as its root, and Chromium checks
// that /proc is gone. Under FEX the program still saw every file, and Chromium's zygote stopped at that check.
// Chromium's own clone is clone(CLONE_FS | CLONE_VM | CLONE_VFORK | CLONE_SETTLS) on a stack and a TLS block of its
// own (`vm`), in its zygote, which is the first process of a PID namespace of its own (`pidns`); the process goes on
// working after it (a thread, a fork), as the zygote does for its renderers.
//   chrootfs [vm|pidns]   prints one line; exit status 1 if /proc or / still showed files or the work after it
//                         failed, 2 where no user namespace could be made (not permitted here)
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static char stack[65536] __attribute__((aligned(16)));
static char tls[65536] __attribute__((aligned(64)));

static int child(void* arg) {
    (void)arg;
    if (chroot("/proc/self/fdinfo/") != 0 || chdir("/") != 0)
        _exit(1);
    _exit(0);
}

static void* thread(void* arg) {
    return arg;
}

static int run(int vm) {
    // Chromium's descriptor of /proc, opened before; after the chroot it checks through it that it is alone (a link
    // count of 3 of self/task/: ".", ".." and one thread) before it sets its capabilities. FEX's disk cache writer, a
    // thread of FEX's own, was left out of that count only by a lookup of /proc/self/task by its path.
    const int proc_fd = open("/proc", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    int flags = CLONE_FS | SIGCHLD;
    if (vm)
        flags |= CLONE_VM | CLONE_VFORK | CLONE_SETTLS;
    pid_t p = clone(child, stack + sizeof stack, flags, NULL, NULL, vm ? tls : NULL, NULL);
    if (p < 0) {
        printf("chrootfs: clone: %s\n", strerror(errno));
        return 1;
    }
    int st = 0;
    waitpid(p, &st, 0);
    struct stat sb;
    const int proc = stat("/proc", &sb) == 0;
    int entries = 0;
    DIR* d = opendir("/");
    if (d) {
        struct dirent* e;
        while ((e = readdir(d)))
            if (strcmp(e->d_name, ".") && strcmp(e->d_name, ".."))
                entries++;
        closedir(d);
    }
    struct stat task;
    const int alone = proc_fd >= 0 && fstatat(proc_fd, "self/task/", &task, 0) == 0 && task.st_nlink == 3;
    // the work a zygote does after it: a thread, a fork whose child ends
    pthread_t t;
    void* r = NULL;
    const int threaded = pthread_create(&t, NULL, thread, (void*)7) == 0 && pthread_join(t, &r) == 0 && r == (void*)7;
    pid_t f = fork();
    if (f == 0)
        _exit(5);
    const int ferr = errno;
    int fst = 0;
    const int forked = f > 0 && waitpid(f, &fst, 0) == f && WIFEXITED(fst) && WEXITSTATUS(fst) == 5;
    char how[96] = "ran";
    if (!forked) {
        if (f < 0)
            snprintf(how, sizeof how, "failed (%s)", strerror(ferr));
        else
            snprintf(how, sizeof how, "failed (child status %#x)", fst);
    }
    printf("chrootfs%s: the child's chroot %s; then /proc %s, %d entries in /, %s through the old /proc; a thread %s, "
           "a fork %s\n",
           vm ? " (CLONE_VM | CLONE_VFORK | CLONE_SETTLS)" : "", WIFEXITED(st) && WEXITSTATUS(st) == 0 ? "done" : "failed",
           proc ? "still there" : "gone", entries, alone ? "alone" : "not alone", threaded ? "ran" : "failed", how);
    fflush(stdout);
    return proc || entries || !alone || !threaded || !forked ? 1 : 0;
}

int main(int argc, char** argv) {
    const int vm = argc > 1 && (!strcmp(argv[1], "vm") || !strcmp(argv[1], "pidns"));
    const int pidns = argc > 1 && !strcmp(argv[1], "pidns");
    if (unshare(CLONE_NEWUSER | (pidns ? CLONE_NEWPID : 0)) != 0) {
        printf("chrootfs: no user namespace here (%s)\n", strerror(errno));
        return 2;
    }
    if (!pidns)
        return run(vm);
    // the first process of the new PID namespace, as Chromium's zygote
    pid_t z = fork();
    if (z == 0)
        _exit(getpid() == 1 ? run(1) : 3);
    int st = 0;
    if (z < 0 || waitpid(z, &st, 0) != z) {
        printf("chrootfs: no first process of a PID namespace (%s)\n", strerror(errno));
        return 1;
    }
    if (!WIFEXITED(st))
        printf("chrootfs (pidns): the first process ended with signal %d\n", WTERMSIG(st));
    return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}
