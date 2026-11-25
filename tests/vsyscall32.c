// A 32-bit program's system call through the kernel's entry point in AT_SYSINFO, as the i386 C library makes them
// (glibc 2.35 and older for every call: Ubuntu 22.04's, Debian 11's, older games' runtimes). Where FEX has no VDSO
// it makes a page of its own for that entry, which its tracking kept as not executable: every such program crashed
// at its first system call.
//   vsyscall32     prints "vsyscall32: ...: all right" or what went wrong, exit status 1 then (i386 only)
#include <stdio.h>
#include <sys/auxv.h>
#include <unistd.h>

int main(void) {
    const unsigned long entry = getauxval(AT_SYSINFO);
    if (!entry) {
        printf("vsyscall32: no AT_SYSINFO\n");
        return 1;
    }
    int pid = 0;
    // getpid (20 on i386) through the entry: eax holds the number, the result comes back in eax
    __asm__ volatile("call *%1" : "=a"(pid) : "r"(entry), "0"(20) : "memory", "ecx", "edx");
    if (pid != getpid()) {
        printf("vsyscall32: getpid through AT_SYSINFO gave %d, not %d\n", pid, (int)getpid());
        return 1;
    }
    printf("vsyscall32: a system call through AT_SYSINFO (%#lx): all right\n", entry);
    return 0;
}
