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

## 3. What FEX does today (FEX be66e03, 2026-11-16)

Defaults: `TSOEnabled` true, `VectorTSOEnabled` false, `MemcpySetTSOEnabled` false, `HalfBarrierTSOEnabled` true.
In addition, accesses whose base or index register is `rsp` are never ordered (`IsNonTSOReg`). So by default FEX
orders scalar accesses not based on `rsp`, and nothing else. This is a heuristic: it is not TSO.

It is less unsound than it looks. Leaving data accesses plain is harmless as long as the accesses that synchronise
are ordered: an `stlr` flag store orders all earlier plain stores before it, an `ldapr` flag load all later plain
loads after it. FEX's default breaks when the synchronising access itself is one of the unordered kinds: a flag in
the writer's stack frame written through `rsp`, a flag or lock word written by a vector store, a `rep stos` that
writes the flag. `litmus/mp.c` gets variants for exactly these next.

FEX already has the per-instruction override needed for experiments: `ForceTSO` (used for Windows volatile
metadata) can force an instruction ordered or plain.

## 4. Litmus tests on the A76 (`litmus/mp.c`, 2 million iterations, threads on cores 2 and 3)

Message passing with the data written by `mov`, `movdqu`, `rep stosq`, or `mov` through `rsp`; load buffering; store
buffering. Natively on x86 (WSL): no forbidden outcome, store buffering seen in 8.5 % of iterations.

| FEX setting | mp | vec | rep | stack | lb | sb (allowed) |
|---|---|---|---|---|---|---|
| default | 0 | 0 | 0 | 0 | 0 | 1436 |
| TSO off | 0 | 0 | 0 | **21304** | 0 | 11 |
| full (vector + memcpy) | 0 | 0 | 0 | 0 | 0 | 1195 |

With TSO off the stack variant fails 21304 times: the A76 does reorder. The other message-passing variants did not
fail even with TSO off, so this harness is not yet sensitive enough to show load-load reordering in general; the
reader should pull the data line into its cache before waiting for the flag. Box64 refuses static binaries
("not an executable file"); it needs dynamic test binaries.

## 5. How much could stay plain (`study/pagestate.c`, DynamoRIO 11.91, x86-64 in WSL)

The client replays the page-state protocol of section 2 on every access, per x86 instruction (if one operand of an
instruction needs ordering, the whole instruction is ordered, as a translator decides it). Workloads are static
non-PIE builds from official sources (`study/build_static.sh`), so the same file runs here and under FEX.

Share of accesses that stay plain under the mechanism ("sticky"), against FEX's default:

| Workload | Threads | Stores: mechanism | Stores: FEX default | Vector stores: mechanism | Loads: mechanism | Page transitions |
|---|---|---|---|---|---|---|
| zstd -T4 -3, 100 MB | 7 | 85.4 % | 38.1 % | 86.2 % | 83.7 % | 47175 |
| pigz -p 4, 100 MB | 6 | 99.95 % | 10.9 % | 93.4 % | 99.4 % | 1166 |
| xz -T4 -6, 8 MB, 2 MB blocks | 5 | 99.80 % | 58.2 % | 99.7 % | 99.9 % | 39685 |

(FEX's default leaves all vector accesses plain, unsoundly; the mechanism's figures are sound.) Raw results in
`study/results/`. The test patterns behave as constructed: private buffers and a table shared read-only stay plain
(above 99.9 %), racy shared counters and a queue between threads are ordered (above 99.5 %).

Page transitions are the cost side: each one is a fault and at least one `mprotect` in the real mechanism. zstd
allocates and frees job buffers that wander between threads, hence 47175 transitions in a run of 0.09 s natively.

## 6. Oracle experiment in FEX (2026-11-17)

`fex/oracle_patch.py` (export in `fex/patches/`): `TSO_PLAIN_LIST=FILE` gives FEX a list of guest instruction
addresses that are translated with plain accesses (`ForceTSO` disabled for them, `rep movs/stos` included); all
other instructions keep the configured setting. The list is the study's set of executed instructions of the binary
that never had to be ordered. This is what the mechanism would produce once every instruction has settled, without
the cost of faults and transitions: an upper bound for it.

Same static binaries as in the study, Pi 5 at a fixed 1.8 GHz, 4 worker threads, wall time, best of 3
(`bench/run_fex.sh`, raw lines `out/fex_runs.txt` on the test machine). In parentheses: overhead over TSO off.

| Workload | TSO off (wrong) | FEX default (not TSO) | full TSO | full TSO + list | default + list |
|---|---|---|---|---|---|
| pigz -p 4, 100 MB | 1.14 s | 1.58 s (+39 %) | 1.64 s (+44 %) | **1.19 s (+4 %)** | 1.15 s (+1 %) |
| xz -T4 -6, 8 MB | 1.34 s | 1.52 s (+13 %) | 1.56 s (+16 %) | **1.38 s (+3 %)** | 1.37 s (+2 %) |
| zstd -T4 -3, 100 MB | 0.58 s | 0.68 s (+17 %) | 0.73 s (+26 %) | **0.67 s (+16 %)** | 0.64 s (+10 %) |

User processor time shows the same (pigz: 4.27 s off, 6.02 s default, 6.30 s full, 4.46 s full + list). zstd and xz
produce the same bytes as natively on x86 in every configuration; pigz's gzip header holds the input file's name and
time, which differ between the machines, and is identical across the configurations (now run with `pigz -n`).

So for pigz and xz nearly all of the cost of full TSO goes away, and full TSO with the list is faster than FEX's
unsound default (pigz 1.19 s against 1.58 s). zstd keeps 16 % because it really shares more: its job buffers move
between threads.

Not yet included: the faults and transitions. With 5 to 11 microseconds per fault on the A76 (`bench/fault_cost.c`)
the transition counts of section 5 would cost little for pigz (1166) but noticeably for xz (39685) and zstd (47175).
Most of those are first touches of new pages, which the real mechanism can avoid by assigning pages to the thread
that maps them; the study now has to model that before the counts mean anything.

## 7. Plan for the mechanism in FEX

From a survey of FEX be66e03 (file references are to that commit):

- FEX maps guest memory 1:1 (`SyscallsSMCTracking.cpp` GuestMmap/Munmap/Mremap/Mprotect pass the guest address to
  the host) and has no memory base register. On a 39-bit host it reserves nothing for itself, and the guest stack
  sits just below 512 GB (`ELFCodeLoader.h`, `StackHint`).
- Plain `LoadMem`/`StoreMem` accept `[base, Xm, extend]`; `LoadMemTSO`/`StoreMemTSO` only `[base]` or `[base, #imm]`
  (`ldapr`, `ldapur` with RCPC2) and emit a `nop` next to each ordered access for backpatching.
- Faults: `SyscallHandler::HandleSegfault` and the SIGBUS path already backpatch JIT code
  (`Utils/ArchHelpers/Arm64.cpp`), `RestoreRIPFromHostPC` maps a host PC to the guest RIP, the SMC path re-runs a
  faulting guest instruction as a single-instruction block, and `ForceTSOInstructions` plus code invalidation give
  a per-instruction retranslation in ordered form.

Layout (39-bit host): the guest gets a window `[0, W)`, W = 16 GB; FEX's guest allocations, stack and brk are placed
inside it. Above it, at fixed multiples of W: one ordered view (or one per thread, depending on section 8) and one
plain view per thread, all aliases of the same shared memory (`MAP_SHARED|MAP_ANONYMOUS`, aliased with
`mremap(old, 0, len, MREMAP_MAYMOVE|MREMAP_FIXED, view)`). The identity mapping stays fully accessible: the kernel
(system call buffers) and FEX's runtime use it.

Code generation:

- plain view: a reserved register (x18 or x24, taken from the allocatable set, filled and spilled like
  `REG_CALLRET_SP`) holds the thread's plain-view base; plain accesses become `ldr x, [xview, xaddr]`, with an extra
  `add` when the guest address has a displacement.
- ordered view: placed at a single-bit offset (2^37), so `orr xtmp, xaddr, #(1 << 37)` forms the address without a
  register; then `ldapr`/`stlr`, or `dmb` and a plain vector access.
- atomics go through the ordered view too, so that they take part in the page protocol.

Fault handling: a SIGSEGV whose address lies in a view is a page-state fault. The handler applies the transition
(mprotect of the affected views). If the access is now allowed it returns and the instruction repeats. If not (a
plain access to a page that is shared and written), it performs this one access itself through the ordered view with
the right ordering, writes the result to the saved registers, steps over the host instruction, and adds the guest
RIP to the forced-TSO set and invalidates its code, so the next translation orders it.

Not covered at first: `fork` (shared mappings would stay shared with the child), file-backed `MAP_SHARED` memory
(treated as shared from the start), 32-bit guests.

Open questions before building it:

1. How much of the time FEX spends on TSO is spent on stores and vector accesses to memory that stays private?
   (Study with a memory tracer on x86, `study/`.)
2. How often do pages change state, and what does a change cost (signal, `mprotect`, TLB shootdown on four cores)?
3. Address space: the test machine has 39-bit virtual addresses (512 GB), so the number of views times the guest
   window must fit into that.
