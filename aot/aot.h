// Interface between FEX and a library of functions translated ahead of time (aot/lift.py). FEX keeps its own copy of
// these structures (Source/Tools/LinuxEmulation/Thunks.cpp); both sides change together.
#pragma once
#include <stdint.h>

struct aot_ctx {
    // guest address a is at view + a: the thread's plain view under the page protocol, 0 without views
    uint8_t *view;
    uint64_t fs_base;
    // runs the guest function at target with the six argument registers, rsp being the stack pointer it would have
    // at its entry (pointing at a return address slot); returns rax
    uint64_t (*guest_call)(struct aot_ctx *c, uint64_t target, uint64_t rsp, const uint64_t *args);
    void *thread;
    // the thread's ordered view (atomics: read/write on shared pages); 0 without views
    uint8_t *oview;
};

// One translated function. FEX checks size and hash against the guest code before it routes calls to fn.
// fn gets the guest stack pointer at the call (rsp: return address, stack arguments above it) and the stack the
// translated code uses for what it keeps on a guest stack (stack: the thread's own, private to it), and returns rax.
struct aot_entry {
    uint64_t rip;
    uint64_t size;
    uint64_t hash; // FNV-1a 64 of the function's bytes
    uint64_t (*fn)(struct aot_ctx *c, uint64_t rsp, uint64_t stack, const uint64_t *args);
    const char *name;
};

extern const struct aot_entry aot_table[];
