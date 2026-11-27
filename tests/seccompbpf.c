// What Chromium asks before it uses seccomp-bpf for its renderers (sandbox::SandboxBPF::SupportsSeccompSandbox):
// prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, NULL) and seccomp(SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC,
// NULL) fail with EFAULT where the kernel supports filters. Then a filter of its own, installed for all threads
// (TSYNC), that makes getpid fail with EPERM: in this thread and in one that ran before the filter came. Chromium said
// "Lacking support for seccomp-bpf sandbox" under FEX, and its renderers ran with namespaces alone.
//   seccompbpf      prints one line; exit status 1 if an answer is not the kernel's
#define _GNU_SOURCE
#include <errno.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

static pthread_barrier_t ready, installed;

// a thread that runs before the filter is installed, which TSYNC has to reach
static void* early(void* arg) {
    (void)arg;
    pthread_barrier_wait(&ready);
    pthread_barrier_wait(&installed);
    errno = 0;
    long r = syscall(SYS_getpid);
    return (void*)(r == -1 && errno == EPERM ? 1L : 0L);
}

int main(void) {
    errno = 0;
    const int prctl_probe = prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, NULL) == -1 && errno == EFAULT;
    errno = 0;
    const int tsync_probe = syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, NULL) == -1 && errno == EFAULT;
    const int get_mode = prctl(PR_GET_SECCOMP, 0, 0, 0, 0);

    pthread_barrier_init(&ready, NULL, 2);
    pthread_barrier_init(&installed, NULL, 2);
    pthread_t t;
    pthread_create(&t, NULL, early, NULL);
    pthread_barrier_wait(&ready);

    struct sock_filter f[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_getpid, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog prog = {sizeof f / sizeof f[0], f};
    const int nnp = prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0;
    errno = 0;
    const long rv = syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, &prog);
    const int install_err = errno;
    pthread_barrier_wait(&installed);
    errno = 0;
    const long me = syscall(SYS_getpid);
    const int denied_here = me == -1 && errno == EPERM;
    void* r = NULL;
    pthread_join(t, &r);
    const int denied_there = r == (void*)1L;
    const int mode_after = prctl(PR_GET_SECCOMP, 0, 0, 0, 0);
    printf("seccompbpf: prctl probe %s, TSYNC probe %s, mode %d; no_new_privs %s, filter %s, getpid here %s, in the "
           "earlier thread %s, mode then %d\n",
           prctl_probe ? "EFAULT" : "other", tsync_probe ? "EFAULT" : "other", get_mode, nnp ? "set" : "failed",
           rv == 0 ? "installed" : strerror(install_err), denied_here ? "EPERM" : "allowed", denied_there ? "EPERM" : "allowed",
           mode_after);
    return prctl_probe && tsync_probe && get_mode == 0 && nnp && rv == 0 && denied_here && denied_there && mode_after == 2 ? 0 : 1;
}
