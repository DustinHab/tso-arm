// Descriptors used up: fork, vfork and clone(CLONE_VM | CLONE_VFORK) (posix_spawn's) with 0 to 10 descriptors left,
// and every descriptor of the program still open afterwards. Under the views a fork took two descriptors for a pipe
// before (the parent waited on it for the child's copy of guest memory); with the last free ones gone, FEX's own
// pipe for vfork found none, and the parent closed whatever numbers the pair held: descriptors of the program
// (CPython's test_no_leaking, notes section 51).
//   fdfull [ROUNDS]   exit status 1 if a descriptor was lost or a child did not exit as it should
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

static int Fds[65536], N;
static char Stack[64 * 1024] __attribute__((aligned(16)));

static int Child(void* Arg) {
  _exit((int)(long)Arg);
}

static int Wait(pid_t P, int Want, const char* What, int Left) {
  int S;
  if (P < 0) {
    printf("fdfull: %s with %d left: %s\n", What, Left, strerror(errno));
    return 1;
  }
  if (waitpid(P, &S, 0) != P || !WIFEXITED(S) || WEXITSTATUS(S) != Want) {
    printf("fdfull: %s with %d left: the child did not exit with %d\n", What, Left, Want);
    return 1;
  }
  return 0;
}

static int Lost(const char* What, int Left) {
  for (int i = 0; i < N; ++i) {
    if (fcntl(Fds[i], F_GETFD) == -1) {
      printf("fdfull: %s with %d left closed descriptor %d of the program\n", What, Left, Fds[i]);
      return 1;
    }
  }
  return 0;
}

int main(int argc, char** argv) {
  const int Rounds = argc > 1 ? atoi(argv[1]) : 20;
  // A high limit (GitHub's runners) would take long to fill: 1024, as on most desktops
  struct rlimit Limit;
  if (getrlimit(RLIMIT_NOFILE, &Limit) == 0 && Limit.rlim_cur > 4096) {
    Limit.rlim_cur = 1024;
    setrlimit(RLIMIT_NOFILE, &Limit);
  }
  for (;;) {
    const int F = open("/dev/null", O_RDONLY);
    if (F < 0) {
      if (errno != EMFILE) {
        printf("fdfull: open: %s\n", strerror(errno));
        return 1;
      }
      break;
    }
    if (N == (int)(sizeof(Fds) / sizeof(Fds[0]))) {
      printf("fdfull: no descriptor limit below %d\n", N);
      return 1;
    }
    Fds[N++] = F;
  }
  // The last ones go for a while (the program's highest numbers), and come back with the same numbers
  int Bad = 0;
  for (int Left = 0; Left <= 10 && !Bad; ++Left) {
    for (int i = 0; i < Left; ++i) {
      close(Fds[N - 1 - i]);
    }
    const int Keep = N - Left;
    const int All = N;
    N = Keep;
    for (int R = 0; R < Rounds && !Bad; ++R) {
      pid_t P = fork();
      if (P == 0) {
        _exit(7);
      }
      Bad |= Wait(P, 7, "fork", Left) || Lost("fork", Left);
      P = vfork();
      if (P == 0) {
        _exit(8);
      }
      Bad |= Wait(P, 8, "vfork", Left) || Lost("vfork", Left);
      P = clone(Child, Stack + sizeof(Stack), CLONE_VM | CLONE_VFORK | SIGCHLD, (void*)9L);
      Bad |= Wait(P, 9, "clone(CLONE_VM | CLONE_VFORK)", Left) || Lost("clone(CLONE_VM | CLONE_VFORK)", Left);
    }
    N = All;
    for (int i = 0; i < Left; ++i) {
      if (dup2(Fds[0], Fds[N - 1 - i]) < 0) {
        printf("fdfull: dup2: %s\n", strerror(errno));
        return 1;
      }
    }
  }
  if (Bad) {
    return 1;
  }
  printf("fdfull: %d descriptors, fork, vfork and clone(CLONE_VM | CLONE_VFORK) with 0 to 10 left, %d times each: none lost\n", N,
         Rounds);
  return 0;
}
