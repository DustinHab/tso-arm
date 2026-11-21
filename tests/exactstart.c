// A thread sent back to the dispatcher at an instruction start must find the guest registers as they are there.
// The function below is CPython's _PyObject_GC_UNTRACK as GCC compiles it (python3.12 of Ubuntu 24.04): it unlinks a
// node from a doubly linked list. Its store to the previous node meets a page another thread writes; the second
// time, the store's block is translated anew and the thread leaves the old one at its next instruction start
// (`mov %rax, 0x8(%rcx)`). FEX had already set rcx to 0 there, for the `xor %ecx, %ecx` after it (a constant shared
// within the block, put into rcx's register where it was first made): the store, repeated, wrote to address 8
// (notes section 51).
//   exactstart [ROUNDS]   exit status 1 if a list came out wrong
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

struct Node {
  uint64_t Next; // the header, as CPython's PyGC_Head: the next node's header
  uint64_t Prev; // the previous node's header, two flag bits below
  uint64_t Object[2];
};

void Untrack(uint64_t* Object);
// On a page of code of its own: FEX throws translations away by page, and the escalations of the code around it
// would have it translated anew before its old translation ran a second time
__asm__(".text\n"
        ".p2align 12\n"
        ".globl Untrack\n"
        ".type Untrack, @function\n"
        "Untrack:\n"
        "  push %rbp\n"
        "  mov %rsp, %rbp\n"
        "  push %rbx\n"
        "  mov %rdi, %rbx\n"
        "  push %rdx\n"
        "  mov -0x10(%rdi), %rcx\n"
        "  mov -0x8(%rdi), %rdx\n"
        "  mov 0x8(%rcx), %rax\n"
        "  and $0xfffffffffffffffc, %rdx\n"
        "  and $0x3, %eax\n"
        "  mov %rcx, (%rdx)\n"
        "  or %rdx, %rax\n"
        "  mov %rax, 0x8(%rcx)\n"
        "  xor %ecx, %ecx\n"
        "  andq $0x1, -0x8(%rdi)\n"
        "  mov %rcx, -0x10(%rdi)\n"
        "  pop %rax\n"
        "  pop %rbx\n"
        "  pop %rbp\n"
        "  ret\n"
        ".size Untrack, .-Untrack\n"
        ".p2align 12\n");

static atomic_int Stop;
static struct Node* First; // on the page the other thread writes

static void* Writer(void* Arg) {
  (void)Arg;
  volatile uint64_t* Field = &First->Object[1];
  while (!atomic_load_explicit(&Stop, memory_order_relaxed)) {
    *Field += 1;
  }
  return NULL;
}

int main(int argc, char** argv) {
  const int Rounds = argc > 1 ? atoi(argv[1]) : 1000;
  // The first node on a page of its own, the two others on another
  char* Pages = mmap(NULL, 2 * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (Pages == MAP_FAILED) {
    perror("mmap");
    return 1;
  }
  First = (struct Node*)Pages;
  struct Node* Middle = (struct Node*)(Pages + 4096);
  struct Node* Last = Middle + 1;
  pthread_t T;
  pthread_create(&T, NULL, Writer, NULL);
  for (volatile int i = 0; i < 2000000; ++i) {
  }
  int Wrong = 0;
  for (int R = 0; R < Rounds; ++R) {
    First->Next = (uint64_t)Middle;
    Middle->Prev = (uint64_t)First | 2;
    Middle->Next = (uint64_t)Last;
    Last->Prev = (uint64_t)Middle | 1;
    Untrack(Middle->Object);
    if (First->Next != (uint64_t)Last || Last->Prev != ((uint64_t)First | 1) || Middle->Next != 0 || Middle->Prev != 0) {
      ++Wrong;
    }
  }
  atomic_store(&Stop, 1);
  pthread_join(T, NULL);
  printf("exactstart: %d rounds, %d wrong\n", Rounds, Wrong);
  return Wrong != 0;
}
