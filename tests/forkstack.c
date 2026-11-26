// Chromium's way of forking (base::ForkWithFlags, which its zygote forks every renderer, GPU and utility process
// with): clone() without CLONE_VM onto a stack of its own, and in the child a longjmp back onto the caller's stack. The
// child's memory has to be its own, also while other threads of the parent work on memory they share.
//   forkstack [ROUNDS]     exit status 1 if a child crashed or a write of the child's reached the parent
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile long shared[4096];
static volatile int stop;

static void* worker(void* arg) {
    long k = (long)arg;
    while (!stop) {
        for (int i = 0; i < 4096; i += 64) shared[i] += k;
    }
    return NULL;
}

static int helper(void* arg) {
    longjmp(*(jmp_buf*)arg, 1);
    return 0;
}

// as base::ForkWithFlags: setjmp here, clone onto a small stack, longjmp back in the child
static __attribute__((noinline)) pid_t clone_and_longjmp(jmp_buf* env) {
    static char stack[65536] __attribute__((aligned(16)));
    return clone(helper, stack + sizeof(stack), SIGCHLD, env);
}

static __attribute__((noinline)) pid_t fork_with_flags(void) {
    jmp_buf env;
    if (setjmp(env) == 0) {
        return clone_and_longjmp(&env);
    }
    return 0;
}

int main(int argc, char** argv) {
    int rounds = argc > 1 ? atoi(argv[1]) : 50;
    static volatile long mine = 1;
    pthread_t t[2];
    for (long k = 0; k < 2; k++) pthread_create(&t[k], NULL, worker, (void*)(k + 1));
    int crashed = 0, leaked = 0;
    for (int r = 0; r < rounds; r++) {
        mine = 1;
        pid_t pid = fork_with_flags();
        if (pid == 0) {
            // the child: its own copy, written and read back
            mine = 2;
            shared[1] = -1;
            _exit(mine == 2 ? 0 : 3);
        }
        if (pid < 0) {
            perror("clone");
            return 2;
        }
        int st;
        waitpid(pid, &st, 0);
        if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) crashed++;
        if (mine != 1) leaked++;
    }
    stop = 1;
    for (int k = 0; k < 2; k++) pthread_join(t[k], NULL);
    printf("forkstack: %d rounds, %d children crashed or failed, %d writes reached the parent\n", rounds, crashed,
           leaked);
    return crashed || leaked ? 1 : 0;
}
