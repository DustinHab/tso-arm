// Segment register loads: a program sets DS and ES to the user data selector and reads them back, with a second
// thread running so that the page protocol's views are awake. FEX reads a selector's base from its own descriptor
// table, which is not guest memory; under the views that read went through them and faulted (Wine's ntdll does
// "mov %eax, %ds" in its signal handler, and every Windows program stopped with "nested exception on signal stack").
//   segload        prints "segload: ... all right", exit status 1 if a value is wrong
#include <pthread.h>
#include <stdio.h>

static volatile int stop;
static void *spin(void *arg) {
    (void)arg;
    while (!stop) __asm__ volatile("pause");
    return NULL;
}

int main(void) {
    pthread_t t;
    pthread_create(&t, NULL, spin, NULL);
    unsigned short ds, es, ss, after_ds = 0, after_es = 0;
    __asm__ volatile("mov %%ds, %0; mov %%es, %1; mov %%ss, %2" : "=r"(ds), "=r"(es), "=r"(ss));
    int bad = 0;
    for (int i = 0; i < 1000; i++) {
        unsigned sel = ss;  // the user data selector (0x2b on Linux x86-64)
        __asm__ volatile("mov %0, %%ds; mov %0, %%es" : : "r"(sel) : "memory");
        __asm__ volatile("mov %%ds, %0; mov %%es, %1" : "=r"(after_ds), "=r"(after_es));
        bad += after_ds != ss || after_es != ss;
        __asm__ volatile("mov %0, %%ds; mov %1, %%es" : : "r"((unsigned)ds), "r"((unsigned)es) : "memory");
    }
    stop = 1;
    pthread_join(t, NULL);
    printf("segload: DS and ES loaded with the selector of SS (%#x) 1000 times and read back: %s\n", ss,
           bad ? "WRONG" : "all right");
    return bad != 0;
}
