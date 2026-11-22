// Asynchronous preemption as Go's runtime does it: one thread runs a tight loop of arithmetic whose carry goes from
// one instruction to the next; another sends it SIGURG every few microseconds. The handler makes the interrupted
// thread call a trampoline at the interrupted address (it pushes that address as the return address, past the red
// zone), which saves the flags and two registers, changes them, restores them and returns there. That is right only
// if the state the handler saw is the one of an instruction start: FEX delivered such a signal at once, with the
// address of the start of the instruction whose translation it interrupted and the registers as the translation had
// them by then, and the loop computed something else or crashed (notes section 54).
//   preempt [ITERATIONS] [ROUNDS] [where]   exit status 1 if a round's result differs from the one without signals,
//                                           2 on a crash; with "where" the places in the loop the handler found
#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

void Mix(uint64_t Iterations, uint64_t* Out);
void MixEnd(void);
void Trampoline(void);
long Preempts;

__asm__(".text\n"
        ".globl Mix\n"
        ".type Mix, @function\n"
        "Mix:\n"
        "  push %rbx\n"
        "  push %r12\n"
        "  mov %rdi, %r12\n"
        "  movabs $0x123456789, %rax\n"
        "  mov $0x9876543, %rbx\n"
        "  mov $0x5555, %rcx\n"
        "  mov $0x31337, %rdx\n"
        "  mov $0x10001, %r8\n"
        "1:\n"
        "  add %rbx, %rax\n"
        "  adc %rdx, %rcx\n"
        "  rol $7, %rax\n"
        "  xor %rcx, %rbx\n"
        "  imul %r8, %rdx\n"
        "  lea 1(%rdx,%rax), %r8\n"
        "  sbb %rax, %rbx\n"
        "  dec %r12\n"
        "  jnz 1b\n"
        "  mov %rax, (%rsi)\n"
        "  mov %rbx, 8(%rsi)\n"
        "  mov %rcx, 16(%rsi)\n"
        "  mov %rdx, 24(%rsi)\n"
        "  pop %r12\n"
        "  pop %rbx\n"
        "  ret\n"
        ".globl MixEnd\n"
        "MixEnd:\n"
        ".size Mix, .-Mix\n"
        ".globl Trampoline\n"
        "Trampoline:\n"
        "  pushfq\n"
        "  push %rax\n"
        "  push %rcx\n"
        "  lock incq Preempts(%rip)\n"
        "  mov $-1, %rax\n"
        "  mov $-1, %rcx\n"
        "  add %rax, %rcx\n"
        "  pop %rcx\n"
        "  pop %rax\n"
        "  popfq\n"
        "  ret $128\n");

static atomic_int Stop;
static pthread_t Worker;
static atomic_long Outside;
// where in Mix the handler found the thread: a count per byte offset
static atomic_long At[256];
static int CountOnly; // "count": the handler only counts, nothing is redirected

static void Crash(int Signal, siginfo_t* Info, void* Context) {
  ucontext_t* UC = Context;
  greg_t* G = UC->uc_mcontext.gregs;
  char B[256];
  const int N = snprintf(B, sizeof(B), "preempt: signal %d at %#llx (Mix+%#llx), address %p, rsp %#llx, rax %#llx, r12 %#llx\n", Signal,
                         (unsigned long long)G[REG_RIP], (unsigned long long)(G[REG_RIP] - (uintptr_t)Mix), Info->si_addr,
                         (unsigned long long)G[REG_RSP], (unsigned long long)G[REG_RAX], (unsigned long long)G[REG_R12]);
  if (write(1, B, N) < 0) {
    _exit(3);
  }
  _exit(2);
}

static void Handler(int Signal, siginfo_t* Info, void* Context) {
  (void)Signal;
  (void)Info;
  ucontext_t* UC = Context;
  greg_t* G = UC->uc_mcontext.gregs;
  const uintptr_t RIP = G[REG_RIP];
  if (RIP < (uintptr_t)Mix || RIP >= (uintptr_t)MixEnd) {
    atomic_fetch_add_explicit(&Outside, 1, memory_order_relaxed);
    return;
  }
  atomic_fetch_add_explicit(&At[(RIP - (uintptr_t)Mix) & 255], 1, memory_order_relaxed);
  if (CountOnly) {
    return;
  }
  // as asyncPreempt: a call from the interrupted instruction, past the red zone
  uint64_t* SP = (uint64_t*)(G[REG_RSP] - 128 - 8);
  *SP = RIP;
  G[REG_RSP] = (greg_t)SP;
  G[REG_RIP] = (greg_t)(uintptr_t)Trampoline;
}

static void* Sender(void* Arg) {
  (void)Arg;
  const struct timespec Pause = {0, 5000};
  while (!atomic_load_explicit(&Stop, memory_order_relaxed)) {
    pthread_kill(Worker, SIGURG);
    nanosleep(&Pause, NULL);
  }
  return NULL;
}

int main(int argc, char** argv) {
  const uint64_t Iterations = argc > 1 ? strtoull(argv[1], NULL, 10) : 20000000;
  const int Rounds = argc > 2 ? atoi(argv[2]) : 5;
  CountOnly = argc > 3 && !strcmp(argv[3], "count");
  uint64_t Want[4], Got[4];
  Mix(Iterations, Want);

  // the handler on a stack of its own, as Go's: it writes below the interrupted stack pointer, where a frame on the
  // same stack would lie
  static char AltStack[64 * 1024];
  stack_t SS = {.ss_sp = AltStack, .ss_flags = 0, .ss_size = sizeof(AltStack)};
  sigaltstack(&SS, NULL);
  struct sigaction SA;
  memset(&SA, 0, sizeof(SA));
  SA.sa_sigaction = Handler;
  SA.sa_flags = SA_SIGINFO | SA_RESTART | SA_ONSTACK;
  sigaction(SIGURG, &SA, NULL);
  struct sigaction SC;
  memset(&SC, 0, sizeof(SC));
  SC.sa_sigaction = Crash;
  SC.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigaction(SIGSEGV, &SC, NULL);
  sigaction(SIGILL, &SC, NULL);
  sigaction(SIGBUS, &SC, NULL);
  Worker = pthread_self();
  pthread_t S;
  pthread_create(&S, NULL, Sender, NULL);
  int Wrong = 0;
  for (int R = 0; R < Rounds; ++R) {
    Mix(Iterations, Got);
    if (memcmp(Got, Want, sizeof(Want))) {
      ++Wrong;
    }
  }
  atomic_store(&Stop, 1);
  pthread_join(S, NULL);
  if (argc > 3) {
    printf("preempt: the handler found the thread at");
    for (int i = 0; i < 256; ++i) {
      if (At[i]) {
        printf(" Mix+%#x (%ld)", i, At[i]);
      }
    }
    printf("\n");
  }
  printf("preempt: %d rounds of %llu iterations, %ld calls from the handler (%ld outside the loop), %d wrong%s\n", Rounds,
         (unsigned long long)Iterations, Preempts, atomic_load(&Outside), Wrong, Wrong ? "" : ", all right");
  return Wrong != 0 || (Preempts == 0 && !CountOnly);
}
