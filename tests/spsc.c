// A single-producer single-consumer ring buffer written the way x86 code often is: no barriers and no atomics,
// only volatile, relying on x86's memory order (stores are seen in program order, loads are not reordered). The
// producer writes a slot, then publishes it by moving the head; the consumer reads the head, then the slot. Every
// value carries a check word derived from it; a translator that does not keep x86 order lets the consumer see a
// head before the slot's contents, and the check fails.
//   spsc [MESSAGES]     exit status 1 and the count of bad messages if any arrived wrong
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
static long messages = 20000000;
static long bad;

static uint64_t check_of(uint64_t v) {
    return v * 0x9E3779B97F4A7C15ULL ^ 0x5bd1e995;
}

static void *producer(void *arg) {
    (void)arg;
    for (uint64_t i = 1; i <= (uint64_t)messages; i++) {
        while (head - tail == SLOTS)
            ;
        struct slot *s = (struct slot *)&ring[head % SLOTS];
        *(volatile uint64_t *)&s->value = i;
        *(volatile uint64_t *)&s->check = check_of(i);
        head = head + 1; // publishes the slot: x86 keeps this store after the two above
    }
    return NULL;
}

static void *consumer(void *arg) {
    (void)arg;
    uint64_t expect = 1;
    while (expect <= (uint64_t)messages) {
        while (tail == head)
            ;
        struct slot *s = (struct slot *)&ring[tail % SLOTS];
        uint64_t v = *(volatile uint64_t *)&s->value; // x86 keeps these loads after the load of head
        uint64_t c = *(volatile uint64_t *)&s->check;
        if (v != expect || c != check_of(v))
            bad++;
        tail = tail + 1; // frees the slot: x86 keeps this store after the loads above
        expect++;
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc > 1)
        messages = atol(argv[1]);
    pthread_t p, c;
    pthread_create(&c, NULL, consumer, NULL);
    pthread_create(&p, NULL, producer, NULL);
    pthread_join(p, NULL);
    pthread_join(c, NULL);
    printf("spsc: %ld messages, %ld arrived wrong\n", messages, bad);
    return bad != 0;
}
