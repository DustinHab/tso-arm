// The program's own signal handlers: raised, with siginfo, from a timer during a system call, sent with kill, and a
// child's exit while waiting in sigsuspend. FEX runs a handler on a dispatcher loop below the host state it saved
// at the signal; a loop that reset its stack pointer above that state overwrote it, and every handler crashed.
// Last line "signals: ... all handled"; exit status 1 if one was not.
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t hits;

static void plain(int sig)
{
    (void)sig;
    hits++;
}

static void info(int sig, siginfo_t *si, void *uc)
{
    (void)uc;
    if (sig == SIGUSR1 && si->si_signo == SIGUSR1)
        hits++;
}

static int handled(const char *what, int before)
{
    if (hits == before + 1)
        return 1;
    printf("FAIL: %s: %d handler calls\n", what, hits - before);
    return 0;
}

int main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct sigaction sa;
    int ok = 1, h;

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = plain;
    sigaction(SIGUSR2, &sa, NULL);
    h = hits;
    raise(SIGUSR2);
    ok &= handled("raise", h);

    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = info;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGUSR1, &sa, NULL);
    h = hits;
    raise(SIGUSR1);
    ok &= handled("siginfo", h);

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = plain;
    sigaction(SIGALRM, &sa, NULL);
    h = hits;
    alarm(1);
    pause();
    ok &= handled("timer during pause", h);

    h = hits;
    kill(getpid(), SIGUSR2);
    ok &= handled("kill", h);

    sigaction(SIGCHLD, &sa, NULL);
    sigset_t block, old;
    sigemptyset(&block);
    sigaddset(&block, SIGCHLD);
    sigprocmask(SIG_BLOCK, &block, &old);
    h = hits;
    pid_t p = fork();
    if (p == 0)
        _exit(0);
    while (hits == h)
        sigsuspend(&old);
    sigprocmask(SIG_SETMASK, &old, NULL);
    waitpid(p, NULL, 0);
    ok &= handled("child's exit during sigsuspend", h);

    if (ok)
        printf("signals: raised, with siginfo, timer during pause, kill, child's exit during sigsuspend: all handled\n");
    return !ok;
}
