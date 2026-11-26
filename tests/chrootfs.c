// What Chromium's sandbox does to take a process's access to files (sandbox::Credentials::DropFileSystemAccess): in a
// user namespace of its own, a child made with clone(CLONE_FS), which shares the process's root, changes the root to
// its own /proc/self/fdinfo/ and ends; the process is left with an empty directory as its root, and Chromium checks
// that /proc is gone. Under FEX the program still saw every file, and Chromium's zygote stopped at that check.
//   chrootfs          prints one line; exit status 1 if /proc or / still showed files, 2 where no user namespace
//                     could be made (not permitted here)
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static char stack[65536] __attribute__((aligned(16)));

static int child(void* arg) {
    (void)arg;
    if (chroot("/proc/self/fdinfo/") != 0 || chdir("/") != 0)
        _exit(1);
    _exit(0);
}

int main(void) {
    if (unshare(CLONE_NEWUSER) != 0) {
        printf("chrootfs: no user namespace here (%s)\n", strerror(errno));
        return 2;
    }
    pid_t p = clone(child, stack + sizeof stack, CLONE_FS | SIGCHLD, NULL);
    if (p < 0) {
        printf("chrootfs: clone(CLONE_FS): %s\n", strerror(errno));
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
    printf("chrootfs: the child's chroot %s; then /proc %s, %d entries in /\n",
           WIFEXITED(st) && WEXITSTATUS(st) == 0 ? "done" : "failed", proc ? "still there" : "gone", entries);
    return proc || entries ? 1 : 0;
}
