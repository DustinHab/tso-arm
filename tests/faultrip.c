// What WebAssembly's trap handler in V8 (and Java's implicit null checks) does with a fault: a load from a page
// without access at a known instruction; the SIGSEGV handler checks that the context names that instruction and
// the address, sets the instruction pointer to a landing pad and a register to the faulting instruction, and
// returns there. Many times, from a loop, so that the load runs in translated code of every kind.
//   faultrip [ROUNDS]     prints one line; exit status 1 if a fault named another instruction or did not land
#define _GNU_SOURCE
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <ucontext.h>

extern char faultrip_load[], faultrip_pad[];
static uint8_t* guard;
static volatile long wrong_rip, wrong_addr, landed;

static void handler(int sig, siginfo_t* info, void* ctx) {
    ucontext_t* uc = ctx;
    (void)sig;
    if ((uintptr_t)uc->uc_mcontext.gregs[REG_RIP] != (uintptr_t)faultrip_load)
        wrong_rip++;
    if ((uint8_t*)info->si_addr != guard + 0x40)
        wrong_addr++;
    uc->uc_mcontext.gregs[REG_R10] = uc->uc_mcontext.gregs[REG_RIP];
    uc->uc_mcontext.gregs[REG_RIP] = (greg_t)(uintptr_t)faultrip_pad;
}

// returns 1 if it came back through the landing pad with r10 naming the load (once in the program: the labels)
__attribute__((noinline, noclone)) static long probe(uint8_t* p) {
    long r;
    __asm__ volatile("xor %%r10d, %%r10d\n"
                     "mov $7, %%eax\n"
                     ".globl faultrip_load\n"
                     "faultrip_load:\n"
                     "mov (%1), %%eax\n"
                     "jmp 1f\n"
                     ".globl faultrip_pad\n"
                     "faultrip_pad:\n"
                     "lea faultrip_load(%%rip), %%rax\n"
                     "cmp %%rax, %%r10\n"
                     "sete %%al\n"
                     "movzbl %%al, %%eax\n"
                     "1:\n"
                     : "=&a"(r)
                     : "r"(p)
                     : "r10", "memory", "cc");
    return r;
}

int main(int argc, char** argv) {
    const long rounds = argc > 1 ? atol(argv[1]) : 2000;
    guard = mmap(NULL, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigaction(SIGSEGV, &sa, NULL);
    long good = 0;
    for (long i = 0; i < rounds; i++)
        good += probe(guard + 0x40) == 1;
    landed = good;
    const int ok = good == rounds && !wrong_rip && !wrong_addr;
    printf("faultrip: %ld faults, %ld landed, %ld named another instruction, %ld another address%s\n", rounds, landed, wrong_rip,
           wrong_addr, ok ? "" : " (wrong)");
    return !ok;
}
