// Signals ignored across execve, as nohup leaves SIGHUP: the program ignores SIGHUP and SIGUSR1, executes itself
// again, and the new image must see both ignored (sigaction) and live through a SIGHUP it sends itself. FEX began
// every guest action at SIG_DFL in a new process, so Go's runtime took SIGHUP for not ignored and died of it
// under nohup (notes section 53).
//   sigign      exit status 1 if the new image does not see the signals ignored
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char** argv) {
  if (argc > 1 && !strcmp(argv[1], "child")) {
    struct sigaction Hup, Usr;
    sigaction(SIGHUP, NULL, &Hup);
    sigaction(SIGUSR1, NULL, &Usr);
    if (Hup.sa_handler != SIG_IGN || Usr.sa_handler != SIG_IGN) {
      printf("sigign: after execve SIGHUP is %s, SIGUSR1 is %s\n", Hup.sa_handler == SIG_IGN ? "ignored" : "not ignored",
             Usr.sa_handler == SIG_IGN ? "ignored" : "not ignored");
      return 1;
    }
    raise(SIGHUP);
    printf("sigign: SIGHUP and SIGUSR1 ignored across execve, a SIGHUP lived through\n");
    return 0;
  }
  signal(SIGHUP, SIG_IGN);
  signal(SIGUSR1, SIG_IGN);
  fflush(stdout);
  char* Args[] = {argv[0], (char*)"child", NULL};
  execv(argv[0], Args);
  perror("execv");
  return 1;
}
