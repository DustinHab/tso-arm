// What WebAssembly's trap handler in V8 (and Java's implicit null checks) does with a fault: a load from a page
// without access at a known instruction; the SIGSEGV handler checks that the context names that instruction and
// the address, sets the instruction pointer to a landing pad and a register to the faulting instruction, and
// returns there. Many times, from a loop, so that the load runs in translated code of every kind.
// With v8, as V8's handler in Chromium: on an alternate signal stack (SA_ONSTACK, Chromium's crash handling gives
// every thread one), SIGSEGV unblocked inside the handler and blocked again before it returns, a thread-local flag
// that the code is in WebAssembly, cleared by the handler and set again at the landing pad.
//   faultrip [ROUNDS] [v8]     prints one line; exit status 1 if a fault named another instruction or did not land
#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <ucontext.h>

extern char faultrip_load[], faultrip_pad[];
static uint8_t* guard;
static volatile long wrong_rip, wrong_addr, landed, wrong_stack, not_in_wasm;
static int v8;
static uint8_t* altstack;
#define ALTSTACK_SIZE (64 * 1024)
static __thread volatile int in_wasm;

static void handler(int sig, siginfo_t* info, void* ctx) {
    ucontext_t* uc = ctx;
    (void)sig;
    sigset_t segv, old;
    if (v8) {
        uint8_t* sp = (uint8_t*)__builtin_frame_address(0);
        if (sp < altstack || sp >= altstack + ALTSTACK_SIZE)
            wrong_stack++;
        if (!in_wasm)
            not_in_wasm++;
        in_wasm = 0;
        sigemptyset(&segv);
        sigaddset(&segv, SIGSEGV);
        pthread_sigmask(SIG_UNBLOCK, &segv, &old);
    }
    if ((uintptr_t)uc->uc_mcontext.gregs[REG_RIP] != (uintptr_t)faultrip_load)
        wrong_rip++;
    if ((uint8_t*)info->si_addr != guard + 0x40)
        wrong_addr++;
    uc->uc_mcontext.gregs[REG_R10] = uc->uc_mcontext.gregs[REG_RIP];
    uc->uc_mcontext.gregs[REG_RIP] = (greg_t)(uintptr_t)faultrip_pad;
    if (v8)
        pthread_sigmask(SIG_SETMASK, &old, NULL);
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
    v8 = argc > 2 && !strcmp(argv[2], "v8");
    guard = mmap(NULL, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    if (v8) {
        altstack = mmap(NULL, ALTSTACK_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        stack_t st = {.ss_sp = altstack, .ss_size = ALTSTACK_SIZE, .ss_flags = 0};
        sigaltstack(&st, NULL);
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    }
    sigaction(SIGSEGV, &sa, NULL);
    long good = 0, flag_left = 0;
    for (long i = 0; i < rounds; i++) {
        in_wasm = 1;
        good += probe(guard + 0x40) == 1;
        // V8's landing pad sets the flag again; here the loop does, and counts a flag the handler left set
        flag_left += v8 && in_wasm;
        in_wasm = 0;
    }
    landed = good;
    const int ok = good == rounds && !wrong_rip && !wrong_addr && !wrong_stack && !not_in_wasm && !flag_left;
    printf("faultrip%s: %ld faults, %ld landed, %ld named another instruction, %ld another address", v8 ? " v8" : "", rounds, landed,
           wrong_rip, wrong_addr);
    if (v8)
        printf(", %ld off the alternate stack, %ld without the flag, %ld with it left", wrong_stack, not_in_wasm, flag_left);
    printf("%s\n", ok ? "" : " (wrong)");
    return !ok;
}
