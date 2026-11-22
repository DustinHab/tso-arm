// The address a fault of the program's own reports: SIGSEGV at addresses it never mapped (near zero, as a nil
// pointer's field, and further up) and at a page it made inaccessible, SIGBUS past the end of a file it mapped. With a
// second thread running the page protocol's views are awake, and the access goes through a view at another address:
// FEX passed that one on (0x6000000000 for 0), and Go's runtime, which compares si_addr with the address it
// dereferenced, took its own nil pointer panics for a fatal fault (go test's TestNilDeref, TestPanicOnFault; notes
// section 55).
//   faultaddr      exit status 1 if an si_addr is not the address used
#include <fcntl.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

static sigjmp_buf Back;
static void* volatile Seen;
static volatile int SeenSignal;
static volatile int Stop;

static void Handler(int Signal, siginfo_t* Info, void* Context) {
  (void)Context;
  Seen = Info->si_addr;
  SeenSignal = Signal;
  siglongjmp(Back, 1);
}

static void* Spin(void* Arg) {
  (void)Arg;
  while (!Stop) {
  }
  return NULL;
}

static int Check(const char* What, volatile uint8_t* Address, int Write, int Signal) {
  Seen = NULL;
  SeenSignal = 0;
  if (!sigsetjmp(Back, 1)) {
    if (Write) {
      *Address = 1;
    } else {
      (void)*Address;
    }
    printf("faultaddr: %s at %p did not fault\n", What, (void*)Address);
    return 1;
  }
  if (Seen != (void*)Address || SeenSignal != Signal) {
    printf("faultaddr: %s at %p reported %s at %p\n", What, (void*)Address, SeenSignal == SIGSEGV ? "SIGSEGV" : "SIGBUS", Seen);
    return 1;
  }
  return 0;
}

int main(void) {
  struct sigaction Action = {0};
  Action.sa_sigaction = Handler;
  Action.sa_flags = SA_SIGINFO;
  sigaction(SIGSEGV, &Action, NULL);
  sigaction(SIGBUS, &Action, NULL);
  pthread_t Other;
  pthread_create(&Other, NULL, Spin, NULL);

  const long Page = sysconf(_SC_PAGESIZE);
  int Bad = 0;
  Bad += Check("read near zero", (volatile uint8_t*)16, 0, SIGSEGV);
  Bad += Check("write near zero", (volatile uint8_t*)24, 1, SIGSEGV);
  Bad += Check("read further up", (volatile uint8_t*)0x3b12983e7, 0, SIGSEGV);

  uint8_t* None = mmap(NULL, 2 * Page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  None[0] = 1;
  mprotect(None + Page, Page, PROT_NONE);
  Bad += Check("read of a page made inaccessible", None + Page + 40, 0, SIGSEGV);
  mprotect(None, Page, PROT_READ);
  Bad += Check("write to a page made read-only", None + 8, 1, SIGSEGV);

  char Name[] = "/tmp/faultaddr-XXXXXX";
  const int Fd = mkstemp(Name);
  unlink(Name);
  if (Fd < 0 || write(Fd, "x", 1) != 1) {
    perror("faultaddr: file");
    return 1;
  }
  volatile uint8_t* File = mmap(NULL, 2 * Page, PROT_READ, MAP_SHARED, Fd, 0);
  (void)File[0];
  Bad += Check("read past the end of a mapped file", File + Page + 100, 0, SIGBUS);

  Stop = 1;
  pthread_join(Other, NULL);
  if (Bad) {
    return 1;
  }
  printf("faultaddr: 6 faults, each reported at the address used\n");
  return 0;
}
