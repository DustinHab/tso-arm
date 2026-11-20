// Whether ordered accesses (ldapr, or ldar without FEAT_LRCPC, and stlr) may be unaligned on this machine: with
// FEAT_LSE2 they may, within 16 bytes, if the kernel sets SCTLR_EL1.nAA; otherwise they fault (SIGBUS). Prints
// "within16 yes|no" and "crossing16 yes|no"; exit status 0 when ordered accesses within 16 bytes need no alignment.
//   clang -O1 [-march=armv8.2-a+rcpc] -o probe aot/unaligned_probe.c && ./probe
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static sigjmp_buf env;
static void on_fault(int sig)
{
    (void)sig;
    siglongjmp(env, 1);
}

#ifdef __ARM_FEATURE_RCPC
#define LOAD32 "ldapr %w0, [%1]"
#define LOAD64 "ldapr %x0, [%1]"
#else
#define LOAD32 "ldar %w0, [%1]"
#define LOAD64 "ldar %x0, [%1]"
#endif

// one ordered load of 4 and of 8 bytes and one ordered store of 4 and of 8 bytes at p: 1 if none faulted
static int try_at(volatile uint8_t *p)
{
    if (sigsetjmp(env, 1))
        return 0;
    uint64_t v;
    __asm__ volatile(LOAD32 : "=r"(v) : "r"(p) : "memory");
    __asm__ volatile(LOAD64 : "=r"(v) : "r"(p) : "memory");
    __asm__ volatile("stlr %w0, [%1]" ::"r"(v), "r"(p) : "memory");
    __asm__ volatile("stlr %x0, [%1]" ::"r"(v), "r"(p) : "memory");
    return 1;
}

int main(void)
{
    static _Alignas(64) volatile uint8_t buf[64];
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_fault;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGBUS, &sa, 0);
    sigaction(SIGSEGV, &sa, 0);
    // within one 16-byte block: 8 bytes at offset 3 (3..10); across two: 8 bytes at offset 12 (12..19)
    int within = try_at(buf + 3), crossing = try_at(buf + 12);
    printf("within16 %s\ncrossing16 %s\n", within ? "yes" : "no", crossing ? "yes" : "no");
    return within ? 0 : 1;
}
