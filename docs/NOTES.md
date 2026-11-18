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
| 7zz b 1 -mmt4 -md20 | 36.8 s | 39.0 s (+6 %) | 39.6 s (+8 %) | 39.4 s (+7 %) | 38.7 s (+5 %) |

7-Zip's benchmark is register-bound and loses little to TSO; its list (from the first, cruder study model with only
2 % plain stores) changes nothing. Rerun with `pigz -n`: output identical to x86 in every configuration.

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

## 8. Which design (study, `-mode` and policies, 2026-11-17)

The study client now models what the real mechanism would do: pages of a region belong to the thread that mapped
it (`mmap`, `brk`) without a fault; a new thread's stack belongs to it from its start; `munmap` resets pages. Fault
accounting distinguishes sharing transitions, upgrades (shared read-only to read-write, with one revocation per view
that had the page), lazy mappings of shared read-only pages into plain views, lazy mappings into per-thread ordered
views, and escalations. Three designs:

- **views**: one ordered view per thread (its own private pages accessible in it).
- **global**: one ordered view for all threads, private pages inaccessible in it. An ordered access by the owner
  shares the page. This ratchets: once an instruction is ordered, it shares every private page it touches, which
  escalates the plain instructions using those pages, and so on. Private buffers end with 0.06 % plain stores
  instead of 100 %. Ruled out.
- **check**: one ordered view, plus a software owner check in ordered instructions only: if the page-owner table says
  the page is the thread's own, the access takes the plain view. The MMU stays the guard (a stale check result ends
  in a fault on the plain view), the table only picks the path. No per-thread ordered views, no lazy mappings into
  them, and escalated instructions regain the plain path on private data.

Stores left plain and estimated fault cost (A76 costs from section 4 of `bench/fault_cost.c`; escalation assumed at
30 microseconds), 4 KB pages:

| Workload | views: stores plain | views: events | check: stores plain | check: est. cost | check + brake 30: stores | est. cost |
|---|---|---|---|---|---|---|
| pigz | 89.1 % | 5,200 | 99.97 % | 55 ms | 99.97 % | 55 ms |
| xz | 99.80 % | 6,800 | 99.85 % | 65 ms | 99.85 % | 65 ms |
| zstd | 72.8 % | 107,000 | 90.2 % (78 % in another run) | 435 ms | 71.3 % | 179 ms |

Granularity: 64 KB tracking cuts faults by 10 to 15 but destroys the result through false sharing (xz: 39 % plain
stores). A fixed per-chunk threshold (collapse a 2 MB chunk to shared after N transitions) helps zstd and ruins xz
(41 to 56 %). What separates the programs is the rate: zstd causes about 93 transitions per million accesses, xz
1.8, pigz 0.6. The brake (`-brake R`: a thread that caused more than R transitions per million of its accesses in
its last million collapses the chunks it touches in the next) leaves pigz and xz untouched at R = 30.

zstd stays a loss: its whole TSO overhead in FEX is 0.15 s and the list-based optimum saves 0.06 s, less than the
remaining fault cost. Such programs need a process-wide fallback to full TSO when the fault cost passes a budget.

Decision: **check** design, 4 KB pages, regions owned by their mapping thread, stacks owned by their thread, rate
brake, and a fallback to full TSO.

## 9. Stage 1 in FEX: views without protection (2026-11-17)

`fex/patches/0001-tso-arm-stage-1-*.patch` (on FEX be66e03, branch `tso-views`, built to `~/opt/fex-views`,
switched on with `TSO_VIEWS=1`):

- `FEXCore/include/FEXCore/Core/TSOViews.h`: layout. Guest window [0, 16 GB), ordered view at 2^37, thread slots
  at multiples of 16 GB (14 usable on the 39-bit Pi), so `view address & (2^34 - 1)` is the guest address.
- `CpuStateFrame::TSOViewBase`, loaded into x24 (`REG_VIEW`) in `FillStaticRegs`; x24 leaves the register
  allocator (`x64::RA_Views`) only when views are on.
- IR ops `ViewPlain` (`add dst, addr, x24`) and `ViewOrdered` (`orr dst, addr, #2^37`); the `GuestViewPass` runs
  before register allocation and replaces the address of every guest memory op (29 kinds) with the view address,
  ordered ops and atomics with the ordered one.
- `Push`/`Pop`/`PushTwo`/`PopTwo`/`MemCpy`/`MemSet` return updated addresses; the backend forms the view address
  in a temporary instead (store before the pointer moves, so `push rsp` stores the old value). `rep movs/stos`
  ordering is decided per instruction now (`IsTSOEnabled(GPR) && MemcpySetTSO`).
- `LinuxSyscalls/TSOViews.cpp`: guest mmap/munmap/mprotect/mremap/madvise for 64-bit guests. Private memory becomes
  `MAP_SHARED|MAP_ANONYMOUS`, private file mappings become copies in shared memory, everything is aliased into the
  ordered view and every thread's view with `mremap(old, 0, ...)`. Non-fixed mappings are placed top-down in
  [4 GB, 16 GB); the ELF loader's stack hint and the vDSO hint move into the window. `MADV_DONTNEED`/`MADV_FREE` on
  private guest memory become `MADV_REMOVE` (shared memory keeps its contents otherwise, and glibc's `calloc`
  relies on discarded heap memory reading as zero). Growing a private mapping with `mremap` maps a second object
  behind it, or copies when it has to move (shared memory objects do not grow under a mapping).
- Threads get a slot in `ThreadManager::CreateThread` and give it back on deletion.

Result: every litmus variant and every workload output is correct, with all accesses plain through the threads'
views (TSO off) and with all ordered through the ordered view (full TSO). Cost of the views alone (wall time, best
of 3, 1.8 GHz):

| Workload | TSO off | views, TSO off | full TSO | views, full TSO |
|---|---|---|---|---|
| xz | 1.35 s | 1.53 s (+13 %) | 1.55 s | 1.72 s |
| zstd | 0.60 s | 0.64 s (+7 %) | 0.74 s | 0.77 s |
| pigz | 1.14 s | 1.26 s (+11 %) | 1.68 s | 1.76 s |

That overhead would eat the gain for xz. The kernel has no transparent huge pages, so shared memory does not lose
huge pages here.

Breakdown (switches `TSO_VIEWS_IDENTITY=1`: every thread's view base is 0, `TSO_VIEWS_NOPASS=1`: no rewriting):
shared memory plus the lost register cost 0 to 6 %, the address arithmetic 5 to 9 %, the views themselves (TLB,
aliases) nothing measurable. `perf stat` on xz: 15.9 billion instructions without views, 18.8 billion with
(+18.5 %), cycles +8.7 %.

Reducing the arithmetic, measured on xz and pigz (user-mode cycles over TSO off):

| Step | xz instructions | xz cycles | pigz cycles |
|---|---|---|---|
| one `ViewPlain` per access | 18.85 G | +8.7 % | +9.3 % |
| `LoadMem`/`StoreMem` without offset: flag, `[addr, x24]` | 18.83 G | +8.7 % | +9.3 % |
| share the view address per guest register and block | 18.56 G | +8.6 % | +9.5 % |
| remove the register loads that became dead (they turned into copies) | 18.17 G | +7.2 % | +6.3 % |
| keep the view across `r = r + constant` (offset folded into the immediate) | 18.16 G | +6.8 % | +6.1 % |

The dispatcher loads a guest register anew for every access (`LoadRegister` per use), so sharing has to be keyed by
the register, and the loads it makes dead have to be removed or register allocation turns them into copies. What
remains is mostly one addition per block entry and base register, for instance at the top of every loop iteration.

Open questions before building it:

1. How much of the time FEX spends on TSO is spent on stores and vector accesses to memory that stays private?
   (Study with a memory tracer on x86, `study/`.)
2. How often do pages change state, and what does a change cost (signal, `mprotect`, TLB shootdown on four cores)?
3. Address space: the test machine has 39-bit virtual addresses (512 GB), so the number of views times the guest
   window must fit into that.

## 10. Stage 2 in FEX: the page protocol (2026-11-17)

Same patch, now with protection (default with `TSO_VIEWS=1`; `TSO_VIEWS_STAGE1=1` gives stage 1 back):

- Owner table at 2^36, one byte per guest page: 0 nobody, 1..15 private to the thread in that slot, 0xFE shared
  read-only (bit mask of the plain views that may read), 0xFF shared read-write. Pages of a mapping belong to the
  thread that maps it, a new thread's stack to that thread from its first instruction (`HandOffStack` in
  `CreateNewThread`, glibc writes the thread descriptor at the top before `clone`). A leaving thread's pages go
  back to nobody.
- Protections: a plain view has its own private pages read-write and shared read-only pages it was granted
  read-only; everything else is inaccessible. The ordered view has shared pages accessible, private ones not.
- Faults (`TSOViewMemory::HandleFault`): a plain access to a page nobody owns claims it; to another thread's
  private page shares it (read-only on a read, read-write and escalation on a write); a plain write to a shared
  read-only page upgrades it; a plain access to a shared read-write page escalates. An ordered access (or atomic) to
  a private page shares it.
- Escalation: the guest instruction is translated ordered from now on (`ForceTSO` per RIP, `AddTSOEscalation`).
  Ordered instructions check the owner table: the thread's own private page goes through its plain view (the MMU
  still guards, a stale answer ends in a fault), anything else through the ordered view.

### The faulting access is completed in the handler

The first version repeated the faulting instruction as a single-instruction block, like FEX does for
self-modifying code. That is not exact, and three bugs came from it, each found by a wrong program result:

1. AVX upper halves live in FEX's register cache until the block ends; a repeated `vmovdqu` stored zeros in the
   upper 16 bytes (printf output with 16 NUL bytes).
2. FEX keeps the carry flag inverted inside a block (subtraction convention) and only rectifies it at block
   boundaries; restarting after an `add` flipped the carry and `jb` went the other way (`pthread_create` returned
   `EINVAL` in xz and in `tests/sharedstack.c`).
3. Instructions may change registers before their access faults (the register allocator writes the new stack
   pointer of `leave` into the guest register first).

Now `LinuxSyscalls/TSOAccess.cpp` decodes the faulting host load or store (single and pair, immediate, unscaled,
pre/post-index and register offsets, GPR and SIMD, LDAR/STLR/LDAPR, LDAPUR/STLUR, LD1/ST1 lanes, LD1R), performs it
on the identity mapping between two full barriers, writes back registers and steps over it. The thread continues
in the old translation.

That old translation is stale, and a loop in it faults on every iteration (a stack slot read in a loop: the same
address faulted until the loop guard gave up). So after completing the access the handler writes a trap
(`ldrb wzr, [x24]`, which faults at guest address 0 in every view) over every instruction start of the block that
has a RIP entry (`TSOTrapBlockBoundaries`), and a thread reaching one goes back to the dispatcher with the RIP of
that start, where the code is translated again. For that the state at those starts must be exact:

- every register cache entry is written back before each instruction (MMX, DF and the AVX upper halves, not only
  the static registers),
- the carry flag is put into its ABI form before each RIP entry,
- the register allocator merges nothing across an instruction start (it fused the pop of `leave` with the pop of
  the following `ret` into one `ldp`, so the stack pointer at the start of `ret` was already 8 bytes further).

The trap is written while other threads run the block. A thread that faults on an instruction which is then
replaced reads the trap instead; the handler reads the instruction once and treats a trap there as an exit (the
replaced instruction is the first of its guest instruction and has done nothing yet). FEX's own SIGBUS handler for
unaligned atomics checks for the trap as well. Before this, zstd crashed in the handler (it emulated the trap).

### Tests

- `litmus/run_views.sh 500000`: every variant 0 forbidden outcomes.
- `tests/sharedstack.c`: the main thread's stack is made shared, then library code runs on it (printf, qsort,
  memmove, struct copies, deep recursion) and `pthread_create` is called at 80 stack depths; checksum equal to x86.
- `tests/threads.c`: 12 threads at once, each with its own heap work; correct.
- zstd, pigz, xz: output identical to x86 in every run.

### Speed (wall time, best of 3, 1.8 GHz, `bench/run_views.sh`)

| Workload | TSO off | FEX default | full TSO | protocol |
|---|---|---|---|---|
| xz | 1.37 s | 1.53 s (1.12) | 1.56 s (1.14) | 1.93 s (1.41) |
| zstd | 0.59 s | 0.69 s (1.17) | 0.74 s (1.25) | 1.89 s (3.20) |
| pigz | 1.14 s | 1.60 s (1.40) | 1.65 s (1.45) | 1.77 s (1.55) |

Events per run: pigz 1,700 escalations, 500 shares; zstd 5,500 escalations, 17,000 shares, 12,600 upgrades. Every
escalation completed in the handler, none repeated; about 85 % of them sent a thread back to the dispatcher.

Stage 1 with the exact instruction starts (all plain, no protocol) costs 7 to 9 % user time over TSO off, a few
points more than before.

So the protocol is correct and slower than full TSO. Where the time goes:

1. Escalated accesses cost more than in full TSO: the owner check is seven instructions and a dependent load on top
   of the ordered access.
2. Every escalation recompiles a block, under FEX's code invalidation lock, and the boundary exits start new blocks
   at each escalated RIP; pigz spends less processor time than full TSO (5.6 s against 6.3 s) and still loses on
   wall time.
3. zstd's job buffers move between threads page by page: 30,000 transitions, each with `mprotect` in every view.

Next: an ordered view per thread instead of the owner check (its own private pages and the shared ones accessible;
two views per thread fit 15 threads into 39 bits), escalation per block instead of per instruction, transitions
of whole chunks at a time, and the fallback to full TSO.

## 11. Efficiency against native Arm, and what moved it (2026-11-17)

Reference from here on: the same programs built natively for AArch64 from the same sources and options
(`bench/build_native.sh`), efficiency = native time / time (`bench/efficiency.sh`, table in the README).
FEX without any ordering reaches 83 % (geometric mean of pigz, xz, zstd), FEX with full TSO 66 %. So whatever
the ordering costs, the rest of the translation already leaves 17 %; the protocol can at best close the gap
between 66 % and 83 %.

| Step | pigz | xz | zstd | mean |
|---|---|---|---|---|
| owner check, escalation per instruction (section 10) | 26 % | 51 % | 38 % | 37 % |
| ordered view per thread instead of the owner check, escalation per block | 53 % | 59 % | 42 % | 51 % |
| escalation per instruction, recorded first, recompiled on the second fault | 67 % | 63 % | 41 % | (one round) |
| chunks: a few shared pages of a 2 MB chunk take the owner's other pages along | 68 % | 65 % | 41 % | 57 % |

What each step fixed:

- **Ordered view per thread** (plain view base | 2^38): a thread's own private pages and the shared ones are
  accessible in it, other threads' private pages are not. Ordered accesses cost `add` + `orr` instead of the
  seven-instruction owner check with a table load. The owner check also had a real defect: the rewriting pass
  shared one check per base register across offsets, and `[rdi + 0x60]` could lie on the next page, so the access
  went through the wrong view, faulted, and the block was recompiled, in a loop (memcpy in pigz: 5,424 faults
  for the same three instructions). Rights are taken away at once in every view; rights a transition gives to
  other threads are given by their own first fault.
- **Block escalation** made pigz worse: whole functions went ordered, user time above full TSO. Escalation per
  instruction is the default again (`TSO_VIEWS_ESC=block` for the other).
- **Recorded first, recompiled later**: the first fault of an instruction only records it and completes the access
  in the handler; the old translation goes on (its plain accesses to shared pages keep faulting, so it stays
  correct). The second fault of a recorded instruction recompiles the code once, with everything recorded since.
  pigz: fault handling 0.55 s -> 0.20 s, compilation 0.63 s -> 0.28 s (processor time of all threads).
- **Chunks**: zstd's buffers move between threads page by page. After four pages of a 2 MB chunk changed state,
  the owner's other pages in it follow in one step. zstd faults 44,600 -> 23,000, but its time stays: it now
  spends 0.6 s handling faults and 0.9 s compiling (4,800 escalations), against 0.15 s that full TSO costs it.
- A boundary trap bug on the way: guest instruction offsets in FEX's IR are 32-bit, relative to the block entry,
  and negative for a loop head before the entry; the rewriting pass read them unsigned and treated escalated
  instructions as plain.

Where the remaining time goes, for the next steps:

1. The views cost 7 to 9 % of processor time even with nothing ordered (address arithmetic). For xz that is most of
   the gap: protocol 5.56 s user time, stage 1 without ordering 5.40 s, TSO off 4.95 s.
2. zstd needs the fallback of section 8: past a budget of faults and recompilations, the whole process goes to
   full ordering (every page shared read-write, every instruction ordered).
3. Each recompilation costs 200 to 340 microseconds (whole multiblocks), and FEX takes its code invalidation lock
   exclusively for it.

## 12. Fallback, cheaper view addresses, profiles (2026-11-17)

Efficiency (geometric mean over pigz, xz, zstd; README table): 57 % -> **61 % on a first run, 67 % with the
profile of earlier runs**, against 66 % for FEX's full TSO. FEX's full TSO is not quite TSO either: it leaves
accesses through RSP (and pushes, pops) unordered, treating the stack as private to its thread; the protocol orders
them once a stack page is really shared.

- **Fallback** (section 8's plan): past 5000 faults per second over a window of 1000 faults (after 300 ms), every
  page becomes shared read-write, all translated code is dropped and translated again fully ordered, addressing
  guest memory directly. Old translations still running keep working through the views. zstd 1.20 s -> 1.00 s.
  An earlier fallback (50 to 150 ms) gains zstd little and makes pigz fall back by mistake (its start-up burst).
- **Base cost of the views** (`bench/perf_views.sh`, xz cycles over FEX without ordering): shared memory 0, exact
  instruction starts 1 to 2 %, address arithmetic 6 %. `bench/dump_block.sh` showed where in the hottest block
  (lzma_lzma_optimum_normal, 80 % of xz's cycles): FEX turns `0x2cc(%r15,%r8,4)` into `tmp = r15 + r8 << 2` and an
  immediate; the pass added the view to `tmp`, one more `add` per access. Now the view goes onto the base
  register (shared within the block) and the index is added to it. Pushes and pops are accesses at an offset from
  the stack pointer, so consecutive ones share its view. xz: +8.0 % -> +5.6 % cycles. What remains is one view
  addition per basic block and base register (332 in that block, 118 of them for RSP).
- **Profile**: the escalated ranges and the fallback decision are written at exit
  (`~/.cache/tso-arm/<program>-<hash>.prof`) and loaded before the next run starts. pigz: 1,927 -> 196
  escalations, 1.49 s -> 1.34 s; zstd starts in the fallback. Loading a profile cannot break anything: an
  escalation too many only costs ordering, a missing one is learned again.

zstd stays behind (57 % against FEX's 68 %), in the fallback and without it alike (0.83 to 0.87 s against 0.72 s):

- In the fallback the stack accesses are ordered, and on the A76 `ldapr`/`stlr` take no offset, so every
  `[rsp + x]` needs one more addition: 26 % more instructions than FEX's full TSO, 10 % with stack accesses plain
  (`TSO_VIEWS_FALLBACK_STACK=plain`, unsound, only for measuring).
- Without the fallback, with the profile: 141 instructions of its hottest function
  (ZSTD_compressBlock_doubleFast, 64 % of the cycles) are escalated. They read the input buffer, which the main
  thread fills and a worker then compresses. The buffer is reused, so its pages end up shared read-write for good,
  although only one thread uses them at a time.

Next: **migratory ownership**. A page (or a chunk) that changes hands should move to the new thread instead of
becoming shared: the old owner loses it by `mprotect`, which also makes its stores visible, and both threads keep
plain accesses. Only pages used by two threads at once (detected by ping-pong) become shared. That is the case of
zstd's, pigz's and xz's buffers.

## 13. Migratory ownership: built, measured, off by default (2026-11-17)

Section 12 ended with zstd's input buffer: filled by one thread, compressed by another, reused, and therefore shared
read-write for good, with the compressing loop escalated. Migratory ownership (`TSO_VIEWS_MIGRATE=1`) moves a page
to the thread that writes it instead of sharing it: the old owner loses it through `mprotect` (which also completes
its earlier plain stores), both threads keep plain accesses. A reader of another thread's page still shares it
read-only; a quiet shared read-write page goes to its next writer, or read-only to its next reader. A page that
changes hands quickly several times in a row (`TSO_VIEWS_QUICK` microseconds, `TSO_VIEWS_STRIKES` times) is really
used by two threads at once and is shared as before, its plain writers escalated. No migration in the fallback.
Litmus tests: 0 forbidden outcomes with it on.

It does what it should: zstd's escalations drop from 2,636 to 535 to 635. It does not pay. First runs, best of 2
(`bench/migrate_sweep.sh`):

| Setting | pigz | xz | zstd |
|---|---|---|---|
| no migration | **1.47 s** | 1.62 s | 0.99 s |
| migration, quick = 1 ms, 2 strikes, chunks follow | 1.87 s | **1.59 s** | 0.97 s |
| migration, quick = 20 ms, no strike, chunks follow | 1.54 s | 1.67 s | 0.97 s |
| the same, single pages only | 1.56 s | 1.63 s | 0.97 s |

Every change of hands is a fault plus `mprotect` in every view of every thread, taken under the address space lock
that every other thread's page faults also need: 100 to 150 microseconds on average under load, and pigz's
buffers change hands thousands of times (2,165 migrations, 30,000 to 250,000 pages moved with their chunks). An
escalated instruction pays nothing like that: loads become `ldapr`, which the A76 executes at the cost of a
plain load. On this machine ordering shared data is cheaper than moving it. It would be worth another look on a
host with a cheaper way to change per-thread rights (memory protection keys or Arm's permission overlays, which
change rights by a register write instead of page table updates).

zstd stays at about 0.9 to 1.0 s against 0.72 s with FEX's full TSO; its gap is the ordered stack in the fallback
(section 12) and its large escalated hot loop.

## 14. Stack pointer as a view address: tried, discarded (2026-11-17)

In xz's hottest block 118 of the 332 view additions were for RSP (section 12). The experiment
(`fex/experiments/stack-pointer-views.diff`, on top of the patch of this commit) kept RSP's static register as an
address in the plain view: guest RSP + x24. `SpillStaticRegs`/`FillStaticRegs` and the signal handler's
`SpillSRA` convert between that and the guest value in the context; the rewriting pass gives every load of RSP a
guest-value node (`and` with the window mask), maps addresses on it back to the register, and stores RSP +/-
constant and alignment masks in view form, anything else with the view base added. Correct at once (litmus,
threads, shared stacks, all workloads), and no faster:

| Instructions (user, all plain, `bench/perf_views.sh`) | FEX without ordering | views | views + RSP as view address |
|---|---|---|---|
| xz | 15.89 G | 18.08 G | 18.09 G |
| pigz | 14.02 G | 16.58 G | 16.80 G |

The additions it saves are mostly outside the hot loops (one per block that uses the stack), and it adds work
where RSP is used as a value: an `and` for every `lea x(%rsp)`, and a view addition after `add`/`sub` of RSP when
the flags are live. Not kept.

What remains of the view cost is one addition per basic block and base register; FEX's IR keeps values inside a
block, so they cannot be shared further without changing its register allocation.

## 15. FEX's own code generation (2026-11-17)

FEX without any ordering reaches 84 % of native (geometric mean); 90 % with correct ordering would need a better
translation first. Where FEX loses against the native build (`bench/native_vs_fex.sh`, `bench/stalls.sh`, xz,
user mode, billions):

| | instructions | cycles | backend stalls | frontend stalls | loads | stores |
|---|---|---|---|---|---|---|
| native | 10.34 | 7.23 | 2.84 | 0.13 | 2.58 | 0.76 |
| FEX, TSO off | 15.89 | 8.79 | 2.85 | 0.12 | 3.35 | 1.28 |

Stalls are the same; the 1.56 billion extra cycles are spent issuing 5.56 billion extra instructions. 1.3 billion
of them are loads and stores the x86 code itself has (16 registers: more values live on the stack). The rest is
spread thin: in the hottest function (`bench/mix_compare.sh`, lzma_lzma_optimum_normal: 1,744 instructions native,
2,671 translated) more additions (address arithmetic), register copies, merges into 16-bit parts of registers
(`bfxil`, `uxth`, from x86's 16-bit writes), `mul` where the compiler would shift and add, and materialised
constants for large displacements. pigz: +21 % instructions, +10 % cycles; zstd: +5 % cycles, its wall time is lost
in the serial main thread.

Changes (`LocalCSE.cpp`, `Addressing.cpp`), measured on all three without views (`bench/codegen.sh`):

- **Narrowing**: `Bfe(32, Op64)` of a single-use 64-bit add, sub, shifted add, mul, logical op or constant shift
  becomes the 32-bit operation (Arm zero-extends), `add x20, x7, #1; mov w9, w20` -> `add w9, w7, #1`. xz -2.6 %
  instructions.
- **Large displacements**: an aligned displacement that does not fit the access is split into
  `add #imm, lsl #12` on the base and the access's immediate, instead of `mov`, `movk` and a register offset. xz
  -2 % instructions.
- **Value sharing within a block** (registers loaded once, equal address arithmetic and constants computed once):
  fewer instructions on paper, more cycles in practice (longer live values for FEX's register allocator), also
  restricted to address arithmetic. Off (`TSO_ARM_CSE=1` or `2` to try).

Together xz runs 4.6 % fewer instructions and about 1 % fewer cycles; pigz and zstd within the noise. The
efficiency table shows the build without ordering at the same 84 % as upstream FEX.

Assessment: the remaining distance to native is many small costs of translating x86 (its register pressure, its
partial registers and flags), each worth a percent or less. That is FEX's own long-term work, not something a
memory-ordering project closes; 90 % of native with correct ordering is out of reach on this path.

## 16. Hot functions translated ahead of time (prototype, 2026-11-17)

Section 15 left the distance to native in the translation itself: a JIT that translates one instruction at a time
keeps x86's register pressure, flags and partial registers. A compiler that sees whole functions removes them. The
prototype (`aot/`) translates the hot functions of a program ahead of time into C, compiles them with clang for the
host, and FEX runs them instead of its own translation; everything else stays with FEX.

Where xz spends its time natively (`bench/func_profile.sh`): match finder (`bt_find_func`, `lzma_mf_bt4_find`,
`bt_skip_func`, `lzma_mf_bt4_skip`, `move_pos`) 59 %, encoder (`lzma_lzma_optimum_normal`, `get_literal_price`,
`rc_encode`, `lzma_lzma_encode`, `length`, ...) 40 %. Translating `lzma_lzma_optimum_normal` alone would call back
into the guest once per input position; the unit is the whole call tree below `lzma_lzma_encode`: 13 functions,
about 3,700 x86 instructions, 99.3 % of native xz's cycles.

**Translator** (`aot/lift.py`, Capstone for decoding):

- A guest function becomes a C function with the System V convention: the six argument registers are parameters,
  rax the result, stack arguments are read through a pointer to the caller's outgoing area. Registers are C locals,
  so callee-saved registers survive calls by construction and clang allocates them to host registers. Calls between
  translated functions are C calls (clang inlines across them); calls to other code go back into the guest through
  FEX (`aot.h`, `guest_call`); indirect calls check the translated functions first.
- Flags are C locals written by every flag-setting instruction; clang drops the unused ones. A condition in the
  same basic block as its compare is computed from the compared values (`a < b` instead of carry).
- The stack offset is known at every instruction (data flow over the function). Stack slots reached only as
  `rsp + constant` become a local array, which clang turns into registers: the spills x86's 16 registers force
  disappear. They cannot be seen by other threads, so their order does not matter.
- Stack objects whose address is taken or that are indexed (`lea` of `rsp`, `[rsp + reg*4 + c]`): an escape
  analysis (forward data flow over registers and stack slots, with a summary per argument register of every
  translated function, to a fixed point over the call graph) decides where they live. If their addresses provably
  stay in translated code and out of memory, in a host array (reached as `view + address`); otherwise on a stack
  of the thread's own for translated code, in guest memory, which the thread allocates itself, 2 MiB aligned, alone
  in its chunk of the page protocol, so it stays private. (The thread stacks themselves end up shared in xz, next to
  the pthread structures other threads touch: 297 of the 1,952 instructions the protocol escalates in xz are in
  `lzma_lzma_optimum_normal`, mostly stack accesses.)
- Read-only segments: constants are read at translation time, tables indexed by a register are read unordered
  (immutable data cannot be seen out of order).
- All other memory is guest memory, in two variants of every function. The plain variant goes through the thread's
  plain view with volatile accesses: the compiler keeps their program order, and the page protocol orders them
  against other threads as it does FEX's plain accesses. When one of them meets a shared page, the fault handler
  completes it with barriers (as for FEX's code) and switches the function to its ordered variant from its next call
  on: the ordered view with `ldapr`/`stlr` (an unaligned access between full barriers). The protocol's fallback to
  full ordering switches all functions. Atomics (`xchg`, `lock`) are `__atomic` operations on the ordered view.

**FEX side** (`fex/patches/0002-*`): `TSO_AOT=library` loads a table of guest function, size, FNV-1a hash and host
entry; each entry is checked against the mapped guest code and becomes a custom IR entry point whose block calls a
thunk bridge. The bridge runs the host function and performs the return (rax, rsp, the return address); calls from
host code back into the guest use FEX's thunk callback path.

**xz** (Raspberry Pi 5 at 1.8 GHz, `bench/efficiency.sh`, best of three, wall time):

| Configuration | x86 order kept | xz |
|---|---|---|
| FEX, TSO off | no | 79 % |
| tso-arm, with profile | yes | 70 % |
| ahead of time, TSO off | no | 90 % |
| ahead of time, all ordered (`ldapr`/`stlr` throughout, FEX full TSO for the rest) | yes, except RSP | 67 % |
| ahead of time + tso-arm, with profile | yes | 86 % |

Once the code itself is close to native, ordering is the largest cost left: ordering every access of the translated
functions takes xz from 90 % to 67 %, the page protocol keeps it at 86 %.

- User-mode cycles of the whole run: native 7.21 billion, translated ahead of time 7.38 billion (97.6 %); per part
  match finder 4.26 vs 4.30, `lzma_lzma_optimum_normal` 2.46 vs 2.50, `rc_encode` faster than native.
- The wall-time gap that is left is mostly FEX's fixed cost per process (`bench/startup.sh`: xz on an empty input
  takes 59 ms under FEX, upstream as well, against 0.8 ms natively; about 30 ms of it is CPU time for translating
  start-up code). On a run of about a second that is five points of efficiency.
- With the page protocol and a profile the protocol is almost idle: 115 faults in 5 ms, no escalations in
  translated code.

**Correctness**: xz's output is byte-identical in every configuration. Litmus tests with the thread functions of
`litmus/mp.c` translated ahead of time (`litmus/run_aot.sh`, 200,000 iterations): without ordering forbidden
outcomes show (mp 1; rep 4 and repflag 2 in an earlier run), with everything ordered and with the page protocol none
in any variant. A spin loop on a shared flag in translated code faults on every read until the function returns
(the switch to the ordered variant takes effect at the next call); the protocol's guard against fault loops now
counts only faults that make no progress.

Limits of the prototype: only the instruction forms these functions use; the bound of a jump table is found by
pattern (an index outside it ends in an abort, not silently); indirect calls are assumed to pass no stack
arguments; the per-thread stack for translated code (2 MiB, 4 MiB reserved) is not freed when a thread ends; guest
code changed after loading is not noticed (the hash is checked once).

## 17. pigz and zstd ahead of time; single accesses ordered by patching (2026-11-17)

Hot sets (`bench/func_profile.sh`, `aot/calls.sh`): pigz 16 functions, 2,941 x86 instructions (zlib's
`deflate_slow` and everything below it, `crc32_z`); zstd 16 functions, 5,276 instructions (the double-fast match
finder, 3,296 instructions in one function, sequence encoding in the BMI2 variant FEX's CPUID selects, XXH64, block
splitting with its fingerprint functions, statistics).

Translator additions: SSE integer operations (`pand`, `pcmpgtd`, `punpcklwd`, `pshuflw`, `psrldq`, ...) on clang
vectors, so xmm values stay in NEON registers; BMI2 shifts, `bzhi`, `mul`, `bt`/`bts`, prefetches; functions that
share a name (zstd has five static `ZSTD_safecopyLiterals`) are named by address; stack arguments of calls into guest
code are copied to where the x86 code has them on the guest stack (zstd's `ZSTD_buildCTable` takes 16 arguments).

Three faults found on the way:

1. **FEX, dispatcher stack**: a signal handler that sends a thread back to the dispatcher loop from inside a block
   (an escalation, a boundary exit, self-modifying code) leaves the block's spill area on the host stack. In the
   outer loop that is a small leak; in a callback from host code into guest code (thunks, here the translated code
   calling memcpy through the PLT) the callback's return then pops the wrong frame and jumps to address 0. The page
   protocol sends threads back often enough to hit it. Fix: the frame records the stack pointer of the dispatcher
   loop that runs; the loop top resets it; a callback keeps the outer loop's value and restores it on return.
2. Stack objects kept in host memory are addressed relative to the plain view; the ordered variant read them
   through the ordered view, 2^38 away. Ordered accesses now take an address above the 16 GB window as such an
   object.
3. Switching a function to its ordered variant looked up the nearest function start below the faulting pc; clang
   had inlined the plain variant into the entry function, so the wrong function was switched. Entry points and
   indirect calls now call through a table.

**Single accesses instead of whole functions.** Switching whole functions is too coarse: in pigz seven functions
met shared memory somewhere, among them `deflate_slow`, and ran ordered from then on (2.02 s, cold). Now the fault
handler replaces the faulting instruction by a branch to a ten-word stub: the base register with bit 38 set (the
ordered view), the original instruction, `dmb ishld` after a load or `dmb ish` before a store, and back. A base or
64-bit offset register that already has bit 38 set holds a host address (a stack object in host memory) and takes
the original instruction. This is FEX's escalation of single instructions, done to the translated code: pigz
1.37 s cold, 1,896 escalations (FEX alone: 1,920). Whole functions switch only for an instruction the patcher does
not know, and in the protocol's fallback. Litmus tests (`litmus/run_aot.sh`): without ordering mp 4, vec 5,
vecwait 7 forbidden outcomes; ordered throughout and with the protocol none, and store buffering shows again
(1,111 times), so the stubs do not order more than x86.

**zstd** stays where it was. It falls back to full ordering in every run (its input buffers move between threads,
sections 12 and 13), and it is memory-bound: natively 0.68 instructions per cycle. Translated ahead of time it
executes fewer instructions than FEX (2.15 against 2.61 billion) but not fewer cycles (2.96 against 2.85; native
2.69). Unaligned ordered accesses now take one barrier instead of two (`ldr; dmb ishld`, `dmb ish; str`).

Efficiency (`bench/efficiency.sh`, best of three, README table):

| Configuration | x86 order kept | pigz | xz | zstd | mean |
|---|---|---|---|---|---|
| FEX full TSO | yes, except RSP | 61 % | 70 % | 68 % | 66 % |
| tso-arm, with profile | yes | 74 % | 69 % | 57 % | 66 % |
| ahead of time, TSO off | no | 92 % | 91 % | 83 % | 89 % |
| ahead of time, all ordered | yes, except RSP | 56 % | 64 % | 64 % | 61 % |
| ahead of time + tso-arm, with profile | yes | 81 % | 85 % | 53 % | 71 % |

**FEX's fixed cost** is the larger lever left for short runs: zstd on an empty input compiles 406 blocks, 45 ms of
CPU time; against zstd's 0.49 s natively that alone is about ten points. FEX's own code cache
(`FEX_ENABLECODECACHINGWIP=1`) crashes on the third run (SIGILL) and is no way out as it stands.

## 18. Start-up, the PLT, and a fallback without views (2026-11-17)

**Start-up** (`bench/startup.sh`, a program on an empty input, median of 9): xz 67 ms under FEX with views, 37 ms
with `FEX_MULTIBLOCK=0`; zstd 93 -> 59 ms. Multiblock compiles whole guest functions at once, cold paths included;
with the hot functions translated ahead of time, FEX only translates the rest, and block by block is cheaper.
For FEX's own translation of the hot code multiblock is worth it (all three programs lose without it: FEX without
ordering 82 -> 76 %), so only the ahead-of-time configurations switch it off. FEX also writes a telemetry file at
every exit with an `fsync` (10 ms on the Pi's SD card in `bench/startup_trace.sh`; in the medians within the noise),
left as it is.

**PLT**: translated code calls glibc's string functions through the PLT, which jumps through a GOT slot written at
start-up by an IRELATIVE relocation (the AVX variants under FEX's CPUID). Such a call now reads the slot and calls a
translated target directly; glibc's `__memmove_avx_unaligned_erms` and `__memset_avx2_unaligned_erms` are translated
(256-bit moves as two 128-bit halves, `vpbroadcastb`, `vzeroupper`, `rep movsb`) but not routed for FEX's own calls
(`--internal`): routing them as well changed nothing for pigz (82 against 81 %). pigz also gained
`deflateSetDictionary` and `deflateStateCheck`: no calls back into the guest are left in its hot path.

**Fallback without views**: a program whose profile says it fell back to full ordering (zstd in every run) now runs
without views from the start (FEXInterpreter reads the profile before the context exists): FEX's full TSO and the
ordered variants of the translated functions, without the views' set-up and address arithmetic. Translated code
without views and with FEX's TSO on always runs its ordered variants (before, only `TSO_AOT_ORDERED=1` did that).
zstd with its functions translated ahead of time: 0.87 s on the first run (it falls back and says so in the
profile), 0.70 s after (57 % -> 70 %).

Efficiency (`bench/efficiency.sh`, best of three, README table):

| Configuration | x86 order kept | pigz | xz | zstd | mean |
|---|---|---|---|---|---|
| FEX full TSO | yes, except RSP | 61 % | 70 % | 67 % | 66 % |
| tso-arm, with profile | yes | 74 % | 71 % | 66 % | 70 % |
| ahead of time, TSO off | no | 93 % | 93 % | 89 % | 92 % |
| ahead of time, all ordered | yes, except RSP | 56 % | 65 % | 64 % | 62 % |
| ahead of time + tso-arm, with profile | yes | 83 % | 87 % | 66 % | 78 % |

Without ordering the translation is past 90 %. With x86 order kept the page protocol leaves 6 to 10 points for pigz
and xz; zstd hands its data between threads and pays for full ordering (66 %, as FEX's full TSO).

## 19. What the protocol costs translated code (2026-11-18)

`aot/protocol_cost.sh`: the same translated program without ordering and under the page protocol with a profile
(median of 5, fixed clock). At the start pigz paid 150 ms (1,077 -> 1,227 ms), all of it user time (4.09 -> 4.41 s);
the protocol's own work was small (327 faults, 38 ms over all threads). Where it went (`aot/protocol_where.sh`,
`aot/hot_stubs.sh`):

- **glibc's memmove in FEX's JIT**, 0.29 billion cycles. Under the protocol FEX is run with
  `FEX_MEMCPYSETTSOENABLED=1`, and with it reports no ERMS in CPUID, so glibc picks `__memmove_avx_unaligned`
  instead of the ERMS variant that was translated. The variants share one body and jump into each other; the
  translator now takes a region with an entry inside it (`NAME=ENTRY:START:END`, `aot/strings_specs.sh` for every
  memmove/mempcpy/memset entry). String functions are translated as units (`--strings`): one `dmb ish` on entry and
  before each return, their own accesses plain through the ordered view in any order. The C library leaves that
  order unspecified (glibc itself copies the tail first or in overlapping blocks), so no program can depend on it;
  it is how FEX orders `rep movs` with that option. They are routed for every caller, FEX's code included.
- **Patched accesses**: 72 sites, 5.5 % of all cycles in their stubs. Integer loads without writeback now get a fast
  stub: the address into the destination register, bit 38 set, `ldapr` (as cheap as a plain load on the A76) if
  aligned, the barrier path otherwise. The alignment test uses `tbnz`, not `tst`: the first version broke pigz and
  zstd, because clang may keep a comparison's flags live across a load.
- **Read-only data made shared read-write**: the hottest stubs read zlib's constant Huffman tables. A program's
  read-only segment lies in the same 2 MB chunk as its `.data`, `.bss` and heap start, which every thread touches;
  after four transitions the chunk collapsed to shared read-write, read-only data included, and every read of it
  was ordered (FEX's own code was escalated for it as well). A collapse now makes pages the guest cannot write shared
  read-only, readable in all plain views; a later mprotect that allows writing is covered, since the first write
  faults and upgrades the page.

pigz: 150 ms -> 58 ms (1,102 -> 1,160 ms), stubs 5.5 % -> 2.4 %, 57 patched sites. The rest is mostly
`crc32_z` reading the input buffer, which the reading thread fills: data that really moves between threads.

xz pays 45 ms (1,153 -> 1,198 ms) with the same user cycles (7.57 against 7.56 billion). It is kernel time: guest
memory under the protocol is shared memory mapped into the views of every thread in use, and each new guest mapping
costs an `mremap` per view plus `mprotect` calls for the rights (494 and 1,315 calls in one run, about 26 ms of
system calls), and `read` into shared memory is slower (22 against 3 ms). Page faults are not the problem
(`aot/protocol_faults.sh`, 2.4 GHz: 55,763 without ordering, 41,224 with the protocol, whose shared memory the
kernel maps around a fault). Transparent huge pages would not change much and are not available anyway: the
4 KB-page kernel FEX needs here (`rpi-v8`) is built without them.

## 20. Views mapped on first use (2026-11-18)

Until now every guest mapping went into the plain and the ordered view of every thread at once (an `mremap` per
view), and a new thread mapped every existing range into its views; each change of rights then took an `mprotect` in
every view. Now a range carries a mask of the slots whose views map it. A mapping goes into the views of the thread
that makes it; another thread meets the reservation (`PROT_NONE`) at its first access, and the fault handler maps the
range into that thread's two views with its rights and lets the access run again (it may fault once more for its
page's state). Rights are only ever set in views that map the range; a thread that ends clears its bit; stage 1,
which has no fault handling, and `TSO_VIEWS_EAGER=1` map everything at once as before.

Correct in every test (the views matrix with shared stacks and twelve threads, outputs, both litmus series), and the
system calls drop by half (`aot/lazy_views.sh`, one run each):

| | mprotect | mremap | wall, median of 5 |
|---|---|---|---|
| xz, at once | 1,368 | 494 | 1,212 ms |
| xz, on first use | 660 | 162 | 1,214 ms |
| pigz, at once | 3,368 | 596 | 1,174 ms |
| pigz, on first use | 1,788 | 380 | 1,172 ms |

The wall time does not move: these calls were never the cost (strace's own overhead had made them look like
26 ms). Kept anyway, since a thread no longer maps every existing range when it starts, which matters for programs
with many threads and mappings. What xz still pays (`aot/protocol_stat.sh`): user cycles equal (7.53 against 7.54
billion), kernel cycles +0.07 billion (about 10 ms of wall time over five threads), the rest on the serial path of
its main thread (reading, handing out blocks, writing), which runs FEX's own code with ordering.

Litmus tests after the change: FEX's own under the protocol (500,000 iterations) and with translated thread
functions, ordered and under the protocol: no forbidden outcome. Efficiency (best of three, README table):

| Configuration | x86 order kept | pigz | xz | zstd | mean |
|---|---|---|---|---|---|
| FEX full TSO | yes, except RSP | 61 % | 70 % | 69 % | 67 % |
| tso-arm, with profile | yes | 75 % | 73 % | 67 % | 72 % |
| ahead of time, TSO off | no | 92 % | 95 % | 89 % | 92 % |
| ahead of time + tso-arm, with profile | yes | 86 % | 92 % | 68 % | 81 % |

Native xz varies between sessions and rounds (1.07 to 1.15 s, cooled below 60 °C each time; 1.09 s best here),
so its efficiency carries about three points either way; translated xz with the protocol took 1.19 to 1.26 s.

## 21. zstd: where full ordering is the best on offer (2026-11-18)

zstd is the program that keeps the mean below 90 %: 89 % translated without ordering, 68 % with it. It falls back to
full ordering in every run; the alternatives, with its functions translated ahead of time
(`aot/zstd_fallback.sh`, median of 5, profile of each setting's own):

| Setting | Wall | Faults |
|---|---|---|
| fallback to full ordering (as measured) | 725 ms | - |
| protocol, no fallback (`TSO_VIEWS_BUDGET=0`) | 946 ms | 3,003 in 53 ms, 35,343 pages moved with their chunk |
| the same without chunks (`TSO_VIEWS_CHUNK=0`) | 1,119 ms | 34,267 in 347 ms |
| the same with migratory ownership (`TSO_VIEWS_MIGRATE=1`) | 761 ms | 5,447 in 441 ms, 1,471 migrations |

Without the fallback the chunk collapses make zstd's hash tables shared read-write: its compression contexts and
buffers go from one worker to the next (they come from pools), one thread at a time. Migrating them instead works
with the views mapped on first use better than before (section 13: 0.97 s against 0.99 s), 761 ms against 946 ms,
but each change of hands still costs about 80 microseconds of `mprotect` and TLB shootdowns: ordering the data
remains cheaper than moving it.

Within full ordering (`aot/ordered_hot.sh`): in the ordered `ZSTD_compressBlock_doubleFast` 22 % of the samples sit
on barriers, almost all `dmb ishld` after unaligned loads (three sites 19 %: the input read at byte positions), 7 %
on `stlr`, 0.4 % on `ldapr`. Reading the aligned words that cover an unaligned load with `ldapr` instead
(`AOT_WORDS`, `aot/words_sweep.sh`): 745 ms with barriers, 738 ms for 8-byte loads, 769 and 776 ms for 4 and 2
bytes (all sizes at once: 782 ms). zstd is memory-bound, and the barriers wait on cache misses that cost the same
time either way; kept as it was.

So on this core zstd's ordering costs about as much as FEX's full TSO (67 to 69 %), whatever is translated how.
What would change it is hardware: FEAT_LRCPC2 (`ldapur`, ordered loads with offsets and without the alignment
fault) and FEAT_LRCPC3 (ordered vector accesses) remove the barriers from unaligned and vector loads; the A76 has
neither.

Correctness: outputs identical everywhere; litmus tests with translated thread functions (forbidden outcomes only
without ordering: rep 2, vecflag 2, vecwait 1) and FEX's own litmus tests under the protocol (500,000 iterations,
none) after the change to collapsing chunks.

Measuring: one session had native xz 5 % slow (1.13 s against 1.07 s; the chip was still warm from the litmus
runs), which made translated xz look 94 % efficient. `bench/efficiency.sh` now cools down below 60 °C before every
run, not only before every round. Efficiency (best of three):

| Configuration | x86 order kept | pigz | xz | zstd | mean |
|---|---|---|---|---|---|
| FEX full TSO | yes, except RSP | 61 % | 69 % | 67 % | 66 % |
| tso-arm, with profile | yes | 75 % | 71 % | 65 % | 70 % |
| ahead of time, TSO off | no | 92 % | 93 % | 87 % | 91 % |
| ahead of time + tso-arm, with profile | yes | 86 % | 88 % | 68 % | 80 % |

The page protocol now costs translated pigz and xz 5 to 6 points; zstd pays full ordering for its shared data.

## 22. A thread's end walked the whole window; start-up; rep stos (2026-11-18)

**crc32_z ordered from the start** instead of its patched loads (`aot/lift.py --ordered NAME`, the function's
ordered variant chosen at load; `aot_order_reset` puts it back when FEX runs without ordering): 1,166 against
1,163 ms for pigz (`aot/ordered_cmp.sh`, median of 5), no difference. Kept as an option, not used.

**Thread end.** Under the page protocol each pigz worker spent about 0.08 billion cycles more than without
ordering, in FEX and in code at the start of an anonymous executable mapping. perf on a FEX linked without
`--strip-all` (`fex/link_symbols.sh`: same code and addresses, with a symbol table) named the FEX part:
`TSOViewMemory::DetachThread`, 1 % of all cycles. When a thread ended, it cleared the thread's bit in the state of
every page of the 16 GB window, 4 million pages, under the protocol's lock, and wrote every `ROMask` entry whether
it changed or not, which made the kernel back all 8 MB of that table with real pages. Several milliseconds per
thread, one thread after the other at the end of the program. Page states exist only inside guest mappings (a
mapping sets them, an unmapping clears them), so it now walks the mappings only and writes only what changes.
The other part was the patched access stubs (`aot/hot_stubs.sh`: 2.2 % of cycles, mostly crc32_z).

The serial walk is gone from every thread's end; what it was worth in wall time is hard to state for pigz, whose
runs fall into two groups (below). `aot/output_cost.sh` (median of 5, fixed clock) puts the protocol's cost at
about 35 ms for pigz after the change (1,077 to 1,091 ms without ordering, 1,109 to 1,113 ms under the protocol),
against 58 ms before (`aot/protocol_cost.sh`, section 19); xz paid 45 ms before and 3 ms in one session after
(1,197 against 1,200 ms). Correct in every test: the views matrix (shared stacks, twelve threads), outputs of all
three programs with and without ordering, FEX's litmus tests under the protocol and the litmus tests with
translated thread functions (200,000 iterations each, no forbidden outcome).

**Start-up** (`bench/startup_aot.sh`, empty input, median of 15, 1.8 GHz): native pigz 1.2 ms; translated without
ordering 29.4 ms, under the protocol 31.5 ms; the library itself adds less than 1 ms. Of FEX's part, 13 ms are
1,453 blocks compiled (glibc's start), 7 ms FEX's telemetry file, written at every exit with an `fsync` (on the
Pi's SD card). The efficiency table now runs every FEX configuration with `FEX_DISABLETELEMETRY=1`, FEX's own
included: it has nothing to do with translation. The protocol's statistics took two clock reads per compiled block
and per fault even when nobody asked for them (3 % of the start-up's cycles); only with `TSO_VIEWS_STATS` now.

**rep stos.** Without ordering FEX reports ERMS, glibc picks `__memset_avx2_unaligned_erms`, and its `rep stosb`
was translated as one volatile byte store per iteration: 0.21 billion cycles in pigz, 2.8 % of all (under the
protocol FEX hides ERMS and glibc uses the vector stores). The stores of one string instruction may happen in any
order among themselves (x86 fast strings), so `rep stos` now fills 16 bytes per store; still the library's own
stores, not a call to `memset`, so that a fault under the protocol comes from translated code and can be patched.
Ordered: a `dmb ish` before (every later store is a release or follows a barrier).

**Code quality** (`aot/vs_native.sh`, user cycles per function, native build against the translation without
ordering): pigz 6.96 against 7.37 billion (+6 %), of it `longest_match` 3.74 against 4.13 (+10 %), `compress_block`
+11 %, `deflate_slow` and `slide_hash` faster than native. xz 7.23 against 7.57 (+5 %), `lzma_lzma_optimum_normal`
+10 %, the match finders +2 %. The hot chain loop of `longest_match` (`aot/annotate_vs.sh`) is 13 instructions
translated against 11 native (two register copies, an extending compare) and waits on the same loads; the byte
comparisons after it take an extra `add` each, since guest addresses are formed relative to the view's base.

**Addresses as view + base + displacement** (tried, taken out): `V + (base + disp)` cannot be split by clang (the
integer sum may wrap), so every access computed its own address. Formed as `(V + base) + disp` instead, accesses
shared the base register and used immediate offsets. User cycles unchanged (`aot/ab_cycles.sh`, median of 5,
without ordering): pigz 7.363 against 7.374 billion, xz 7.495 against 7.485. The extra `add`s are not on the
critical path; the A76 has the arithmetic units to spare.

**A wrong patch stub** turned up with it: zstd crashed under the protocol. `ldr w15, [x2, x18]`, x2 the view plus
`ip`, x18 the negative `1 - offset_1`: the stub took bit 38 of the offset register as the sign of a host address and
ran the access plainly on a page another thread writes (found with `TSO_AOT_PATCH_MAX`, `aot/patch_bisect.sh`). The
old address form could meet the same split, since clang's backend reassociates the integer additions freely; it had
not happened to. Stubs now compute the address and decide by its bit 38: loads into their destination register as
before (`ldapr` when aligned, the instruction there with `dmb ishld` when not), everything else (stores, vector and
pair accesses, a destination that is also base or offset, writeback) through a scratch register saved on the host
stack, with the instruction converted to that base and the writeback applied after. Stores whose data register is
the base can now be patched as well. Correct with every load on the general path too (`TSO_AOT_NOFAST=1`,
`aot/stub_check.sh`), in the views matrix and both litmus series.

**crc32_z ordered** against its patched loads once more, by user cycles under the protocol (`CFG=protocol
aot/ab_cycles.sh`, median of 6): 7.475 against 7.435 billion, half a percent less. Real, but it needs a choice per
program, and a rule such as "functions with many patched sites start ordered" would order `deflate_slow` as well,
whose stores would all become `stlr`. Not used.

**Two groups of wall times.** pigz under FEX lands either near 1.07 s or near 1.11 s without ordering, near 1.11 s or
1.16 s under the protocol, from run to run (`aot/bimodal.sh`, `aot/output_cost.sh`); natively 1.00 s with one outlier
in ten. User and system time are the same in both groups; the slow runs have more involuntary context switches and
more ranges mapped into a view on first use (140 against 127 to 132), so it is how six threads share four cores, not
work done. `bench/efficiency.sh` now takes the best of five rounds (the profile configurations learn in the first).
The output's destination makes no difference (`/dev/null` against `/dev/shm`: 1,109 against 1,113 ms).

**What the start-up compiles** (`bench/startup_blocks.sh`): xz on an empty input compiles 2,213 blocks in 291 guest
functions, the largest `init_cpu_features` with 87; glibc's start, locale, malloc and option parsing. Nothing there
to translate ahead of time in one piece.

Efficiency (`bench/efficiency.sh`, best of five, telemetry off in every FEX configuration, README table):

| Configuration | x86 order kept | pigz | xz | zstd | mean |
|---|---|---|---|---|---|
| FEX full TSO | yes, except RSP | 61 % | 70 % | 68 % | 66 % |
| tso-arm, with profile | yes | 79 % | 72 % | 68 % | 73 % |
| ahead of time, TSO off | no | 91 % | 93 % | 89 % | 91 % |
| ahead of time + tso-arm, with profile | yes | 89 % | 90 % | 69 % | 82 % |

With x86 order kept, pigz and xz are at 89 and 90 % (xz's protocol runs fall into two groups as well: 1.19 s once,
1.25 to 1.26 s in the other three profile rounds). What is left between them and native: the start-up (25 and
36 ms, mostly FEX compiling glibc's start block by block), code quality of the translation (5 to 6 % more user
cycles, `longest_match` and `lzma_lzma_optimum_normal` about 10 %), and for pigz the patched loads of crc32_z on
the input buffer the reading thread fills.
