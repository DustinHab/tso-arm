# Notes

Measurements, decisions and findings, newest at the end.

## 1. Cost of ordered accesses on the Cortex-A76 (2026-11-17)

`bench/order_cost.c`, core 3 at a fixed 1.8 GHz, processor cycles from the PMU (user mode), best of 7 (part 1) or 3
(part 2) runs. Raw output: `out/order_cost.txt` on the test machine.

L1-resident, cycles per access, ratio to the plain form:

| Access | Plain | `ldapr`/`stlr` | `dmb` form |
|---|---|---|---|
| load | 1.00 | 1.00 (`ldar` 1.00) | 7.00 (`ldr; dmb ishld`) |
| store | 1.50 | 5.00 (x3.3) | 6.00 (`dmb ishst; str`, x4.0) |
| load, add, store to another line | 0.86 | 2.50 (x2.9) | 4.50 (x5.2) |
| store, then load from another line | 0.86 | 2.50 (x2.9); with `ldar` 8.07 (x9.4) | |
| 16-byte vector load | 1.00 | none exists before LRCPC3 | 7.00 (x7.0) |
| 16-byte vector store | 1.00 | none exists before LRCPC3 | 6.00 (x6.0) |
| 16-byte copy (load + store) | 1.01 | | 4.50 (x4.5) |
| dependent load (latency) | 4.00 | 4.00 | |

Buffers of increasing size, cycles per element (copy: 8-byte load + store; gather: sequential index load + random
load; scatter: sequential index load + random store):

| Buffer | Kernel | Plain | `ldapr`/`stlr` | `dmb` form |
|---|---|---|---|---|
| 16 KB | copy | 2.01 | 2.55 (x1.27) | 9.01 (x4.5) |
| 16 KB | gather | 2.30 | 2.66 (x1.16) | 14.14 (x6.2) |
| 16 KB | scatter | 2.00 | 5.33 (x2.7) | 9.00 (x4.5) |
| 256 KB | copy | 2.03 | 2.95 (x1.46) | 9.00 (x4.4) |
| 256 KB | scatter | 2.89 | 6.08 (x2.1) | 9.01 (x3.1) |
| 2 MB | copy | 2.02 | 4.26 (x2.1) | 9.17 (x4.6) |
| 64 MB | copy | 2.27 | 7.61 (x3.4) | 9.32 (x4.1) |
| 64 MB | gather | 24.42 | 24.02 (x0.98) | 25.48 (x1.04) |
| 64 MB | scatter | 41.54 | 41.22 (x0.99) | 42.77 (x1.03) |

Findings:

- Acquire loads are free on the A76: `ldapr` and even `ldar` have the throughput and latency of `ldr`, and random
  loads with `ldapr` still overlap their cache misses (64 MB gather: same time). The core evidently executes later
  loads speculatively and checks ordering afterwards.
- Release stores are not: `stlr` costs 3.3 times a `str` in L1 and 3.4 times in a streaming copy to memory, where the
  plain stores drain in parallel and the release stores one after the other.
- Store followed by load: `stlr` + `ldapr` (RCpc, allowed to pass each other as TSO allows) costs 2.9 times the plain
  pair, `stlr` + `ldar` (RCsc) 9.4 times. Without FEAT_LRCPC a translator would pay the latter.
- Every `dmb` costs 5 to 6 cycles even when nothing is outstanding. Vector accesses have no ordered form on cores
  without FEAT_LRCPC3 and need one `dmb` each: 4.5 to 7 times the plain cost. memcpy, memset and SSE code are hit
  hardest.

So on this core the cost of TSO emulation is the cost of ordered stores and of ordered vector accesses. Loads
can be left as `ldapr`.

## 2. Idea: order only what another thread can see (2026-11-17)

TSO ordering is only observable through memory that at least two threads access and at least one writes. Accesses
to memory that only one thread touches (its stack, thread-local storage, per-thread heap arenas, private buffers) and
loads from memory that nobody writes any more (code, read-only data, tables filled before the threads started) can
be plain, if the translator can tell them apart soundly.

Translators cannot tell at translation time which page an access will hit. The plan is to let the MMU tell:

- Guest memory is mapped several times from the same memory object: one view per thread for plain accesses and one
  for ordered accesses. A thread's plain view has its own private pages read-write, pages shared read-only
  read-only, and everything else inaccessible.
- Translated code starts with plain accesses through the thread's plain view. An access that hits a page it may not
  touch faults. The fault handler moves the page to the new state (private to T, shared read-only, shared
  read-write) and retranslates the faulting instruction in the ordered form, which goes through the ordered view.
- A page leaves the private state through `mprotect` of the owner's view. The TLB invalidation that it implies
  completes only after all accesses through the old mapping are complete, so the owner's earlier plain stores are
  visible before the other thread reaches the page.
- Mixed sequences stay correct: an `stlr` orders all earlier plain accesses before it, an `ldapr` all later ones
  after it, and reordering a private access with any other access cannot be observed by another thread.

Related work, as far as found: Lasagne (PLDI 2022, static translation, removes fences by analysis) and Risotto
(ASPLOS 2023, QEMU, verified mappings and fence merging) reduce barriers by reasoning about the code; Microsoft's
US 11,379,195 uses compiler metadata about volatile accesses (Prism uses it for Windows binaries); Red Hat's
US 11,449,339 elides barriers when the communicating threads share a core; TEMPO (MICRO 2026) proposes hardware.
None detects private memory at run time through page protection.

Open questions before building it:

1. How much of the time FEX spends on TSO is spent on stores and vector accesses to memory that stays private?
   (Study with a memory tracer on x86, `study/`.)
2. How often do pages change state, and what does a change cost (signal, `mprotect`, TLB shootdown on four cores)?
3. Address space: the test machine has 39-bit virtual addresses (512 GB), so the number of views times the guest
   window must fit into that.
