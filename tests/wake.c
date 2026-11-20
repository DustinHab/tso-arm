// Code translated while the views slept (one thread) must not run on once a second thread exists (notes section 46).
// The ring buffer of tests/spsc.c, its producer and consumer as functions that first run in the main thread alone
// (translated asleep, every access plain), then in two threads: under x86 order every message arrives right; a
// translation left over from the sleep would let the consumer see a slot published before its contents.
//   wake [MESSAGES]     exit status 1 and the count of bad messages if any arrived wrong
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define SLOTS 64

struct slot {
    uint64_t value, check;
};

static struct slot ring[SLOTS];
static volatile uint64_t head, tail; // head: written by the producer only, tail: by the consumer only

static uint64_t check_of(uint64_t v) {
    return v * 0x9E3779B97F4A7C15ULL ^ 0x5bd1e995;
}

__attribute__((noinline)) static void produce(uint64_t from, uint64_t to) {
    for (uint64_t i = from; i <= to; i++) {
        while (head - tail == SLOTS)
            ;
        struct slot *s = (struct slot *)&ring[head % SLOTS];
        *(volatile uint64_t *)&s->value = i;
        *(volatile uint64_t *)&s->check = check_of(i);
        head = head + 1; // publishes the slot: x86 keeps this store after the two above
    }
}

__attribute__((noinline)) static long consume(uint64_t from, uint64_t to) {
    long bad = 0;
    for (uint64_t expect = from; expect <= to; expect++) {
        while (tail == head)
            ;
        struct slot *s = (struct slot *)&ring[tail % SLOTS];
        uint64_t v = *(volatile uint64_t *)&s->value; // x86 keeps these loads after the load of head
        uint64_t c = *(volatile uint64_t *)&s->check;
        if (v != expect || c != check_of(v))
            bad++;
        tail = tail + 1; // frees the slot: x86 keeps this store after the loads above
    }
    return bad;
}

static uint64_t base, messages = 20000000;
static long bad;

static void *producer(void *arg) {
    (void)arg;
    produce(base + 1, base + messages);
    return NULL;
}

static void *consumer(void *arg) {
    (void)arg;
    bad += consume(base + 1, base + messages);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc > 1)
        messages = strtoull(argv[1], NULL, 10);
    // One thread: producer and consumer translated now, while the views sleep
    for (uint64_t k = 0; k < 2000; k++) {
        produce(k * 32 + 1, k * 32 + 32);
        bad += consume(k * 32 + 1, k * 32 + 32);
    }
    base = 2000 * 32;
    // Two threads: the views wake, and what was translated so far goes
    pthread_t p, c;
    pthread_create(&c, NULL, consumer, NULL);
    pthread_create(&p, NULL, producer, NULL);
    pthread_join(p, NULL);
    pthread_join(c, NULL);
    printf("wake: %llu messages after a start with one thread, %ld arrived wrong\n", (unsigned long long)messages, bad);
    return bad != 0;
}
