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
