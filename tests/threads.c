// Creates threads one after another while the earlier ones keep running, then joins them.
// Prints the result of every pthread_create; checks that each thread saw its own argument.
//   threads [count]
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static volatile int go;
static long seen[64];

static void *worker(void *arg) {
    long id = (long)arg;
    char *p = malloc(1 << 20);
    memset(p, (int)id, 1 << 20);
    while (!__atomic_load_n(&go, __ATOMIC_ACQUIRE))
        ;
    seen[id] = id + p[12345];
    free(p);
    return NULL;
}

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 8;
    if (n > 64)
        n = 64;
    pthread_t t[64];
    int made = 0;
    for (int i = 0; i < n; i++) {
        int rc = pthread_create(&t[i], NULL, worker, (void *)(long)i);
        printf("thread %d: %s\n", i, rc ? strerror(rc) : "ok");
        if (rc)
            break;
        made++;
    }
    __atomic_store_n(&go, 1, __ATOMIC_RELEASE);
    int bad = 0;
    for (int i = 0; i < made; i++) {
        pthread_join(t[i], NULL);
        bad += seen[i] != 2 * i;
    }
    printf("threads %d, wrong %d\n", made, bad);
    return bad != 0 || made != n;
}
