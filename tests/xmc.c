// Code patched by one thread while another runs it, as a JIT patches a method's entry (HotSpot): the first two bytes
// of the function change with one atomic 2-byte store, between `mov $1, %eax` (b8 01, its other bytes and the
// `ret` after it stay) and a jump over them to `mov $2, %eax; ret` (eb 04). On x86 the running thread sees the old
// two bytes or the new ones; a decoder that reads them one at a time may see b8 04 (`mov $4, %eax`) or eb 01 (a
// jump into the middle). FEX protected a page against writes only after it had translated code from it, so a store
// while it decoded went unseen and such a translation stayed valid (notes section 52).
//   xmc [PATCHES]   calls the function until PATCHES patches are done (default 2000); exit status 1 if a call
//                   returned anything but 1 or 2, 2 if the calls did not end within a minute
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static volatile uint8_t* Code;
static atomic_int Stop;
static atomic_long Patches;

static void* Writer(void* Arg) {
  (void)Arg;
  for (long i = 0; !atomic_load_explicit(&Stop, memory_order_relaxed); ++i) {
    const uint16_t Start = (i & 1) ? 0x04eb : 0x01b8; // eb 04: jmp +4; b8 01: mov $1, %eax
    __atomic_store_n((volatile uint16_t*)Code, Start, __ATOMIC_RELEASE);
    atomic_fetch_add_explicit(&Patches, 1, memory_order_relaxed);
    for (volatile int k = 0; k < 300; ++k) {
    }
  }
  return NULL;
}

static void Late(int Signal) {
  (void)Signal;
  static const char M[] = "xmc: the calls did not end within a minute\n";
  if (write(1, M, sizeof(M) - 1) < 0) {
    _exit(3);
  }
  _exit(2);
}

int main(int argc, char** argv) {
  const long Wanted = argc > 1 ? atol(argv[1]) : 2000;
  void* Page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (Page == MAP_FAILED) {
    perror("mmap");
    return 1;
  }
  // mov $1, %eax; ret; mov $2, %eax; ret
  static const uint8_t Initial[] = {0xb8, 0x01, 0x00, 0x00, 0x00, 0xc3, 0xb8, 0x02, 0x00, 0x00, 0x00, 0xc3};
  memcpy(Page, Initial, sizeof(Initial));
  Code = Page;
  int (*Function)(void) = (int (*)(void))Page;
  signal(SIGALRM, Late);
  alarm(60);
  pthread_t T;
  pthread_create(&T, NULL, Writer, NULL);
  long Ones = 0, Twos = 0, Wrong = 0, Calls = 0;
  int Seen = 0;
  for (; atomic_load_explicit(&Patches, memory_order_relaxed) < Wanted; ++Calls) {
    const int R = Function();
    if (R == 1) {
      ++Ones;
    } else if (R == 2) {
      ++Twos;
    } else {
      if (!Wrong) {
        Seen = R;
      }
      ++Wrong;
    }
  }
  atomic_store(&Stop, 1);
  pthread_join(T, NULL);
  alarm(0);
  printf("xmc: %ld calls during %ld patches, %ld returned 1, %ld returned 2, %ld something else%s\n", Calls,
         atomic_load(&Patches), Ones, Twos, Wrong, Wrong ? "" : ", all right");
  if (Wrong) {
    printf("xmc: the first was %#x\n", Seen);
  }
  return Wrong != 0;
}
