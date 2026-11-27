// fork takes a snapshot: the child's memory is the parent's at the moment of the fork, whatever the parent's other
// threads write after it. A thread here counts in two words 64 MB apart, the first, then the second (so in memory the
// second is never ahead of the first), while the main thread forks; each child checks that its second word is not
// ahead of its first. Under the page protocol the child copies the parent's memory after the fork, from memory the
// parent goes on writing: a copy taken while the other thread ran had the second word ahead, and a lock the other
// thread took just after the fork came out taken in the child (Wine's explorer.exe children waited on it forever).
//   forksnap [forks]     prints "forksnap: N forks, W children saw memory from after the fork, D ended otherwise",
//                        exit status 1 if W or D > 0; each such child on standard error (the words it saw, or how it
//                        ended)
#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define SPAN (64u << 20)
static volatile unsigned long *first, *second;
static volatile int stop;

static void *count(void *arg) {
    (void)arg;
    for (unsigned long n = 1; !stop; n++) {
        *first = n;
        *second = n;
    }
    return NULL;
}

int main(int argc, char **argv) {
    int forks = argc > 1 ? atoi(argv[1]) : 100;
    char *m = mmap(NULL, SPAN, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) return 2;
    memset(m, 1, SPAN);  // every page in memory, so that a copy has all of them to copy
    first = (volatile unsigned long *)m;
    second = (volatile unsigned long *)(m + SPAN - 64);
    pthread_t t;
    pthread_create(&t, NULL, count, NULL);
    while (*second == 0) __asm__ volatile("pause");
    int wrong = 0, other = 0;
    for (int i = 0; i < forks; i++) {
        pid_t p = fork();
        if (p == 0) {
            // only write(2) here: the parent had another thread running
            unsigned long f = *first, s = *second;
            if (s > f) {
                char b[160];
                int n = snprintf(b, sizeof(b), "forksnap: fork %d: the child's second word %lu, ahead of its first %lu by %lu\n",
                                 i, s, f, s - f);
                if (n > 0) (void)!write(2, b, (size_t)n);
                _exit(1);
            }
            _exit(0);
        }
        int st;
        if (waitpid(p, &st, 0) != p) {
            fprintf(stderr, "forksnap: fork %d: waitpid failed\n", i);
            other++;
            continue;
        }
        if (WIFEXITED(st) && WEXITSTATUS(st) == 1) {
            wrong++;
        } else if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
            other++;
            if (WIFSIGNALED(st))
                fprintf(stderr, "forksnap: fork %d: the child ended with signal %d (%s)%s\n", i, WTERMSIG(st),
                        strsignal(WTERMSIG(st)), WCOREDUMP(st) ? ", core dumped" : "");
            else
                fprintf(stderr, "forksnap: fork %d: the child ended with exit status %d\n", i, WEXITSTATUS(st));
        }
    }
    stop = 1;
    pthread_join(t, NULL);
    printf("forksnap: %d forks, %d children saw memory from after the fork, %d ended otherwise\n", forks, wrong, other);
    return wrong + other > 0;
}
