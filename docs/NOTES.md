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

## 23. zstd: what a fault costs, and migration once more (2026-11-18)

The start-up is not where zstd's points go: on an empty input it stops at once (30 ms, FEX's start and glibc's);
a FEXServer started anew for every run (it exits one second after its last client, so runs with a pause between them
start it again) costs 2 to 2.5 ms (`bench/startup_server.sh`). FEX's own code cache is filled in the background by
`FEXOfflineCompiler`, which knows nothing of the views, the escalated instructions or the profile; tying it in is a
project of its own.

With the thread end fixed (section 22), migratory ownership without the fallback (`TSO_VIEWS_MIGRATE=1
TSO_VIEWS_BUDGET=0`) came out ahead of the fallback in one session (705 against 727 ms, `aot/zstd_fallback.sh`).
`TSO_VIEWS_STATS` now also counts the protocol's `mprotect` calls, the time faults wait for its lock and the time
spent moving chunks. zstd with migration:

| | |
|---|---|
| faults handled | 4,444 in 0.305 s (all threads) |
| of it waiting for the lock | 0.161 s |
| mprotect | 36,677 calls, 1.96 million pages, 0.095 s |
| moving chunks | 0.064 s |

Two changes against it, both measured and taken out again:

- Moving a chunk re-protected all 512 pages in every view. Only the pages that moved, only in the views whose rights
  change: 1.31 instead of 1.96 million pages, the same wall time (707 ms).
- A right a view may hold but was not given yet (2,995 such faults, one page each) given for the whole chunk at
  once: 296 of them, half the faults, the same handling time (0.357 s) and no better wall time.

The cost is in few expensive faults, chunk moves whose `mprotect` the kernel does while the other threads wait for the
lock, not in the number of faults. Side by side (`aot/ab_env.sh`, six runs each, alternating): fallback best 739,
median 782 ms; migration with the budget 732 / 766 ms (it still falls back); migration without the budget 699 /
764 ms, with 3.27 instead of 3.99 billion user cycles. The spread is larger than the difference: handing zstd's
buffers and contexts from thread to thread costs about what ordering them costs. Left as it was.

Efficiency after these changes (only the statistics are new in FEX; best of five, README table):

| Configuration | x86 order kept | pigz | xz | zstd | mean |
|---|---|---|---|---|---|
| FEX full TSO | yes, except RSP | 60 % | 70 % | 69 % | 66 % |
| tso-arm, with profile | yes | 79 % | 72 % | 69 % | 73 % |
| ahead of time, TSO off | no | 93 % | 93 % | 91 % | 92 % |
| ahead of time + tso-arm, with profile | yes | 90 % | 90 % | 67 % | 82 % |

For a mean of 90 % with pigz and xz where they are, zstd would need 91 %, which it reaches only without ordering.

## 24. What else was tried for the last points (2026-11-18)

- **Ordered stores as `dmb ishst; str`** instead of `stlr` (with every load already acquire, a store needs only
  store-store order under TSO): 6 cycles against 5 in `bench/order_cost.c` (section 1). No.
- **The start-up translated ahead of time**: of the 40 guest functions FEX compiles most blocks for at xz's
  start-up (1,070 of 2,213 blocks), the translator takes none as they are (`aot/startup_liftable.sh`): frame
  pointer epilogues (`lea rsp, [rbp - 0x28]`), indirect jumps that are not jump tables, jumps into split-off cold
  parts, returns with the stack pointer moved, system calls. glibc's start code is a project of its own.
- **Instructions against cycles** (`aot/ipc_vs_native.sh`): translated `longest_match` executes 27 % more
  instructions than native (6.52 against 5.13 billion) for 10 % more cycles; `lzma_lzma_optimum_normal` 4 % more
  instructions for 10 % more cycles; zstd's translated code is as fast as native (`doubleFast` 0.98 of its cycles),
  its gap without ordering is start-up and FEX's own code.
- **Compiler options for the library** (`aot/ab_tune.sh`, user cycles without ordering, median of 5):
  `-mtune=cortex-a76` pigz -1.5 %, xz -0.5 %, zstd +1.7 %; `-O3` pigz -0.6 %, xz +0.7 %, zstd +2.2 %. The same
  build differs by up to 2.4 % between sessions. Left at `-O2`.

Where this leaves the target: with x86 order kept pigz and xz are at 90 %, zstd at 67 to 69 %. zstd's buffers and
contexts really move between threads; ordering them or moving the pages costs the same on this core. The part that
would shrink on newer cores is the barrier after each unaligned load (19 % of zstd's ordered match finder):
FEAT_LRCPC2 (`ldapur`) and FEAT_LSE2 (unaligned `ldapr` within 16 bytes) make those loads as cheap as aligned ones;
the A76 has neither.

## 25. Box64 on the same machine (2026-11-18)

Box64 refuses static binaries, so it runs dynamically linked builds of the same sources with the same options
(`study/build_dynamic.sh`: zlib, liblzma and libzstd linked in, only the C library dynamic, which Box64 runs as
native Arm code). `bench/box64.sh`, one session, best of three at 1.8 GHz, outputs checked:

| | x86 order kept | pigz | xz | zstd | mean |
|---|---|---|---|---|---|
| native | - | 1.01 s | 1.07 s | 0.49 s | 100 % |
| Box64, default (`STRONGMEM=0`) | no (litmus `stack`: 44 forbidden) | 77 % | 30 % | 86 % | 58 % |
| Box64, `STRONGMEM=1` | no (litmus `vec`: 123 forbidden) | 56 % | 28 % | 66 % | 47 % |
| Box64, `STRONGMEM=4` (TSO like QEMU) | yes (litmus clean) | 21 % | 17 % | 36 % | 23 % |
| tso-arm, ahead of time + protocol | yes | 87 % | 90 % | 68 % | 81 % |

(pigz under tso-arm landed in its slower group in this session; 90 % in the README's best of five.) xz under Box64
is slow in every setting. Box64's ordered mode costs it three quarters of its speed; its default and its first
level are not correct for multithreaded x86 programs on this core.

## 26. More threads than views, functions chosen from a profile, older cores (2026-11-18)

**Threads.** A thread with views of its own needs two 16 GB windows; a 39-bit address space holds 15 of them, and
the 16th thread at once stopped FEX ("no free view slot"). Now a thread that finds no slot starts the fallback to
full ordering (`FallbackForThread`: every page shared read-write, all translated code thrown away before the new
thread runs anything, the translated functions switched to their ordered variants) and shares the views of a slot
in use (`ShareSlot`; a count per slot keeps the views until their last user ends). Sharing is sound there: in the
fallback nobody owns pages and the ordered views have every right, so two threads on one slot see what one would.

A first version gave such a thread no views (guest memory itself, base 0). zstd with 12 threads (twelve workers and
its I/O threads) crashed: a patched access in translated code reaches the ordered view through the address with bit
38 set, which for base 0 is slot 0's ordered view, kept only in a measurement mode. Found with the handler's view of
the failing fault (`TSO_VIEWS_LOG`: range, rights mask, state). `tests/many_threads.sh`: the threads test with 12,
15, 16, 32 and 64 threads, pigz, xz and zstd with 32 threads, all correct.

**Functions chosen from a profile** (`aot/auto.py`, `aot/auto.sh`): one run under FEX without ordering, block by
block (`FEX_MULTIBLOCK=0`: with multiblock a block named by its start spans several functions, and the first
attempt credited `read_buf` with 45 % of pigz), cycles per guest function from FEX's block names; the functions with
at least 0.2 % each, every one through the translator and a compile check on its own; then the functions they call
directly, if they translate; the library, and the output with it, without ordering and under the protocol, against
a run without it (a function whose library alone changes the output would be left out). The lists go to
`aot/lists/`, which `aot/WORKLOAD.sh` builds from.

| | chosen | by hand before | guest cycles covered |
|---|---|---|---|
| pigz | 21 functions (adler32, crc32, adler32_z more) | 18 | 97.9 % |
| xz | 13 functions, the same as by hand | 13 | 99.1 % |
| zstd | 14 (hash table fill, Huffman and FSE tables more; three rarely used ones fewer) | 16 | 91.1 % |

Side by side under the protocol (`aot/auto_vs_hand.sh`, six runs each, best / median): pigz 1,148 / 1,155 ms by hand
against 1,142 / 1,150 ms chosen; xz 1,216 / 1,233 against 1,205 / 1,221 ms (the same functions: noise); zstd 740 /
764 against 755 / 764 ms. What the translator could not take: pigz's `compress_thread` (a jump into a split-off
cold part), zstd's `HUF_compress1X_usingCTable_internal_bmi2` and `ZSTD_compressLiterals`.

**Older cores.** Without FEAT_LRCPC (Cortex-A53, A72) `ldapr` does not exist. The patch stubs now use `ldar` there
(`getauxval(AT_HWCAP)`, `TSO_AOT_NORCPC=1` forces it), `aot/build.sh` builds the library for Armv8.0 when
`/proc/cpuinfo` has no `lrcpc` (`AOT_NORCPC=1` forces it), and the views refuse a kernel with pages other than 4 KB,
leaving FEX's own full ordering. FEX itself is built for the A76 here (`-mcpu=cortex-a76`); `fex/build_generic.sh`
builds it for any Armv8.0 core. `tests/norcpc.sh`, both forced on the test machine: no `ldapr` left in the
libraries, all outputs correct, litmus tests with translated thread functions without a forbidden outcome.

Other cores could not be tried: QEMU's user mode (Debian's `qemu-user` 10.0, unpacked, not installed) emulates
Cortex-A53/A72/A710, Neoverse N1/N2/V1 and more, but FEX does not run under it, upstream FEX neither (`tests/
qemu_smoke.sh`: segmentation fault at start). A full system emulation would need QEMU installed on the test machine.
`tools/board_check.sh` lists a board's requirements (architecture, page size, address bits, the ordering features)
and with `--run` builds, chooses, checks and measures everything there.

Checked before the commit (`tests/full_check.sh`): the patch stubs' general path, the views matrix, FEX's litmus tests
under the protocol and those with translated thread functions (200,000 iterations, no forbidden outcome), up to 64
threads, the workloads with 32 threads. Efficiency with the functions chosen from the profile (best of five, README
table): pigz 90 %, xz 90 %, zstd 69 %, mean 82 %, as with the lists made by hand.

## 27. Other cores in a full system emulation (2026-11-18)

QEMU 10.0 (`qemu-system-arm`, TCG) on the test machine runs Debian 13's arm64 cloud image (kernel 6.12, 4 KB pages,
48-bit addresses) with a chosen core model; cloud-init fetches a payload from the host (FEX built for Armv8.0,
`fex/build_generic.sh`; the threads and litmus tests; pigz with its library for Armv8.0 and for FEAT_LRCPC) and
`tests/vm_guest.sh` writes the results to the console (`tests/vm_run.sh MODEL...`, two to four minutes a model).
Correctness only: emulated cores have no real timing.

| Core model | features of note | threads 8 / 20 | litmus mp, stack, lb | pigz: FEX full TSO / protocol / + translated |
|---|---|---|---|---|
| Cortex-A53 | no LRCPC, no LSE | ok / ok | 0 forbidden | ok / ok / ok |
| Cortex-A72 | no LRCPC, no LSE | ok / ok | 0 forbidden | ok / ok / ok |
| Neoverse N1 | like the A76 | ok / ok | 0 forbidden | ok / ok / ok |
| Cortex-A710 | LRCPC2, LSE2, SVE2 (128-bit) | ok / ok | 0 forbidden | ok / ok / ok |
| Neoverse V1 | LRCPC2, LSE2, SVE (256-bit) | ok / **segmentation fault** | 0 forbidden | ok / ok / ok |
| `max` | everything QEMU knows | crash / crash | glibc assertion | crash / crash / ok |

Open: on the V1 model the test with 20 threads (more than the view slots: the fallback with shared slots) crashed;
the V1 is the only model with 256-bit SVE, which FEX uses for AVX (`FEX_HOSTFEATURES=disablesve` turns it off, for
narrowing it down). On `max` FEX fails without the views as well (FEX's full TSO), so that is FEX or QEMU's model,
not the protocol; to be confirmed with upstream FEX there.

Followed up (`tests/vm_diag.sh`, `tests/vm_stress.sh`, `tests/threads_stress.sh`): on the V1 model the test with 20
threads ran 86 more times without a crash (40 with SVE, 40 without, 6 in the diagnosis), on the Pi 150 times; the one
crash did not come back. On `max`, upstream FEX crashes as well (full TSO, no views: threads, litmus, pigz), and
everything of tso-arm runs with `FEX_HOSTFEATURES=disablesve`: QEMU's `max` has 2048-bit SVE, a vector length FEX does
not handle.

## 28. From prototype to a command (2026-11-18)

- **`bin/tso-arm`**: `run` (modes `tso`, `full`, `unordered`; the learned library used when there is one), `learn`
  (`aot/auto.py` on the user's program and arguments, the library cached under `~/.cache/tso-arm/aot/` by a hash of
  the program file), `status`, `forget`, `check` (`tools/board_check.sh`, now with Capstone's version and the
  installed FEX), `install` (`fex/install.sh`: FEX fetched from its repository, set to the commit the patches apply to,
  patched without commits, built and installed to `~/.local/opt/tso-arm`; `--generic` for any Armv8.0 core),
  `rootfs` (FEX's own fetcher), `version` (`VERSION`, 0.1.0). A dynamically linked program without an x86-64 root file
  system gets told what is missing instead of failing inside FEX.
- **Dynamically linked programs** under the page protocol, for the first time (`tests/dynamic_check.sh`, a minimal
  root file system of glibc's loader and libraries, `tests/mini_rootfs.sh`): pigz, xz and zstd correct, as under
  FEX's full TSO.
- **`aot/auto.py`** profiles with the patched FEX as well (its block names reach perf: `tests/perf_names.sh`, 76 %
  of pigz's samples in named blocks against 78 % with upstream FEX), reads perf's numbers in the C locale and gives
  the program an empty stdin.
- **A ring buffer that relies on x86 order** (`tests/spsc.c`, plain `mov`s, no barriers): 20 million messages under
  FEX on the Pi, 31 arrived wrong without ordering, none with FEX's full TSO or with tso-arm
  (`tests/spsc_check.sh`).
- **CI** on GitHub's Arm runners (`.github/workflows/ci.yml`, `tests/ci.sh`): FEX with the patches built by
  `tso-arm install --generic` (cached by the patches' hash), the x86-64 test programs built with a cross compiler, then
  through `tso-arm run`: struct fields and a shared stack against FEX's full TSO, 8, 16 and 40 threads, the litmus
  tests under the protocol and with translated thread functions, a dynamically linked program with the cross
  compiler's C library as root file system, the ring buffer. The same script on the Pi: all passed.
- **README** rewritten as the project's front page: what it is, the result, a quick start, why the order matters,
  how it works, the measurements, correctness, where it runs, the commands.

## 29. Position-independent programs ahead of time; GitHub's Neoverse N2 (2026-11-19)

Distributions build their programs position-independent (PIE): the loader puts them at an address of its choosing,
and the C code of the translator had the program's addresses written into it. Now:

- **`aot/lift.py`**: in a program of ELF type `DYN` every guest address in the generated C is `aot_base` plus the
  link-time address; the dispatch switches on `t - aot_base`. Words the dynamic loader relocates (`RELA`, `RELR`) are
  not folded into constants, and the read-only table shortcut is off for such programs. The library says
  `aot_pie = 1`; FEX's `LoadAOT` takes the main program's load address from its ELF loader, sets `aot_base` through
  `aot_set_base` and moves the library's entry points by it before it checks their code hashes.
- **Jump tables** of position-independent code hold 32-bit offsets from the table
  (`lea table(%rip), rT; movslq (rT, rI, 4), rX; add rT, rX; jmp *rX`). The translated code branches on the target
  the jump really takes: the targets read from the table become cases, any other value ends in `aot_unreachable`, so
  a wrongly recognised table fails loudly and never runs on silently. A table address loaded once before a loop (xz's
  `rc_encode`) is found through the only rip-relative `lea` into that register. xz as PIE: `rc_encode` and
  `lzma_lzma_encode` translate now; `learn` chooses 13 functions with 98.9 of 99.1 % of the guest cycles (before: 10
  with 85 of 98 %).
- **`aot/auto.py`** finds the direct calls in position-independent C as well (`aot_guest_call(c, (aot_base + ...`).
- **`tso-arm learn`** takes static-pie programs and dynamically linked ones (their own functions; those of their
  libraries stay with FEX).

The workloads built several ways from the same sources (`study/build_pie.sh`), each learned by `tso-arm learn`
(`tests/pie_learn.sh`), through `tso-arm run`, median of 5 at 1.8 GHz, every run started below 60 °C, outputs
checked (`tests/pie_bench.sh`); efficiency against the native build (pigz 993 ms, xz 1096 ms, zstd 501 ms):

| | page protocol alone | with what was learned |
|---|---|---|
| pigz, static, not position-independent | 77 % | 88 % |
| pigz, static-pie | 77 % | 89 % |
| pigz, PIE linked dynamically (as distributions build it) | 75 % | 82 % |
| xz, static, not position-independent | 72 % | 88 % |
| xz, PIE linked dynamically | 69 % | 85 % |
| zstd, static, not position-independent | 68 % | 67 % |
| zstd, PIE linked dynamically | 65 % | 64 % |

(zstd goes on with full ordering either way, section 23; translated functions do not change that.) Position
independence itself costs nothing measurable once translated (static-pie as fast as static). Linked dynamically,
pigz is 7 points and xz 3 behind; such a program differs in two ways that both cost: the C library's string functions, which the
static builds carry and `learn` translates with them, lie in `libc.so` there and stay with FEX, and the dynamic
loader's start-up (loading and relocating the libraries of the root file system) comes on top. Translating shared
libraries ahead of time is the next step for such programs.

For the static programs the translator writes the same C as before (only the declarations of `aot_base` added);
`tests/full_check.sh` after the change: libraries, outputs and the stubs' general path, the views matrix, both litmus
series (0 forbidden), 12 to 64 threads, all correct; the efficiency table unchanged within the noise (pigz 91, xz 89,
zstd 68 %, mean 82 %).

**GitHub's Arm runner** (`ubuntu-24.04-arm`, the CI): a Neoverse N2 with 4 cores, 48-bit virtual addresses,
FEAT_LRCPC2 and LSE2, Ubuntu 24.04 (Capstone 4 packaged, 5 from pip). The first run of `tests/ci.sh` there passed
everything (4 min 53 s with FEX built). The ring buffer without ordering: 507 of 20 million messages wrong there,
against 31 on the Pi; with tso-arm none. `tests/ci_bench.sh` measures the efficiency on the runner itself (pigz, xz
and zstd built from their official sources natively and with an x86-64 cross compiler, a 64 MB corpus of the
machine's own files, `tso-arm learn` for each) and writes the table into the run's summary.

## 30. Where the dynamically linked build loses; FEX upstream; GitHub's N2 measured (2026-11-19)

- **The 4 to 7 points between static-pie and dynamically linked** (section 29) are not the C library's code: of pigz's
  guest cycles 1.7 % lie in `libc.so.6`, of xz's 0.07 % (perf by DSO, FEX naming its blocks). At the default clock,
  learned: static-pie 864 ms, linked dynamically 899 ms; FEX's JIT share 3.6 against 7.2 % of the cycles, the
  difference mostly `memmove` and `memset`, which the static builds carry and `learn` translates, and the start-up of
  the dynamic loader. Translating shared libraries ahead of time would win 1 to 2 points here; not done for now. (The
  libc of the root file system has no symbol table; its function bounds would come from `.eh_frame`.)
- **FEX upstream** is still at the commit the patches apply to (`be66e03`, 2026-11-17). `.github/workflows/upstream.yml`
  builds the patches on FEX's newest commit every week and runs `tests/ci.sh` there (`fex/install.sh` takes
  `TSO_ARM_FEX_REF`), so a change in FEX that the patches have to follow shows within a week.
- **The cache key** of a learned library is the program's build ID (`readelf -n`) instead of a SHA-256 of the whole
  file at every start; a program without one still gets the hash. FEX checks every translated function against the
  program's code before using it either way. `readelf` runs in the C locale (its output is translated otherwise).
- **GitHub's Neoverse N2** (`tests/ci_bench.sh`, second CI run, best of 3, pigz on 256 MB, xz on 64 MB, zstd on
  256 MB):

| N2 | native | FEX, TSO off | FEX full TSO | page protocol | + learned | learned, TSO off |
|---|---|---|---|---|---|---|
| pigz | 1371 ms | 88 % | 69 % | 75 % | 83 % | 93 % |
| xz | 3732 ms | 82 % | 72 % | 74 % | 78 % | 80 % |
| zstd | 343 ms | 66 % | 48 % | 48 % | 47 % | 63 % |

Ordering costs FEX about as much on the N2 as on the A76 (pigz 88 to 69 %), and tso-arm takes most of it back for
pigz (83 %). Open: xz's translated code is no faster than FEX's own there (80 against 82 % without ordering), where on
the Pi it is (93 against 79 %); the CI now logs what `learn` chose. zstd's run was too short (0.34 s, mostly the
start); it compresses 1 GB now (the same file four times on one command line made native zstd slower than FEX: 2.26 s
native, 144 % for FEX without ordering, so one file it is).

## 31. A host address taken for a guest one on 48-bit hosts (2026-11-19)

On the N2, `tso-arm learn` left `ZSTD_compressBlock_doubleFast` out of zstd's library twice: with it, zstd's output
under the page protocol differed from the run without the library; without ordering it was right. On the Pi the same
function was right every time (30 runs), also from the runner's own zstd binary, and also compiled by clang 18 (the
runner's) instead of 19: not the translator, not the compiler, but the machine.

The cause: a plain access of translated code that meets a shared page is patched into a stub (section 26), and the
stub tells guest from host memory by bit 38 of the address. The plain views lie below 2^38, the ordered views and
everything of the host above; with 39-bit addresses (the Pi) every host address has bit 38 set. With 48 bits it need
not: host thread stacks lie at 0xffff8... to 0xffffb..., where bit 38 is clear, so a patched instruction that also
reaches a stack object in host memory (the translated code keeps some there) had bit 38 set on a host address and
went to a wrong one. The test is now the whole condition, address at or above 2^38: with at most 40 address bits (an
`mmap` at 2^40 fails with `ENOMEM`) still the one `tbnz` on bit 38, otherwise `lsr` by 38 into the register that
held the address, `cbnz`, and the address computed again (no flags touched, two to three more instructions on that
path). `TSO_AOT_WIDE=1` forces the second form; on the Pi with it: the runner's zstd with the function 8 of 8
correct, `aot/stub_check.sh` (outputs, the stubs' general path, both litmus series) all correct.

On the N2 afterwards (CI): `learn` keeps the function (zstd 14 functions, none left out), all tests passed. The
runner's table with zstd on one 1 GB file (`-T1`/`-T4` natively 4185/1257 ms, under FEX 4861/1558 ms: the threads
work in both) and the bound search of section 30 in effect:

| N2 | native | FEX, TSO off | FEX full TSO | page protocol | + learned | learned, TSO off |
|---|---|---|---|---|---|---|
| pigz | 1448 ms | 89 % | 72 % | 76 % | 84 % | 92 % |
| xz | 3533 ms | 81 % | 71 % | 73 % | 93 % | 91 % |
| zstd | 1484 ms | 86 % | 52 % | 52 % | 47 % | 88 % |

With x86 order kept tso-arm is 12 (pigz) and 22 (xz) points ahead of FEX's full TSO there; zstd goes on with full
ordering as on the Pi (section 23), and its translated functions, all ordered then, are slower than FEX's own code
on the N2 (47 against 52 %; on the Pi equal, 69 against 68 %). On the Pi the full check after the change: all correct,
the table within the noise (pigz 90, xz 90, zstd 70 %, mean 83 %).

## 32. Release 0.1.0: a prebuilt FEX; ordered accesses with an offset (2026-11-20)

- **The packages.** `.github/workflows/release.yml` builds FEX with the patches on `ubuntu-22.04-arm` (glibc 2.35,
  clang 14) for any Armv8.0 core (`fex/install.sh --generic`: `TUNE_CPU=none`, `armv8-a`), packs it with
  `tools/package.sh` (`bin`, `share`, `BUILD`, the licenses of FEX and of its external parts) and checks the packages on
  `ubuntu-22.04-arm` and `ubuntu-24.04-arm`: install from the package, `tso-arm check`, `tests/ci.sh`, `uninstall`. A
  tag `v*` whose name is not `VERSION` stops the run; otherwise it drafts the release with the notes of that version
  from `CHANGELOG.md`, and the draft is published by hand. Two packages: `tso-arm-0.1.0-linux-arm64.tar.gz` (the
  repository at the tag, with the FEX in `fex/prebuilt`, 3.4 MB) and `tso-arm-fex-0.1.0-linux-arm64.tar.gz` (FEX
  alone, 3.1 MB), with `SHA256SUMS`.
- **Which FEX `install` takes.** FEX's binary links FEXCore statically, needs only libstdc++, libm, libgcc_s and libc,
  and finds FEXServer beside itself; the prefix it was built for is only where FEX looks for its AppConfig files, which
  tso-arm does not use. `BUILD` in the prefix names the patches (the first 16 hex digits of a SHA-256 over
  `fex/patches/*tso-arm-stage*.patch`), FEX's commit and how it was built. `install` takes, in this order,
  `TSO_ARM_PACKAGE`, `fex/prebuilt` of the release package, the package of the release named by `VERSION` (checked
  against `SHA256SUMS`), each only if its patches are exactly these; otherwise it builds from source for this core.
  `--source` builds for this core, `--generic` for any. From the package it takes 0.02 s on the Pi. After the release
  was published, on the Pi: a clone of the tag fetched the package from the release, the release's tarball (checked
  against `SHA256SUMS`) took its `fex/prebuilt`; both FEX the same to the byte, `tso-arm check` content with them.
  `tools/release_notes.sh` joins the lines of each paragraph of the version's notes, since GitHub shows every line
  break of a release text.
- **Prebuilt against built for the core,** on the Pi (3 rounds, learned, x86 order kept): pigz 89 against 91 %, xz 93
  against 91 %, zstd 68 against 69 %, mean 82 against 83 %, within the noise. FEX's JIT emits code for the core it runs
  on either way; only FEX's own C++ is built for Armv8.0, and that is not where the time goes.
- **LDAPUR and STLUR.** On cores with FEAT_LRCPC2 (`ilrcpc` in `/proc/cpuinfo`: Neoverse N2 and V1, Cortex-A710 and
  later) an ordered access with an offset is one instruction (`ldapur x0, [x1, #16]`) instead of an `add` and an
  `ldapr`. FEX's own code uses them there; the translated code did not, because clang leaves the feature out of
  `-march=armv8.2-a+rcpc` and does not accept `+rcpc-immo` in `-march`. `aot/build.sh` now passes it with
  `-Xclang -target-feature -Xclang +rcpc-immo` where the core has it. The patch's access decoder already knew both
  forms. On the Pi (no LRCPC2) the code stays as it was.

On the N2, two CI runs the same evening, without and with (not the same machine each time: xz natively 3802 against
3608 ms); all tests passed with it, the litmus tests with translated functions included:

| N2 | native | FEX, TSO off | FEX full TSO | page protocol | + learned | learned, TSO off |
|---|---|---|---|---|---|---|
| pigz, without | 1445 ms | 89 % | 74 % | 79 % | 84 % | 89 % |
| pigz, with | 1446 ms | 90 % | 71 % | 77 % | 85 % | 94 % |
| xz, without | 3802 ms | 85 % | 71 % | 76 % | 95 % | 97 % |
| xz, with | 3608 ms | 82 % | 70 % | 76 % | 90 % | 91 % |
| zstd, without | 1602 ms | 100 % | 56 % | 53 % | 51 % | 97 % |
| zstd, with | 1470 ms | 88 % | 51 % | 55 % | 50 % | 93 % |

zstd's translated code was 5 points behind FEX's full TSO without and is 1 point behind with. But the page protocol and
FEX's full TSO, which end in the same full ordering for zstd (section 23), differ by up to 4 points within one run: the
runner's spread is as large as the effect, so it is not shown. Telling it apart needs both variants in the same job,
on the same machine: `AOT_NOIMMO=1` builds the translated code without the offsets (`AOT_NORCPC=1` would take LDAPR
away as well), and `tests/ci_bench.sh` measures both in alternating rounds on cores with LRCPC2.

## 33. Unaligned ordered accesses; GitHub's runners are not one machine; learn keeps only what is faster (2026-11-20)

**Not one machine.** One CI run of the evening ran on a Neoverse V3 (`lscpu`), the others on N2s: two CI runs may
compare two machines. What `tests/ci_bench.sh` compares now runs in one job, in alternating rounds. On the V3
(`Neoverse-V3`, 4 cores):

| V3 | native | FEX, TSO off | FEX full TSO | page protocol | + learned | learned, TSO off |
|---|---|---|---|---|---|---|
| pigz | 1408 ms | 92 % | 70 % | 76 % | 76 % | 94 % |
| xz | 2659 ms | 85 % | 68 % | 77 % | 96 % | 99 % |
| zstd | 1560 ms | 171 % | 72 % | 67 % | 41 % | 179 % |

Native zstd there is slower than zstd under FEX without ordering (171 %; its threads, as on the N2 in section 31,
only more so), which makes zstd's percentages on that machine say little; the order among the columns still holds.

**Offsets, alternating on one machine** (with `ldapur`/`stlur` against `AOT_NOIMMO=1`): on the N2 pigz 85 against 83 %,
xz 94 against 95 %, zstd 51 against 45 %; on the V3 pigz 83 against 77 %, xz 99 against 97 %, zstd 38 against 38 %.

**Unaligned ordered accesses within 16 bytes.** An x86 access at an unaligned address became `ldr` and `dmb ishld` in
the ordered variant (a store `dmb ish` and `str`), because `ldapr` and `stlr` fault on unaligned addresses. With
FEAT_LSE2 they need not within an aligned 16 bytes, if the kernel sets SCTLR_EL1.nAA. `aot/unaligned_probe.c` tries an
8-byte `ldapr` (`ldar` without LRCPC) and `stlr` at offset 3 and at offset 12 of an aligned buffer, a SIGBUS meaning
no; `aot/build.sh` compiles with `AOT_U16` where the first works, and the translated code then uses `ldapr`/`stlr` for
an unaligned access that stays within 16 bytes (`(a & 15) + size <= 16`) and keeps the barrier only across them.
`AOT_NOU16=1` leaves it out; `tso-arm check` shows what the probe finds. On the N2 runner it works (the kernel sets
nAA); on the Pi (no LSE2) the probe says no and zstd's library came out the same to the instruction (41,067). The
litmus tests with translated functions passed on the N2 with it. Alternating there, the learned code as built, without
the offsets, without the unaligned accesses:

| N2 | as built | without offsets | without unaligned |
|---|---|---|---|
| pigz | 84 % | 79 % | 81 % |
| xz | 93 % | 94 % | 93 % |
| zstd | 48 % | 43 % | 46 % |

FEX does the same in its own way: its JIT uses `ldapur` for every ordered load, and a site that faults on an unaligned
address is rewritten once into a load and a barrier (`HandleUnalignedAccess`, the half barrier); on a kernel with nAA
it does not fault within 16 bytes.

**What remains on these cores:** zstd's translated functions, all ordered when zstd falls back to full ordering
(section 23), are slower than FEX's own code there: 42 to 48 % against 52 % on the N2, 41 against 72 % on the V3; on
the Pi equal (69 against 68 %). Neither the offsets nor the unaligned accesses close it; where the rest goes would take
a profile on such a machine.

**So `learn` measures before it keeps.** After the output check, `tso-arm learn` (`aot/auto.py --timed`) runs the
program as `tso-arm run` runs it, with x86 order kept, once to warm up and then with the library and without in
alternating rounds (`TSO_ARM_LEARN_ROUNDS`, default 3, best of each). A library that makes the program more than 3 %
slower on this machine becomes `OUT.so.slower`: `tso-arm run` goes without it, `tso-arm status` says so, `forget`
removes it, and the next `learn` decides again. On the Pi: pigz 868 ms with, 1017 ms without, kept; zstd 666 against
669 ms, kept. The test chain (`aot/auto.sh`, `bench/efficiency.sh`) builds its libraries without the step.

Found on the way: `aot/auto.py` took the program's arguments with argparse's `REMAINDER`, which also swallowed an
option of its own after the two paths; `--timed` went to pigz, which ended at once with an error, and since the run
without the library ended the same way, the output check passed with an empty profile and "1 function" (an empty
list counted as a line). The program's arguments are now what follows `--`; `learn` first runs the program once and
stops with its exit status if it fails (exit status 22 for an unknown option of pigz); nothing chosen leaves no
library and says so.

On the N2 afterwards (CI): pigz 1676 ms with its library, 1819 ms without, kept; xz 3879 against 4875 ms, kept;
zstd 2983 against 2473 ms, left out, so `tso-arm run` gives zstd the page protocol's 83 % there instead of less.

## 34. Where the translated code loses on the N2; the host-object test as a mask (2026-11-20)

`tests/ci_profile.sh` (on demand on GitHub: `.github/workflows/profile.yml`) runs a workload as `tso-arm run` runs it,
with its translated functions and with FEX's own code alone, and compares cycles per guest function
(`tools/perf_guest.py` maps FEX's named blocks back to the guest's functions). zstd, x86 order kept (fallback):

| zstd | cycles | instructions | per cycle | `ZSTD_compressBlock_doubleFast`, cycles |
|---|---|---|---|---|
| Pi, translated + FEX | 4.64 billion | 4.20 billion | 0.91 | 3265 million |
| Pi, FEX alone | 4.53 billion | 3.42 billion | 0.76 | 3041 million |
| N2, translated + FEX | 36.2 billion | 63.9 billion | 1.77 | 27.7 billion |
| N2, FEX alone | 28.6 billion | 42.7 billion | 1.49 | 21.0 billion |

(The N2 run's input is 1 GB, the Pi's 100 MB.) The translated code executes 23 % (Pi) and 50 % (N2, with the checks
of the unaligned path as well) more instructions than FEX's code for the same work: before every ordered access it
tests for a stack object in host memory (`cmp O, V`, `b.eq`, `lsr #34`, `cbnz`) and for alignment (`tst`, `b.ne`);
FEX's code has neither and lets an unaligned access fault once instead (section 33). On the A76 the higher rate of
instructions per cycle hides most of it; on the N2 it does not. The hottest instructions on the Pi are the one after
the hash table's load (its cache miss, which FEX's code pays as well) and the barriers after unaligned reads of the
input; on the N2 the `cmp` of O and V.

**The host-object test as a mask.** `O != V` holds or not for a whole function, so the test is now `a & H`, with
`H = O != V ? ~(2^34 - 1) : 0` computed once per function and held in a register through an empty `asm` (otherwise
clang folds it back into the comparison per access): one `tst` and one branch per access instead of four
instructions. The libraries become 3 to 6 % shorter (zstd 34,416 instructions to 32,450, xz 29,824 to 28,156, pigz
25,958 to 25,167). On the Pi, alternating (`aot/ab_env.sh`, 8 runs each): zstd best 727 to 726 ms, 3.95 to 3.91
billion user cycles; pigz 1122 to 1119 ms; xz 1212 to 1208 ms, all within the noise. Testing alignment in the same
`tst` (`a & (H | size - 1)`) made the code longer again (the slow path tests the host case a second time), so not.
Full check on the Pi with the mask: libraries, stubs' general path, views matrix, both litmus series, 64 threads,
the CI tests, all correct; efficiency pigz 90, xz 89, zstd 70 %, mean 83 % (README table).

**Addresses through vector registers.** The escape analysis (which stack objects may stay in host memory) followed
addresses through 64-bit registers only: a pointer moved through an xmm register (compilers do so with pairs of
pointers) lost its taint, and a store of it to guest memory would not have counted as an escape, leaving a host
address where guest code could find it. Vector registers carry the taint now. For pigz, xz and zstd the translated C
comes out the same to the byte (`lift.py`'s classification of every function unchanged); it matters for programs
that do this.

## 35. Programs of a distribution (2026-11-20)

pigz, xz and zstd say little about programs with JIT compilers, hand-written SIMD, thread pools and interpreters.
`tools/compat_rootfs.sh` takes programs from an x86-64 machine (here WSL with Ubuntu 26.04: glibc 2.43, Python
3.14, Node 22, ffmpeg with libx264, 7-Zip 26, the Rust coreutils' sort) with every library `ldd` names for them and
for Python's extension modules, the dynamic loader, Python's standard library, the files they load themselves that
`ldd` does not show (7-Zip's codecs in `7z.so` beside its binary, the JavaScript Ubuntu's Node keeps outside
`libnode`, found as paths in its strings), symbolic links resolved; 226 paths, 419 MB, 144 MB packed. Nothing is
installed. `tests/compat.sh` unpacks it on the Arm machine, sets `FEX_ROOTFS` and runs each program with x86 order
kept, with FEX's full TSO and without ordering, outputs compared (`--here` runs them twice natively on the x86
machine: all outputs fixed there). The work: sort of 2 million lines with `--parallel=4`, 7-Zip compressing 64 MB
to xz with 4 threads (at `-mx=5` that input became one block and one thread), 16 Python threads hashing (hashlib
leaves the interpreter lock) and a producer/consumer queue, ffmpeg encoding 4 s of `testsrc2` with x264 on 4 threads
(the md5 of its packets), and Node: 4 worker threads summing over a SharedArrayBuffer, then message passing through
one with plain stores (`a[0] = i; a[256] = i` in the worker, `Atomics.load` of the flag and a plain load of the data
in the main thread, a message wrong when the data is older than the flag).

On the Pi 5 (best of 3, default clock) everything is in the README; in short: the outputs agree in all modes; tso-arm
is as fast as FEX's full TSO or faster (sort 2092 against 2838 ms, Node 8183 against 8682 ms, the others within 4 %),
and the messages: 0 wrong with tso-arm, 0 with FEX's full TSO, 113,884 of 3 million without ordering. So tso-arm keeps
x86's order in code that V8 compiles at run time as well: those pages are shared between the worker and the main
thread, the protocol orders them.

The first run of each program is slower under tso-arm (ffmpeg 5.8 s against 2.9 s): the page protocol learns which
pages the threads share and keeps that for the next run (section 12). Things found on the way, in the tests
themselves: 7-Zip's codecs and Node's externalized builtins missing from the first root file system, and the script
first running the x86 programs without FEX.

`.github/workflows/compat.yml` does the same on every push: an x86-64 runner packs the programs of its Ubuntu 24.04
(Node 18, ffmpeg 6, p7zip 16, GNU sort), an Arm runner runs them. The programs come from `/usr/bin` only: GitHub's
image has a Node of its own in `/usr/local/bin`, which the first run packed instead.

**First runs and the fallback.** ffmpeg's first run (`tso-arm run --stats`): 4884 faults handled in 0.70 s, 3888
escalations, each throwing away translated code that FEX compiles again (7721 block compiles in 5.4 s over all
threads: x264's hand-written SIMD makes large blocks), fallback to full ordering only after 3.6 s, since the faults
came at about 1350 per second, under the budget of 5000. First runs of everything (`TSO_VIEWS_PROFILE=none`, one run
each, default clock), with the budget and window that the knobs allow:

| first run | FEX full TSO | 5000/s over 1000 faults (default) | 2000/s | 1000/s | 1000/s over 300 faults |
|---|---|---|---|---|---|
| pigz | 1302 ms | 1135 ms | 1092 ms | 1100 ms | 1073 ms (falls back at 1.05 s) |
| xz | 1233 ms | 1330 ms | 1281 ms | 1340 ms | 1281 ms |
| zstd | 692 ms | 798 ms (0.36 s) | 815 ms | 827 ms | 812 ms |
| sort | 2052 ms | 2305 ms (0.57 s) | 2270 ms | 2263 ms | 2264 ms |
| 7-Zip | 3379 ms | 3485 ms (3.45 s) | 3431 ms | 3503 ms | 3477 ms |
| Python | 2928 ms | 3218 ms (0.64 s) | 3289 ms | 3255 ms | 3150 ms |
| ffmpeg | 2949 ms | 5679 ms (3.58 s) | 4411 ms | 4363 ms | 3993 ms (1.74 s) |
| Node | 8549 ms | 7955 ms (0.51 s) | 9289 ms | 8183 ms | 9014 ms |

A tighter budget gives ffmpeg's first run back 1.7 s but makes pigz fall back near its end, which on a longer
input would leave most of it at full ordering (60 instead of 90 %); escalations per second do not tell the two apart
either (pigz about 1800, ffmpeg about 1100). Left as it was: the profile keeps the fallback, and from the second run
on ffmpeg is as fast as under FEX's full TSO (2964 and 2937 ms). A rule by cost (the time recompiling code thrown
away, against the time run) would tell them apart; open.

## 36. Translating programs as distributions build them (2026-11-20)

`learn` on the distribution's own programs (section 35) translated nothing: they are stripped, so no function was
found at all (`aot/elfsyms.py`, section 35's commit, takes the bounds from `.eh_frame` then). With that, Python's
profile showed why the translator still took none of its hot functions; the reasons, and what the translator does
about each now:

- **Frame pointers** (Ubuntu builds with them since 24.04, Fedora since 38): `push rbp; mov rbp, rsp` ... `leave` or
  `lea rsp, [rbp - k]`. The analysis follows rbp's offset from the entry rsp beside rsp's own (`fpd` beside `delta`),
  from `mov rbp, rsp` until rbp is written otherwise; an access through rbp is then a stack access at that offset
  (frame slot, argument or object, as through rsp, also in the escape analysis), `leave`, `mov rsp, rbp` and
  `lea rsp, [rbp + k]` set rsp's offset, and rbp's value is the guest stack address it stands for (`gsp + offset`),
  which code that only saves and restores it sees right. rbp read as a value otherwise, rsp read as a value, and
  `enter` are refused (they gave C that did not compile before). `lea rbp, [rsp + k]` stays the address of a stack
  object, as code without frame pointers uses it.
- **Cold parts**: gcc moves rarely run paths into a part of their own (`foo.cold` in `.text.unlikely`), reached by
  jumps from the function and running in its frame. A jump into one was "conditional jump out of the function". Such
  parts are found as symbols named `*.cold*` or, stripped, as FDEs whose first row does not have the CFA at rsp + 8 as
  at a function's entry (they start inside the frame); the function decodes the parts it jumps into with it, and
  jumps between them are internal. Between regions nothing falls through (the analysis stops there, the C gets an
  `aot_unreachable` at each gap and a `goto` to the entry when a part lies before it).
- **Thread-local storage** (`fs:`): the stack protector's canary at `fs:0x28` (`-fstack-protector-strong`, the
  default of distributions) and errno; guest memory at the thread's fs base, which FEX already gave the translated
  code in its context (`c->fs_base`).
- **Calls of guest functions too irregular to tell their stack arguments** (indirect jumps): they made the caller
  fail. Now every frame slot between the call's stack pointer and the entry's goes to the guest stack (this
  function's own part of it), which holds any stack arguments.

Python then translated 40 functions, and `learn`'s output check found the output wrong with all of them but right with
each alone. `aotmin.py` (scratch: functions removed one by one while the output stays wrong, 41 builds) narrowed it to
`PyDict_SetItem` and `PyType_Ready`, which do not call each other: both end in a tail call into guest code after
`leave`. A tail call passed `gsp`, the function's entry, as the callee's stack pointer, and FEX's callback path writes
its return address where the callee starts. When translated code is entered from guest code that translated code
had called, FEX runs it on that very stack (`Bridge`: `Stack = RSP`), and at `gsp` lies the return address into
that guest code; `PyType_Ready` tail-called guest code that called `PyDict_SetItem`, whose tail call overwrote it.
Tail calls now pass `gsp - 16` (the same alignment; their stack arguments never come through `gsp`). pigz's and xz's
libraries hold such tail calls (6 and 2), so this was wrong there as well, only never met.

After that (on the Pi, `tso-arm learn`, outputs checked, times as `tso-arm run`):

| | functions | left with FEX among the hot ones | with the library | without |
|---|---|---|---|---|
| pigz, built as distributions build (frame pointers, stack protector, cold parts) | 23 | 0 | 918 ms | 1019 ms |
| xz, the same | 15 | 0 | 1122 ms | 1372 ms |
| zstd, the same | 15 | 2 | 668 ms | 718 ms |
| Python 3.14 of Ubuntu 26.04 | 40 (8 % of its cycles) | 16 | 4973 ms | 2870 ms |
| sort of Ubuntu 26.04 (Rust) | 18 of 25 | 9 | 10198 ms | 2070 ms |

The programs built the distributions' way translate fully now; before, nearly every function there stopped at a
frame pointer, a cold part or the canary. Python's and sort's libraries are slower than none: little of their time
is in their own translated code, and with a library FEX runs block by block (`FEX_MULTIBLOCK=0`), which alone costs
Python 56 % (2908 against 4624 ms without a library) and sort 14 %. `learn` now times the library with multiblock on
as well and keeps that when it is faster (`OUT.multiblock`, which `tso-arm run` follows). sort's 7 functions left out
return a pair in `rax:rdx` (Rust's slices): translated functions return rax only, so the caller saw a stale rdx;
`learn`'s check caught each of them.

With multiblock as a third choice: Python 5026 ms with the library, 3673 ms with it and multiblock, 2869 ms without,
so still left out (its eval loop stays with FEX and calls the small translated functions all the time; each call goes
through the bridge into the host code and back); pigz built the distributions' way 869, 868 and 1016 ms, kept
without multiblock. Full check on the Pi with all of this (pigz's and xz's libraries changed by the tail calls):
libraries, the stubs' general path, views matrix, both litmus series, 64 threads, the CI tests, all correct;
efficiency pigz 91, xz 89, zstd 70 %, mean 83 % (README table).

## 37. rdx as a second return register (2026-11-20)

x86-64 returns 16-byte results in rax and rdx: Rust's slices (pointer and length), `Option<usize>`, C++'s pairs. A
translated function returned rax only, and the bridge set only the guest's rax; a guest call gave back rax only as
well. sort's 7 functions left out in section 36 all end in `mov rdx, ...; ret`.

First through the context: a field `rdx` at the end of `aot_ctx`, stored before every return and loaded after every
call, set from and into the guest's rdx by the bridge and `GuestCall`. Right (sort learned all 25 functions with the
right output; the CI tests and the full check passed), but it cost, alternating on the Pi (8 runs each, the same FEX):
xz best 1223 against 1235 ms, median 1231 against 1250 ms, 1.6 % more user cycles; pigz 0.6 %; zstd nothing; the
efficiency table came out at 82 instead of 83 %.

So the pair is returned instead: every translated function, `aot_guest_call` and the bridge's entry return
`struct aot_rr {rax, rdx}`, which AArch64 returns in x0 and x1, without memory; a call takes both
(`{ struct aot_rr r = f(...); rax = r.rax; rdx = r.rdx; }`, clang drops what is not read), a return gives both, a
tail call passes the callee's on. FEX's side (the stage-3 patch, `Thunks.cpp`): `Fn` and `GuestCall` return the pair,
the bridge sets the guest's rax and rdx from it. The interface has a number now, `aot_abi` in every library
(`AOT_ABI` = 2 in `aot/aot.h`): FEX does not use a library without it or with another one, it says so and runs the
program without, since a library of the old interface returns rax alone and would leave rdx undefined. `learn` then
translates it again. And `tso-arm` refuses an installed FEX whose `BUILD` names other patches than the checkout's
(`tso-arm install` updates it); the prebuilt FEX of 0.1.0 is such a one now, so a checkout of `main` builds FEX from
source until the next release brings it prebuilt.

On the Pi with both FEX builds made anew (patches `771e78d95e10f3ef`): the CI tests all passed, sort learns all 25
functions with the right output (its library stays slower than none, 12.9 against 2.2 s: its translated functions
call back into FEX for every comparison). Against the code without rdx, alternating (8 runs each): xz best 1229
against 1229 ms, 0.5 % more user cycles; pigz 1142 against 1138 ms, 1 %; zstd 754 against 725 ms; so the pair costs
next to nothing. Full check all correct; efficiency pigz 90, xz 88, zstd 70 %, mean 82 % (README table; xz's 1.21
against 1.19 s of the last table is the spread of single sessions, as the alternating runs show).

## 38. Release 0.2.0; what a call across the border costs (2026-11-20)

Release 0.2.0 (tag `v0.2.0` on `01e83d8`): the release workflow built FEX for any Armv8.0 core and checked the
packages on Ubuntu 22.04 and 24.04; published, then on the Pi: a clone of the tag fetched the prebuilt FEX, the
release's tarball (checked against `SHA256SUMS`) took its own, both the same to the byte (patches
`771e78d95e10f3ef`); `tso-arm learn` with it kept pigz's library (868 ms against 968 ms without) and `tso-arm run` gave
the right output.

Why Python's and sort's libraries are slower than none (section 36): `tests/transitions.c` calls a small function
10 million times across the border, `tests/transitions.sh` measures it (FEX without ordering, block by block, best of
3, on the Pi): guest code calling a translated function costs 40 ns more per call than FEX's own call (1075 against
1480 ms; the bridge: FEX's thunk call, the context, the arguments, the return through the guest stack), translated
code calling guest code through a pointer 81 ns more (1180 against 1995 ms; FEX's callback path into its dispatcher and
out again). Python's eval loop stays with FEX (computed gotos) and calls its small translated functions all the
time; sort's translated functions call back into FEX for each comparison (Rust closures through pointers). Making
these crossings cheap would take FEX's JIT calling translated code directly, or translating whole call graphs with
their indirect targets; `learn` already keeps such libraries out.

**Started directly** (`tso-arm binfmt`): `sudo tso-arm binfmt register` registers `bin/tso-arm-binfmt` with
binfmt_misc for x86-64 executables and position-independent ones (qemu-user's magic and mask) and in
`/etc/binfmt.d`; the interpreter hands the program to `tso-arm run`. The CI registers it on its runner, starts an
x86-64 test program directly and checks that it no longer starts once unregistered.

**`tso-arm rootfs` as a user meets it**, in a HOME of its own on the Pi: FEX's fetcher took 95 s for Ubuntu 24.04 from
FEX's server (1.9 GB extracted) and set it as FEX's root file system, in `~/.config/fex-emu/Config.json`. `tso-arm`
looked for that setting in `~/.fex-emu/Config.json` only, where FEX keeps it just when that directory exists, and so
refused every dynamically linked program right after `tso-arm rootfs` had fetched one. It reads it where FEX does now
(`FEX_APP_CONFIG_LOCATION`, else `~/.fex-emu` if it exists, else `$XDG_CONFIG_HOME/fex-emu`, and the installed FEX's own
configuration). Then x86-64 `bash`, `python3` and `sort` of that root file system ran, and `sort --parallel=4` of 2
million lines gave the same output as the Arm `sort`.

**Profiles of programs from a root file system.** On GitHub's N2, ffmpeg and Node stayed slower under tso-arm than
under FEX's full TSO even at their best of three rounds (2.8 against 1.7 s, 6.1 against 4.3 s): with `--stats` after
the rounds, both escalated anew in every run (1920 escalations, fallback after 1.4 and 0.3 s) instead of starting in
the fallback their profile records; on the Pi Node did the same. Node left no profile at all (strace: nothing under
`~/.cache/tso-arm`). FEX gives a program of the root file system its guest path as its name (`/usr/bin/node`, as the
program sees itself), and the profile's name came from a `stat` of that path on the host: no such file, no profile.
Python's and the Pi's ffmpeg had one only because the Pi has an Arm `python3` and `ffmpeg` at those paths, so the
profile was bound to another program's file; GitHub's runner has no ffmpeg. The profile now takes size and time from
the file in the root file system when there is one there, and keeps the guest path as its name (which stays the same
when the root file system is mounted elsewhere). On the Pi: Node's second run started in the fallback (8829 against
9762 ms), and after the compat rounds no program escalated any more; the CI tests passed.

## 39. fork without exec (2026-11-20)

A program that forks and goes on running in the child (bash's `$(...)`, shell scripts, `make`, Python's
multiprocessing) broke under the page protocol: `tests/fork.c` (the child writes a global, the heap, a 4 MB buffer
and the stack, then exits) ended with the child killed by SIGSEGV, under gdb with glibc's "stack smashing detected".
Memory that is private for the guest is shared memory here (`MAP_SHARED | MAP_ANONYMOUS` at its guest address, one
object mapped again into the views with `mremap` of size 0), and a fork keeps shared memory shared: parent and child
ran on one stack. The kernel's copy-on-write needs private mappings, and the views need shared ones, so the child
has to copy.

What FEX does now (`TSOViewMemory::AfterForkChild`, `AfterForkParent`, `Unshare`):

- The views' lock is held across the fork (`SyscallHandler::LockBeforeFork`), so the child finds consistent tables;
  the child starts the lock over, as the only thread.
- The parent waits until the child has its copy (a pipe: the child writes a byte when done, or dies and closes it).
  The first version copied in the child while the parent ran on: the child copied the parent's later writes (the
  stack frames of its `waitpid` over the child's own, so glibc's stack check fired; a lock word the parent had taken
  again after the fork, so the child waited on it forever). The thread that forked waits inside the system call,
  with glibc's fork locks still held, and the views' lock keeps the other threads' faults waiting; other threads that
  run on their own pages are not stopped, so a child forked from a process with threads may copy a structure another
  thread changes while it copies (POSIX allows such a child only async-signal-safe calls until it calls execve).
- In the child, the views of the threads that did not come along go back to reservations, and every private page
  becomes the forking thread's (plain accesses, a single thread), unless the process already runs fully ordered.
- Each writable private range gets a new shared memory object with its contents; the copy is moved onto the guest
  address with `mremap` and aliased into the thread's two views again. Only pages that hold something are copied:
  `mincore` gives the pages in memory (for shared memory it looks at the object, so pages touched only through a
  view count). Pages of shared memory in swap have no page table entry and are not in the page cache, which
  `mincore` does not see; with swap in use on the system, `/proc/self/smaps` names the guest mappings with pages in
  swap, and every nonzero page of those is copied. The child does no allocations for this (its allocators' locks
  may be held by threads it does not have).
- Ranges the guest cannot write stay shared between parent and child (program code and read-only data: most of a
  large program's memory, never copied in a fork followed by exec). Both sides mark them; the first `mprotect` that
  makes one writable, and `MADV_DONTNEED` on one (which removes pages of shared memory for everyone), copy it first.
- Translations of code in copied writable executable ranges are dropped in the child: FEX write-protects pages it
  translated code from, and that protection is not carried over to the copy.
- Memory the guest mapped shared stays shared, as in a fork. A vfork child (and `posix_spawn`, which FEX runs as a
  fork whose parent waits) runs on its parent's memory until it calls execve or exits, which is what vfork means;
  with that, `posix_spawn` of a program that does not exist reports the error in the parent as it should (under
  FEX's own memory it reports success: the child's write of the error is lost).

`tests/fork.c` checks that the child sees what the parent wrote before the fork and keeps its own writes, with and
without other threads running (the child starts a thread of its own as well), that memory mapped shared stays
shared, that read-only memory made writable after the fork stays separate on either side, vfork, and the time per
fork. On the Pi: 2.8 ms per fork and wait under tso-arm against 1.8 ms under FEX's full ordering; the child of the
test copies 76 KB in 8 ranges in about 1 ms, and one with a 4 MB heap buffer 4.1 MB in 3.7 ms. The first version
took 3.7 ms: `strace -c` showed every child rewriting the parent's profile at its exit (the parent's unsaved changes
came along; the child now writes only what it learns itself), and the child recomputing the views' rights of a
128 MB reservation without any rights, page by page. What remains is mostly the child's first touch of its new
pages, in guest memory and in its views, where a fork's copy-on-write keeps the parent's page tables. A program
with a large heap pays for its size at every fork, also one followed by execve (the kernel's copy-on-write costs
nothing until a page is written); vfork and `posix_spawn` cost nothing extra.

**Signal handlers.** Testing bash's `$(...)` found two older faults. Every handler the program installs crashed FEX,
in every mode, since section 17: a handler runs on a dispatcher loop that FEX starts below the host state it saved
at the signal, and the loop top reset the stack pointer to the dispatcher's (`DispatchSP`), above that state, so the
handler's frames overwrote it and `sigreturn` jumped into data. bash crashed when it reaped a child in its SIGCHLD
handler. Saving the host state now also saves `DispatchSP` and sets it to the new stack pointer; restoring puts it
back. `tests/signals.c` (raised, with siginfo, a timer during `pause`, `kill`, a child's exit during `sigsuspend`) runs
in the CI in every mode. A test that reaps 20 children in a SIGCHLD handler between pipe reads and `sigsuspend`
sometimes hangs, also under FEX without the patches.

**x87 registers.** `seq` of Ubuntu crashed under the views (and only there): FEX's x87 stack pass addresses the x87
registers in the thread's context when the stack top is not known within a block (`FormContextAddress`, then
ordinary loads and stores), and the views' pass took those for guest memory and added the view base. It leaves them
alone now. `tests/x87.c` (sums and products in `long double`, `strtold`, `printf` of `long double`) gives the same
result as FEX's full ordering in the CI.

All three faults had stayed hidden because no test ran a shell or a signal handler. `tests/rootfs_check.sh` runs 25
everyday commands of the Ubuntu root file system under tso-arm and under FEX's full ordering and compares the
outputs: command substitution, pipelines, a loop of 100 forks, subshells, a trap, job control, `timeout`, reaping
background jobs, `printf` of a `long double`, awk, sed and grep, md5sum and sha256sum, gzip, xz with two threads,
tar, find with xargs, factor, date, perl (hashes, fork), Python (hashlib, subprocess, a fork pool of 4, fork beside 3
running threads, SIGUSR1 and a timer signal). On the Pi all 25 the same, in 77 s for both modes.

## 40. Shared libraries translated ahead of time (2026-11-20)

Programs as distributions ship them do their work in shared libraries: Ubuntu's xz spends 99 % of its guest cycles
in liblzma and 0.03 % in itself, so translating the program's own functions gave nothing. Release 0.2.0's
`learn` said so ("those of its libraries stay with FEX").

**FEX.** The translated code of several guest objects can be loaded at once (up to 64): the program's, named by
`TSO_AOT` as before, and a shared library's, which FEX looks up when the guest maps an executable segment of a file
(`GuestMmap`): in `TSO_AOT_DIR`, under the file's real name and the first 8 bytes of its build ID
(`liblzma.so.5.4.5-78d7220824dfcd33.so`), the name `tso-arm learn` keeps it under. The load base comes from the
file's program headers and the mapping's offset; the library is position-independent like a PIE program's (aot_base
set at load), and every function is checked against the guest's code before FEX routes the guest function's block to
it. When the guest unmaps the code or maps something over it (dlclose), the functions go back to the JIT
(`RemoveAOTEntrypoint`); mapped again, the same library takes them again. Everything that was one library's state
before (its code range for the fault handler, the room for patch stubs, the switches to the ordered variants)
exists per library; a library loaded after the protocol fell back to full ordering starts ordered. `TSO_AOT` now
comes with `TSO_AOT_FOR`, the program's real path: programs started with execve inherit the variable and used to
check another program's library against their code (and leave it, with a message for each function); now they look
their own up in `TSO_AOT_DIR` by build ID.

**First try, and why it was slower.** liblzma's 10 hottest functions (from a profile; FEX names their blocks by guest
address, and perf's records of the guest's file mappings place them in liblzma) made xz slower: 44.2 against
41.4 s. In the translated code's profile, 13 % went to FEX and 18 % to JIT code: the translated functions called
liblzma functions that were not translated, through the guest each time. With their callees as well (as `auto.py`
does for programs) the most called ones (8 call sites) were still missing: `aot/elfsyms.py` found no function there.
Leaf functions without a frame have an FDE without instructions of its own, for which `readelf` prints no row, and
elfsyms took a function's FDE by its first row. It takes such FDEs as functions now (also for stripped programs).
Then: 18 functions, 31.1 against 40.4 s, the same output; the host's own Arm xz takes 29.7 s.

**learn** (`aot/auto.py --libdir`): the profile is split by object: the program's blocks by the name FEX gives
them, a shared library's by perf's mapping records; per object the hot functions (at least 0.2 % of the cycles, at
most 40) and the functions they call within it. A shared library's library goes to the cache under its name and
build ID with the functions earlier programs chose in it added (its `.so.list`), so that it serves every program
that maps it; the output check and the timed runs use the program's library and the shared libraries' together, and
only when they do not make the program slower are the shared libraries' installed. The program's `.so.libs` lists
the libraries it learned for (`tso-arm status`). `tso-arm run` sets `TSO_AOT_DIR` to the cache in its tso and
unordered modes.

On the Pi, `tso-arm learn` of Ubuntu's xz (8 MB input, 69 s): liblzma 10 functions (the 7 hottest and 3 callees),
99.1 of 99.3 % of the guest cycles; `tso-arm run` with a 54 MB input 31.0 s against 36.9 s without them (the page
protocol with its profile), the output the same as the Arm xz's, which takes 29.7 s: 96 %. xz with other options
(`-T4 -3`) takes the library too.

`tests/sharedlib/` in the CI: `libhot.so` (a loop that calls a function of the library, and one that calls back into
the program through a pointer) translated with lift.py into a cache of the test's own; `dl` loads it with dlopen,
calls it, unloads it with dlclose, three times: the same output as without the translation, and FEX's log shows the
library's functions taken and given up three times.
**Programs as Ubuntu ships them** (`bench/distro.sh`): xz, gzip, bzip2 and openssl of the root file system, each
learned once, against the Pi's own Arm builds (Raspberry Pi OS: xz 5.8 against Ubuntu's 5.4, gzip 1.13 against 1.12,
the same bzip2, openssl 3.5 against 3.0), at 1.8 GHz, best of 3:

| | FEX full TSO | tso-arm, page protocol | tso-arm, learned |
|---|---|---|---|
| xz -T4 (liblzma: 11 functions) | 64 % | 68 % | 86 % |
| gzip (its own code: 15 functions) | 66 % | 79 % | 94 % |
| bzip2 (libbz2: 8 functions) | 55 % | 71 % | 83 % |
| openssl sha512 (libcrypto) | 60 % | 51 % | 54 % |
| geometric mean | 61 % | 66 % | 78 % |

The first session gave xz -T4 a learned column slower than the protocol alone (1.74 against 1.55 s), and `learn`
itself had found the library slower (1720 against 1520 ms). Both came from one page protocol profile shared by every
run of the program: a profile only grows (the code ranges that met shared memory run ordered from then on), and xz
with 4 threads adds about a thousand ranges per run, so each run was slower than the one before (the protocol's
column read 1.55, 1.76, 1.87 s over its three rounds) and whatever ran later lost. Measured on their own, the same
library made xz -T4 30 % faster. `learn`'s timed runs and each column of `bench/distro.sh` keep a profile of their own
now; `learn` there also runs at the fixed clock, from a cool start. That a profile keeps growing for such a program
is a question for the protocol itself (an escalated range that stays in the profile forever).

openssl's sha512 is the one where tso-arm loses: 78 % of its cycles are in one hand-written assembly function of
libcrypto, which lift.py refuses (`mov rax, rsp`: the stack pointer read as a value), and under the views alone,
without any ordering, it runs 30 % slower than under FEX without them (577 against 443 ms, no fault, no escalation):
the views' addressing costs more there than FEX's ordering (495 ms), which leaves stack accesses through RSP alone.
**vfork, again.** The CI's run of `tests/rootfs_check.sh` on GitHub's N2 failed once: Python's `subprocess.run(["seq",
...])` read a wrong byte from the pipe. On the Pi a loop of 20 such calls failed every time (`FileNotFoundError:
'seq'`), under FEX's full ordering never. Since 0.2.3 a vfork child runs on its parent's guest memory, as vfork means,
and FEX's vfork is a fork whose parent waits on a pipe until the child has called execve or exited. Python's
subprocess child closes every descriptor it does not keep before execve (`close_fds`), FEX's pipe end with them: the
parent went on at once, and both ran on one stack, the child's execve reading paths the parent was overwriting. Under
the views the host fork now carries `CLONE_VFORK` (without `CLONE_VM`, so each side keeps FEX's own memory): the kernel
holds the parent until the child has called execve or exited, whatever the child does with its descriptors.
`tests/fork.c` has a vfork child that closes all its descriptors, works a while, and writes a flag before it exits;
the parent must find the flag set. With 0.2.3's FEX that test fails, corrupts the output or hangs; with the fix the
loop of Python subprocesses passed 20 times out of 20.
## 41. A profile that does not take one run's accident for good (2026-11-20)

The page protocol's profile records the code ranges that met shared memory, and every later run translates them
ordered from the start. It only grew: a range in it never left again. Ubuntu's xz with 4 threads, 10 runs with one
profile: 902 ranges after the first run, 923 after the second, then stable, but in another series the fourth run
added 801 at once (that run, by its timing, shared pages the others did not), and every run from then on ordered
those as well: 1.4 instead of 1.26 s.

Now only the program's first run (which starts from nothing) puts its ranges into the profile at once. After it, a
range that escalates goes into the profile as pending (`pend`, not applied at the start of the next run); it enters
the profile when it escalates again in the next run that changes the profile, and is dropped otherwise. The profile
counts those runs (`runs N`); a run that escalates nothing new does not write it. The same 10 runs: 902, then 19
pending, then 921 (all 19 escalated again), 2 pending, 923, stable; times 1.24 to 1.33 s. A range that really
meets shared memory now costs one more run of faults before it is ordered from the start; a run's accident costs
one run.

## 42. Exact state only where a thread can leave (2026-11-20)

A thread can leave its block at an instruction start only where that start has a RIP entry: a boundary trap is
written there (section 10), and a fault that cannot be completed repeats the instruction from there. FEX makes RIP
entries only for instructions with a memory operand (its `GPRDirect` operand, `[reg]`, is one of them; plain
registers are `GPR`), for control flow and for block ends. Still, every instruction start got the exact state of
section 10: the register cache written back in full, MMX, DF and the AVX upper halves included. openssl's sha512,
register arithmetic for the most part, lost 25 of its 31 % views cost (stage 1, no protocol) to that.

Now the full write-back, the carry flag in ABI form and the register allocator's merge barrier come only at the exit
points (`IsViewExitPoint`): instructions with a memory operand, control flow, block ends, divisions (a divide error
has to report its own instruction), and `pushf`, `maskmovq` and `maskmovdqu`, which access memory without a memory
operand; `lea` and `nop` with a memory operand access nothing and are none. A check at translation backs the list
up: when an instruction that is no exit point creates an IR op that accesses guest memory (the ops of the view pass,
the x87 registers in the thread's context left out), its kind (its table entry) becomes an exit point for good and
the block is translated again. The first version took `GPRDirect` for a register: the check learned 32 kinds (MOV,
CMP, ADD, MOVDQU, ...) in each program, the list's limit, after which every start is exact again; the outputs stayed
right. With the operand types right, pigz, xz, zstd and Ubuntu's openssl, xz, gzip, bzip2, python3 and sort learned
none, every output the same as without views.

The views without the protocol (stage 1) against TSO off, at 1.8 GHz, best of 3:

| | before | now | no exact starts at all |
|---|---|---|---|
| openssl dgst -sha512 (Ubuntu) | +31 % | +13 % | +7 % |
| xz -T4 | +14 % | +9 % | +10 % |
| zstd -T4 | +10 % | +11 % | +11 % |
| pigz -p 4 | +4 % | +6 % | +6 % |

Full check all correct (litmus series, views matrix, 12 to 64 threads, outputs), `tests/ci.sh` passed. Efficiency
pigz 92 (was 90), xz 88, zstd 70 %, mean 83 %; the page protocol alone 73 %. Ubuntu's programs (`bench/distro.sh`):
openssl learned 63 instead of 54 % (FEX's full TSO 60 %), with the protocol alone 59 instead of 51 %; mean 80
instead of 78 %. What is left of openssl's cost is the address arithmetic of the views (section 40).

## 43. Smaller multiblock units (2026-11-20)

ffmpeg (x264, 4 threads) ran its first time under tso-arm in 5.3 s, twice its time under FEX's full TSO. The page
protocol's statistics put the time elsewhere than expected: faults 0.76 s, but 7,741 block compiles in 5.5 s (all
threads, 0.7 ms each), with 3,900 escalations each throwing a translation away. With `FEX_MULTIBLOCK=0` the same run
took 1.9 s, with 39,439 compiles in 0.31 s (8 microseconds each), and FEX's full TSO 1.4 instead of 2.5 s. FEX's
multiblock compiles from each entry everything reachable forward, up to `MaxInst` guest instructions (default 5000).
A large function entered at many points (every return from a call is an entry) is compiled again from each of them,
cold paths included.

Multiblock on and off under tso-arm with a warmed profile (best of 2, 1.8 GHz): it is worth 15 % to pigz, 17 % to
xz, 20 % to gzip, 37 % to bzip2, 16 % to sort and 48 % to Python, and costs ffmpeg 40 % (3.72 against 2.23 s) and
Node 37 % (9.48 against 6.00 s). Smaller units keep both sides (`FEX_MAXINST`, best of 2):

| MaxInst | pigz | xz | gzip | bzip2 | openssl | sort | Python | ffmpeg | Node |
|---|---|---|---|---|---|---|---|---|---|
| 5000 (FEX) | 1.29 s | 1.49 s | 4.55 s | 19.59 s | 0.67 s | 2.47 s | 2.89 s | 3.73 s | 9.43 s |
| 400 | 1.27 | 1.54 | 4.54 | 19.76 | 0.65 | 2.49 | 3.01 | 2.41 | 7.02 |
| 250 | 1.29 | 1.52 | 4.54 | 19.70 | 0.64 | 2.42 | 3.00 | 2.28 | 6.61 |
| 150 | 1.27 | 1.52 | 4.54 | 19.98 | 0.65 | 2.42 | 2.95 | 2.17 | 6.15 |
| 100 | 1.29 | 1.56 | 4.55 | 20.07 | 0.65 | 2.47 | 3.00 | 2.14 | 5.76 |
| multiblock off | 1.47 | 1.77 | 5.46 | 26.75 | 0.61 | 2.85 | 4.28 | 2.23 | 6.00 |

`tso-arm` now sets `FEX_MAXINST=150` (unless it is set): xz, bzip2 and Python lose 1 to 2 % (within the spread),
ffmpeg gains 42 % and Node 35 %. The benchmarks give tso-arm's configurations the same and FEX's columns FEX's own
5000 (`bench/efficiency.sh`, `bench/distro.sh`, `tests/compat.sh`). ffmpeg's first run now 2.4 instead of 5.3 s; in
the compatibility table (README) ffmpeg 1.73 s and Node 4.97 s against 2.93 and 8.38 s under FEX's full TSO, both
faster than FEX without any ordering (2.24 and 6.71 s).

The translated configurations compile block by block (`FEX_MULTIBLOCK=0`), where `MaxInst` only splits basic blocks
longer than that: pigz and xz ahead of time + tso-arm, 150 against 5000 alternating, 8 rounds: pigz best 1096 against
1090 ms (medians 1109 and 1106), xz 1211 against 1212 ms, no difference. The efficiency table of this session has
pigz at 1.12 s (88 %, mean 81 %); its best of five varies between 1.09 and 1.12 s from session to session.

Also seen: FEXServer keeps the root file system of the client that started it, and exits only a second after its
last client; a program started with another `FEX_ROOTFS` within that second gets the first one's ("Invalid or
Unsupported elf file"). Benchmarks that switch root file systems wait a few seconds in between.

## 44. A boundary trap the block linker wrote over (2026-11-20)

`tests/rootfs_check.sh` got three more programs: git packing a repository of 60 commits (made with fast-import)
with 4 threads searching deltas at once, make with 4 jobs, rsync. git's `pack-objects` died of a segmentation fault
under tso-arm, now and then: 1 of 3 runs in the first try, 0 of 40 with multiblock, 4 of 20 with `FEX_MULTIBLOCK=0`
(as FEX runs when a program has translated libraries); never under FEX's full TSO, without ordering, or with the views
alone (stage 1).

The protocol's log of a crashing run: an instruction of a block escalated in four threads at once, the block was
translated anew, and `TSOTrapBlockBoundaries` wrote traps over its instruction starts, among them the start of a
guest `jmp`. Two threads left through that trap as they should. A third faulted on it too (`ldrb wzr, [x24]`, fault
address the view's base), but by the time its handler read the instruction, it was `b +0x6c`: no trap, so not the
protocol's fault, and the guest got SIGSEGV. A guest instruction that is only a jump compiles to nothing but FEX's
exit stub, whose first instruction FEX's block linker rewrites whenever a thread links the jump to its target or
unlinks it (`b HostCode`, `b JmpThunk`). Here a fourth thread had come to the stub before the trap, gone to the
dispatcher, compiled the target and linked the stub, over the trap.

The handler now also takes a fault at the view's base, at a place where a trap was written, where a branch stands
now, for the trap (a branch accesses no memory, and the linker writes nothing but branches there); the thread leaves
at that instruction start as from the trap. A thread that comes to the stub after the linker gets the branch to the
fresh translation of the target, which is what the jump would have done. Afterwards: 0 of 60 runs without multiblock
crashed and 0 of 30 with it, with 3 and 1 exits through a trap linked over.

Then: `rootfs_check` 28 of 28 the same as FEX's full ordering, `tests/ci.sh` passed, full check all correct;
efficiency pigz 90, xz 88, zstd 70 %, mean 82 % (README table).

`tests/soak.sh` looks for such rare failures on purpose: multi-threaded programs of the root file system (git
packing with 4 threads, xz -T4, sort --parallel=4, Python threads with a lock, make -j4), each 20 times in three
settings (with the profile earlier runs left, without a profile, block by block), every output against full
ordering. On the Pi after the fix: 300 of 300 runs right.

## 45. Programs and libraries mapped from their files (2026-11-20)

A program start cost about 10 ms more under tso-arm than under FEX's full TSO (bash starting `/bin/true` 100 times:
50.5 against 40.6 ms each), and large programs much more: `ffmpeg -version` 0.56 against 0.20 s and 266 against
62 MB of memory, `node -e 0` 2.23 against 1.71 s and 216 against 103 MB. Guest memory under the views is shared
memory (every view maps the same pages), so the views copied every private file mapping into shared memory with
`pread`: every library a process maps, code and constants included, at every start, in every process.

A private file mapping the guest cannot write (code, read-only data: most of a program and its libraries) is now the
file itself, mapped shared: the views and all processes read the same pages of the page cache, nothing is copied.
It is marked ForkShared (section 39) and file-backed: before it becomes writable (`mprotect`), it is copied into
shared memory of its own (`Unshare` copies the whole range then: a file's pages not in memory are not zeros), so the
guest's writes never reach the file. ld.so maps a library's whole span at first, past the file's end (.bss, gaps):
the part within the file (in whole pages) comes from the file, the rest is zeros as before, as two ranges. A writable
private mapping (a library's data) is copied as before. `madvise(MADV_DONTNEED)` leaves a file-backed range mapped
(dropped pages read the file again, as in a private mapping); before, it read zeros afterwards. Where the file cannot
be mapped so (a file system mounted noexec), it is copied as before.

| | before | now | FEX full TSO |
|---|---|---|---|
| `ffmpeg -version` | 0.56 s, 266 MB | 0.26 s, 93 MB | 0.20 s, 62 MB |
| `node -e 0` | 2.23 s, 216 MB | 2.06 s, 121 MB | 1.68 s, 102 MB |
| `python3 -c 0` | 0.46 s, 37 MB | 0.45 s, 28 MB | 0.39 s, 26 MB |
| a program start (`/bin/true` from bash) | 50.5 ms | 46.8 ms | 40.6 ms |

`tests/filemap.c` (in `tests/ci.sh`) checks that such a mapping still behaves as a private one: it reads the file
and zeros past its end, made writable it sees its own writes while the file keeps its bytes, also in a forked child
that writes its copy, a second mapping reads the file, `madvise`, executable and writable private mappings, `mremap`;
all right natively, under tso-arm, FEX's full TSO and without ordering. Full check all correct, `rootfs_check` 28 of
28, `tests/ci.sh` passed; efficiency pigz 90, xz 88, zstd 70 %, mean 82 %.

Of the remaining 6 ms per start, a third is the view pass in FEX's translation (`GuestViewPass`, 4.7 % of a start's
user cycles), the rest the views' own mappings (`mprotect`, `mremap` for each mapping and view).

## 46. One thread, no views (2026-11-20)

x86 memory order is a matter between threads (and processes sharing memory): a process with a single thread sees
its own accesses in program order whatever the processor does. Still, every process ran through the views from its
first instruction: the view address in every access, exact instruction starts, the view pass at every translation,
the views' own mappings. A single-threaded program paid that for nothing, and most programs are single-threaded
(shells, compilers, the tools of a build, most commands).

The views now sleep in a new process (`FEXCore::TSOViews::AsleepActive`, read once per translation like the
fallback's flag). While they sleep, code is translated as without views: guest memory addressed directly, every
access plain, no exact starts, no view pass; the views get no mappings (each range comes into a view at its first
access later, as into another thread's). They wake when a second thread is created (`AttachThread`, before the new
thread runs anything) or the process maps memory another process may map as well (a shared mapping, a second
mapping of shared memory by `mremap`, System V `shmat`): everything translated so far goes, as in the fallback, and
the protocol takes over with all pages owned by the first thread. The thread that wakes them is in a system call,
which ends its block; the new thread has not run yet. A forked child inherits the state; `execve` starts asleep.
`TSO_VIEWS_ASLEEP=0` starts awake; the measurement modes (stage 1, identity base, eager views) always do.
`TSO_VIEWS_STATS` tells "views asleep throughout (one thread)" or "views woke after N s" (pigz: 0.013 s).

`tests/wake.c` (in `tests/ci.sh`) is the ring buffer of `tests/spsc.c` with its producer and consumer first run by
the main thread alone (translated asleep), then by two threads: 20 million messages, none wrong under tso-arm
(without ordering 3 wrong in one of three runs: the test can see it).

| | before | asleep |
|---|---|---|
| a program start (`/bin/true` from bash) | 46.8 ms | 40.9 ms (FEX's full TSO 40.5) |
| `python3 -c 0` | 0.45 s, 28 MB | 0.39 s, 25 MB (FEX 0.39 s, 26 MB) |
| `ffmpeg -version` | 0.26 s, 93 MB | 0.22 s, 77 MB (FEX 0.20 s, 62 MB) |
| gzip, page protocol (distro table) | 79 % | 84 % |
| bzip2, page protocol | 70 % | 75 % |
| openssl, page protocol / learned | 59 / 63 % | 68 / 70 % (FEX's full TSO 60 %) |
| distro table, mean protocol / learned | 68 / 80 % | 74 / 83 % |

Node wakes the views at once (V8 starts its threads), and the efficiency table's programs all run four threads:
pigz 91, xz 88, zstd 70 %, mean 83 %. Full check all correct, `tests/ci.sh` passed, `rootfs_check` 28 of 28,
`tests/soak.sh` with 100 rounds 1,500 of 1,500 (each run wakes the views once: every case starts with one thread).

## 47. CPython's own tests, Java, and three faults in signal delivery (2026-11-21)

**CPython's tests.** `tests/cpython_suite.sh` runs the tests of the interpreter's own release (Lib/test of
Python 3.12.3 from python.org, the root file system's python3) for threads, thread-local data, signals in threads,
queues, `sched`, signals, fork, `wait4`, `mmap`, selectors and `concurrent.futures` (19 test files, 750 cases),
under tso-arm and under FEX's full ordering, one test at a time, each in a process of its own, and compares the
failed cases of regrtest's JUnit file: none may fail under tso-arm that passes under full ordering.

The first runs looked like FEX hanging at exit: `test_threading`'s 40 daemon threads never let their interpreter
end, in both modes, until the time limit. It was the set-up: the tests' child interpreters start isolated (`-I`),
which drops `PYTHONPATH`, so they imported Ubuntu's small `test` package, whose threads died on a module it lacks
while the main thread waited for them. `PYTHONHOME` (the interpreter's own prefix) keeps the children's environment.
Then one test failed, in both modes alike: `test_signal`, crashing in its stress tests, in 10 of 10 runs. FEX without
the patches (be66e03, built beside it) crashed the same way in 5 of 5, `test_stress_modifying_handlers` alone in 10
of 10. Three faults, two of them FEX's own:

1. **An action read in pieces.** FEX's delivery read the guest's action for the signal field by field, without the
   lock that `rt_sigaction` takes, and another thread may change it meanwhile (Python's `signal.signal` against a
   thread raising the signal). It checked for `SIG_IGN` and then took the handler address: `SIG_IGN` (1) by then,
   and the guest jumped to address 1. The kernel delivers under the lock sigaction takes; FEX's handler cannot wait
   for a lock the thread it interrupted may hold. The action now has two copies and a count of writes, odd while
   one goes on: a write fills the copy not in use, a delivery reads the current one whole and tries again if a
   write overtook it. A delivery on the writing thread itself reads the other copy and never waits.
2. **FEX's handler inside FEX's handler.** FEX installed its host handler with the guest's signal mask, and
   Python's is empty: a timer signal coming in while FEX built the guest's frame for `kill`'s SIGUSR1 (the test sends
   both at once) ran FEX's handler inside FEX's handler, and the inner one sent the outer one's return to the
   dispatcher before the frame was done. The host handler now blocks every signal FEX does not need there (left
   open: SIGILL, SIGBUS, SIGSEGV, its pause signal and the other synchronous ones). The guest's mask for its handler
   is what FEX's handler returns with, so a signal the guest allows comes in right after, before the handler's first
   instruction, as after the kernel's own delivery.
3. **A system call's state left to the handler** (in tso-arm's way above all). The dispatcher's system call path
   sets `InSyscallInfo` to 0xFFFF ("everything spilled") until the call returns. A signal that came in during the
   call left that value to the guest's handler, which runs JIT code of its own; the page protocol's exits from a
   block (a boundary exit, an escalation) and FEX's own SMC path spill the registers not marked spilled, so they
   spilled none of the handler's and went on with the interrupted code's. A thread raising a signal to itself while
   its handler met memory another thread uses crashed after two or three signals: its stack pointer and `rdx` came
   from `raise`. The handler now starts outside any system call, and `sigreturn` gives the interrupted code its value
   back. Found with a log of the deliveries and the exits (`injit 0 insyscall 0xffff`, then a boundary exit that
   kept `rsp` from before).

`tests/sigrace.c` (in `tests/ci.sh`, every mode): 20,000 rounds of a timer of 1 to 11 microseconds and `kill` at
once, one handler for both (optionally on an alternate signal stack, as Python's run), every signal counted, then a
thread raising SIGUSR1 in a loop while the main thread switches its action between a handler and `SIG_IGN`. A count
for both signals together lost increments now and then, here and natively alike: one handler's increment came in
between the other's load and store. It counts per signal.

**Java.** `tests/compat.sh` packs the distribution's JDK (its directory without the modules for jlink, headers and
manual pages: `tools/compat_rootfs.sh`) and runs a parallel sort of 4 million numbers, a `ConcurrentHashMap` filled
from a parallel stream, and message passing: one thread writes the data plainly and the flag with a release store,
the other reads the flag with an acquire load and then the data. A correct Java program; HotSpot's JIT makes all
four plain moves on x86-64, and only x86 order keeps the reader from seeing the flag before the data. The class is
compiled once by the distribution's javac under tso-arm.

**Results.** `test_signal` passed in 6 of 6 runs in both modes (was 0 of 10). CPython's suite: all 750 cases pass
under full ordering; under tso-arm one failed, `test_threading`'s daemon threads, whose test wants the child's
standard error empty: tso-arm's layer for translated libraries had written "no room for stubs" there. Its messages
go to the program's standard error now only on a terminal or with `TSO_AOT_LOG` (that note only with the log), and
it looks for room for its stubs every 2 MiB out to 96 MiB on both sides of a library (four places had all been taken
next to Python's libraries). Then `test_threading` and `test_signal` pass in both modes. `tests/sigrace.c` without a
profile under the views: 10 of 10 (was 1 of 5), FEX without the patches 3 of 3 crashed. `rootfs_check` 28 of 28,
`tests/ci.sh` passed, `tests/soak.sh` 75 of 75, the full check correct, efficiency unchanged (pigz 90, xz 89, zstd
72 %, mean 83 %).

Java on the Pi (best of 3, cooled to 60 °C): tso-arm 4042 ms, FEX's full TSO 4272 ms, no ordering 2854 ms; messages
seen before their data 0, 0 and 3,131,256 of 20 million. In the CI (a Neoverse N2, Ubuntu 24.04's OpenJDK 21): 2664,
2630 and 1761 ms, 0, 0 and 6,925. HotSpot crashes now and then, in 30 runs each: FEX without the patches with the
settings of full TSO 1, full ordering with the patches 2, tso-arm 3, SIGILL or SIGSEGV at the start of code it has
just compiled (HotSpot patches code that other threads run, which x86 allows, and FEX's translation can meet it half
written). Not to be told apart at these numbers; `tests/compat.sh` repeats such a run, twice at most, and names it.

**A wider run** with the released 0.3.4 (its prebuilt FEX): `test_subprocess test_os test_io test_socket
test_select test_poll test_epoll test_time test_faulthandler test_asyncio test_multiprocessing_forkserver test_pty
test_fcntl test_mmap test_threading`, 47 test files and 5,297 cases, 10.6 minutes per mode. The same 5 cases fail
in both: four of `test_subprocess` find descriptors open in a child that should not be (5, 6, 8, 9: FEX opens its
own in every process, the root file system's directory, its server's socket, and keeps them at low numbers where a
child that lists its descriptors sees them; FEX tracks them only in builds with assertions), and
`test_multiprocessing_forkserver`'s `test_flags`, whose child exits with 1. None fails under tso-arm only
(`SUITE_TIME` gives the run more than the default two hours per mode).

**The whole suite** (`JOBS=3 tests/cpython_suite.sh all`, with the released 0.3.5): 39,988 cases, 21 minutes per
mode. 87 fail under full ordering, 86 under tso-arm, and the 86 are among the 87 (the one more under full ordering,
`test_threaded_import`'s circular import through a multiprocessing pool, is timing). Most are the set-up's: Ubuntu's
Python 3.12.3 carries backported changes (`test_htmlparser`, `test_http_cookies`, `test_email`, `test_tarfile`'s
extraction filters) and a layout (`test_sysconfig`, `test_site`, no ensurepip, venv) the release's own tests do not
expect; the rest are FEX's: the descriptors in children (`test_subprocess`, `test_posix`'s `posix_spawn` and
`fexecve`, `test_tempfile`'s `noinherit`), the multiprocessing flags, and `test_platform`'s architecture of a
program through a symbolic link.

**Two faults of the test set-up on the way.** The orphaned children of the hanging daemon-thread test (five, from
the first runs on) kept FEX's server alive for four hours, and it served Ubuntu's root file system to every FEX
program, whatever `FEX_ROOTFS` said: FEX takes the root file system from its server. `tests/ci.sh`'s dynamically
linked library was not found there, and the test ended silently (`grep -c` with no match under `set -e`; both runs it
compares had failed alike); the first Java numbers ran on the wrong libraries and were measured again. `tests/ci.sh`
now waits for a server the tests before it started and fails aloud; `tests/cpython_suite.sh` runs each mode in a
session of its own and ends what is left of it; `tso-arm run` says so when FEX's server serves another root file
system than `FEX_ROOTFS` names.

## 48. Go programs (2026-11-21)

A Go program built for amd64 (`tests/compat.sh` builds it with the go command, which cross-compiles, or takes one
built elsewhere): eight goroutines sort parts of 4 million numbers, which are merged; a channel pipeline through four
workers; a map filled by four goroutines under a mutex; and message passing, the data stored plainly and the flag
with `atomic.StoreInt64` (an XCHG on amd64), the flag read with `atomic.LoadInt64` (a plain MOV) and then the data.

Go 1.26's program crashed within a second in every mode, FEX's full TSO and no ordering as well, and under FEX
without the patches in 3 of 3 runs: unexpected fault addresses, "unknown caller pc", stack traces through
`runtime.asyncPreempt`. Go's runtime preempts a goroutine that runs for long with SIGURG; its handler pushes a call
to `asyncPreempt` onto the goroutine's stack with the interrupted address as the return address, and `asyncPreempt`
saves the registers the handler saw, may switch goroutines, restores them and returns there. That needs the exact
state at an instruction boundary. FEX delivers a signal that comes in while translated code runs at once, with the
registers spilled from the host's and the address of the guest instruction the host's lay in: in the middle of an
instruction's translation, or with values the block keeps elsewhere, that is not a state any instruction boundary
had, and after the handler changed the address FEX goes on with that state. With `GODEBUG=asyncpreemptoff=1` all
modes run right, 10 of 10 each; messages seen before their data 0 under tso-arm and full TSO, 23 to 601 without
ordering.

`tso-arm run` (and so binfmt_misc, which goes through it) adds `asyncpreemptoff=1` to `GODEBUG` unless it is set
there already or `TSO_ARM_GO_PREEMPT=1`: only Go programs read the variable, and they stop goroutines at their own
safe points then (calls, the loops of the runtime), as all Go versions before 1.14 did; a goroutine in a long loop
without calls is not preempted. What would make preemption work: delivering an asynchronous signal that comes in
during translated code at the thread's next exact instruction start (the views' boundary traps lead a thread there,
and a signal raised again from the trap's handler comes in at the dispatcher's top, where the state in memory is
exact) instead of at once. Exact starts exist only with the views awake, though, not in full ordering and not in the
fallback, where many programs run after their first run; and a signal that comes in during the dispatcher's lookup
has the guest's registers live in the host's (spilling them there would be exact, the lookup does not change them).
Left for later.

On the Pi (best of 3, cooled): tso-arm 2496 ms, full TSO 2440 ms, no ordering 2425 ms; messages seen before their
data 0, 0, 84 of 20 million; the three times within 3 %. In the CI the Arm runner builds it with Ubuntu 24.04's
Go.

## 49. FEX's own descriptors (2026-11-21)

CPython's whole suite left a group of failures under both modes that had one cause: FEX opens descriptors of its own
in every process (its server's socket, the root file system's directory, `/proc`, later the code map and the log),
and they took the lowest free numbers. FEX hides three of them from listings of `/proc/self/fd` (by their inode, for
Chromium, which closes what it finds there), not the socket.

- A program started with its standard input closed found FEX's server socket as stdin (`test_cmd_line`'s
  `test_no_stdin`, `test_no_std_streams`).
- FEX's `execve` opens the program's file and hands the descriptor to the next FEX through `FEX_EXECVEFD` (without
  binfmt_misc, as on the Pi). After a `posix_spawn` file action or a `preexec_fn` that closed descriptor 0, that was
  0: the new program had its own executable as standard input (`test_posix`'s `posix_spawn` tests,
  `test_subprocess`'s `test_swap_std_fds_with_one_closed`).
- A child that checked that a descriptor it had not inherited was closed found FEX's there, open, and wrote into it
  (`test_tempfile`'s `test_noinherit`, `test_subprocess`'s `test_close_fds` and `test_pass_fds`).

`FEX::MoveFEXFD` (Common/FDUtils.h) moves such a descriptor to just below the limit on open files (64 below it; 960
with the usual 1024), close-on-exec unless it has to live past an `execve`; the server's socket, the two directories,
the log and the code map, and the two descriptors `execve` hands on. The socket is hidden from `/proc/self/fd` like
the others. A program that tries every number up to its limit with `fstat` still finds them
(`test_pass_fds_redirected`); hiding them from that as well would take FEX answering every call on them with EBADF and
a lower limit shown to the program.

And one in `execve` itself: an `execveat` of a descriptor (`fexecve`) loads through `FEX_EXECVEFD` as well, and the
loader then drops the first argument as binfmt_misc's copy of the path; FEX had left the program's `argv[0]` out for
that case only where it opened the descriptor itself, so a program run with `fexecve` saw its arguments shifted by one
(`test_posix`'s `test_fexecve`: python took `-c` for its name).

In the six test files concerned (`test_cmd_line test_tempfile test_posix test_subprocess test_platform test_os`,
1,048 cases) 3 fail now instead of 14, in both modes alike: `test_pass_fds_redirected`, an environment test of
`PYTHONPATH`, and `platform.architecture` through a symbolic link. `tests/ci.sh`, `rootfs_check` 28 of 28,
`tests/soak.sh` 45 of 45.

The whole suite afterwards (`JOBS=3 tests/cpython_suite.sh all`): 75 cases fail in both modes, none under tso-arm
only (87 and 86 before). Five processes were left behind after it, multiprocessing's resource tracker and pool
workers of a test: regrtest starts its workers in sessions of their own, out of reach of the suite's session, and
they kept FEX's server alive. The suite marks its processes in their environment now and ends every one that carries
the mark, wherever it went.

## 50. Self-modifying code through the views (2026-11-21)

FEX finds out that code it translated changes by protecting the pages it translated from against writes
(`MarkGuestExecutableRange`, FEX's default `mtrack`): a store faults, the handler throws the translations of the
page away and lifts the protection. It protects the identity mapping of guest memory, the addresses FEX itself
uses. Under the views translated code stores through a thread's plain or ordered view, other mappings of the same
memory that this protection does not reach: a store there went through, and the old translation kept running.
`tests/smc.c`: with a second thread running (the views awake) the main thread writes `mov $N, %eax; ret` over the
same bytes and calls them, and then a second thread writes code the main thread runs; under tso-arm the second call
already returned the first N, in every run (full ordering and no ordering: right). Every JIT that writes over code it
ran before is concerned while it runs under the views and not in the fallback (a code cache that is reused, inline
caches patched in place).

It also made FEX crash: HotSpot without the fallback (`TSO_VIEWS_BUDGET=0`) died at once, in `java -version`
already, in the fault handler: a store to its code cache met a page another thread uses, the handler completed it on
the identity mapping (`EmulateAccess`), which was protected for code, and the write faulted inside the handler (a core
file and FEX's symbols showed it: `strb w8, [x0]`, x0 a guest address in the code cache). With the fallback, after a
fraction of a second, nobody saw either.

The views now keep a byte per page, protected for code (`TSOViewMemory::ProtectCode`, called by
`MarkGuestExecutableRange`): no view gives such a page the right to write, whatever its state. A store faults on its
view, and the handler (`Fault::Code`) goes on with FEX's own handling of self-modifying code at the guest address:
the translations go, the identity mapping and the views get their rights back (FEX's callback calls `UnprotectCode`;
the page's state decides again), and the store runs again; a store into the block it runs in repeats as a single
instruction, as in FEX. An access the handler completes itself does so only if no page within 32 bytes of it is
protected for code, under the views' lock, which `ProtectCode` takes as well; otherwise the instruction is repeated
as a single instruction, faults on its view again and takes the path above. A new mapping clears the bytes (FEX
throws away what it translated from the range before).

`smc.c` (now in `tests/ci.sh`, every mode): 5,000 rewrites and 5,000 hand-overs right in every mode. HotSpot with the
views throughout: right.

The protection costs a view's rights only where the guest may write: most code pages are a program's read-only text
and only get their byte (re-applying every view's protection for each new code page cost the protocol a point or
two). Efficiency afterwards (README): pigz 91, xz 88, zstd 70 %, mean 83 %; the full check correct, `tests/soak.sh`
75 of 75, `rootfs_check` 28 of 28.

HotSpot's occasional crash (section 47) stays: 2 of 60 runs with the views throughout (exact starts at every access
to memory), SIGSEGV and SIGILL, about as often as with the fallback.

## 51. CPython's whole suite with the views throughout (2026-11-21)

With the fallback by fault rate, a program that keeps the protocol busy runs fully ordered after a fraction of a
second, and a program whose profile says it fell back runs without views at all: CPython's suite under tso-arm
mostly tested FEX's full ordering. Run again with `TSO_VIEWS_BUDGET=0 TSO_VIEWS_PROFILE=none` (every program under
the protocol from its start to its end), with three tests at once: the distribution's programs and `compat.sh` the
same as under full ordering, `rootfs_check` 28 of 28, and in CPython 75 cases failing in both modes and, run again
alone, four groups under tso-arm only. Each was found and three were faults of their own.

**Descriptors.** `test_subprocess`'s `test_no_leaking` opens files until EMFILE, closes ten and starts subprocesses:
`EBADF` when the parent closed its ends of the child's pipes. Under the views a fork took two descriptors for a pipe
on which the parent waits for the child's copy of guest memory (section 39). With the guest's eight pipe ends and
these two the ten were gone, and FEX's own pipe for vfork (Python's `subprocess` uses vfork) failed: FEX did not
check `pipe2`, and closed and polled whatever numbers the uninitialised pair held, which were the guest's. The views
now wait on a word in a page of shared memory mapped for each fork (a futex, with `waitid(..., WNOWAIT)` for a child
that dies on the way, which leaves it to be reaped by the guest), and FEX's vfork takes no pipe under the views
(the kernel's vfork waits there, section 39) nor when none is left. `tests/fdfull.c`: fork, vfork and posix_spawn's
`clone(CLONE_VM | CLONE_VFORK)` with 0 to 10 descriptors left, none of the program's lost, every mode.

**Threads.** `test_queue`'s `test_many_threads` starts 100 threads: "can't start new thread" under tso-arm, also
with the fallback (97 threads, against any number under full ordering). The Raspberry Pi 5's kernel gives a process
39 bits, 512 GB; the views had reserved 13 slots of two 16 GB views each, 416 GB, and the host kept about 90 GB. FEX
takes some 700 MB of address space per thread (`vamap.py`, a size histogram of `/proc/PID/maps`, and `strace` of the
mappings each new thread makes): 512 MB from its allocator, rpmalloc, whose 256 MB spans are mapped with 256 MB more
for their alignment and kept whole (for a 64-bit guest FEX installs none of its allocator hooks, so rpmalloc's own
mapping runs), 272 MB of lookup cache (8 bytes per page of a 64 GB guest address space and the block table), and the
thread's stack. Now the window and the views take at most three quarters of the address space (11 slots on 39 bits;
all 15 on 48 bits, `TSO_VIEWS_SLOTS` lowers it), rpmalloc's mapping gives back what lies before and after the aligned
span (`TrimAlignedMappings`), and the lookup cache covers the views' window (a guest address above it still works,
the lookup compares the address). That is some 460 MB per thread and 158 GB for the host: 304 threads under the
views. Beyond that a thread's setup failed halfway in FEX and the program died; FEX now maps 512 and 256 MB of address
space for a moment before it creates a thread, and the guest gets EAGAIN if it cannot.

**A register set too early.** `test_import` died with SIGSEGV in about one run of ten (not alone, and not at all
without `--timeout`, whose watchdog thread wakes the views). With the views' log in a file (`TSO_VIEWS_LOG=/path`; a
vfork child that logged to stderr filled a pipe its parent read only after the child's exec, and both stopped) the
faulting store was in CPython's `_PyObject_GC_UNTRACK`, `mov %rax, 0x8(%rcx)` with rcx 0, right after a boundary
exit to that instruction. The store before it (`mov %rcx, (%rdx)`) had met a page the watchdog thread had touched and
escalated a second time: its block was translated anew and the thread left the old one at its next instruction start.
The registers the exit spilled (logged with the code around the trap) had rcx 0 already: the old block had
`mov w7, #0` (w7 is rcx) before that start, for the `xor %ecx, %ecx` after the store. FEX's IR emitter pools
constants within a block; the 0 had been made for an earlier instruction, the register allocator gave it rcx's
static register because it was written to rcx, and it was set where it was made. Nothing in the old block read rcx
again (the store used the address computed for the load before it), so the block itself ran right. Constants are no
longer pooled across an instruction start that has a RIP entry (`ForgetConstants`, where exact starts flush the
register cache). `tests/exactstart.c` runs that function with the previous node on a page another thread writes: a
segmentation fault in every run before, right now (`tests/ci.sh`, every mode). `test_import` as the suite runs it,
ten times: no crash.

**Timing.** `test_multiprocessing_*`'s `test_get` waits 0.1 s for a child process's queue thread to have written four
items. Under the protocol from the start, a fresh Python's second thread takes 91 ms to start (the views wake and
everything translated so far goes) against 6 ms under full ordering, and the first round trip through a queue 31 ms
against 0.3: the item is not there in time. With the fallback the test passes; nothing to fix but speed.

The same run afterwards, views throughout: the distribution's programs and `compat.sh` the same (Node 38 s against
8.5 under full ordering, Java 7.2 against 4.3: programs whose threads share much are why the fallback exists),
`rootfs_check` 28 of 28, CPython's whole suite 39,988 cases (101 more than before, which the crashed `test_import`
had taken with it), 75 failing in both modes, and under tso-arm only `test_get` of the two multiprocessing variants.
Efficiency afterwards (README): pigz 91, xz 88, zstd 69 %, mean 82 % (zstd a point down, within what it varies
between sessions); the constants made anew at each exact start cost nothing measurable. HotSpot's occasional crash
(sections 47 and 50) was not this: 5 of 100 runs with the views throughout afterwards (SIGILL and SIGSEGV), as before.

## 52. Code patched while it is translated: HotSpot's crashes (2026-11-21)

HotSpot crashed in a few runs of a hundred in every mode, under FEX without the patches as well (sections 47, 50,
51). Under full ordering, 80 runs of `Workers` with `-XX:ErrorFile` (`javacrash.sh`): 4 crashes, one SIGILL "sent
by kill" (FEX raises the guest's SIGILL for an instruction it cannot decode) and three SIGSEGV at addresses no
program uses (0x402c9ffe9, 0xfeac21c8b3). All four were in methods C1 had just compiled, at their very entry
(offsets 0, 0x20 and 0x24 of the nmethod): where HotSpot patches code while other threads may run into it (the
verified entry made not entrant, call sites bound), each step one atomic store so that a processor fetching the
instruction sees it old or new.

FEX finds out that guest code changed by protecting each page it translated from against writes
(`MarkGuestExecutableRange`): a store faults, the translations of the page go, the protection goes, the store runs
again. A page is protected after its translation is done (`CompileBlock`, the decoder's code pages). A store while
the decoder read the bytes, which a page without translations takes without a fault, went unseen: the translation
of the bytes before it, or of a mix of old and new bytes (the decoder reads them one at a time), stayed valid, and
the protection set afterwards waited for the next store. `tests/xmc.c` does what HotSpot does, many times: a
function begins with `mov $1, %eax` (b8 01) and its first two bytes change by one atomic 2-byte store to a jump to
`mov $2, %eax` (eb 04) and back, while another thread calls it. Natively every call returns 1 or 2 (two runs,
870,000 calls during 20,000 patches each); under FEX without the patches, and under tso-arm 0.3.8 in every mode,
every run crashed within two seconds (b8 04 is `mov $4`, eb 01 a jump into the middle of an instruction).

The decoder now protects a page before it reads from it (`Decoder::ProtectCodePage`, at the block's entry and at
each further page it reaches), unless translated code from the page is tracked already, which keeps the page
protected (`LookupCache::HasCodePage`). The compile holds `CodeInvalidationMutex` shared; a store during it faults,
FEX's handler of self-modifying code waits for that mutex, and when the translation is done throws it away with
the page's others and lifts the protection: the next call translates the bytes as they are then. xmc: every call 1
or 2, every mode (`tests/ci.sh`). HotSpot under full ordering, the same 80 runs: no crash; with the views
throughout 100 of 100 right (5 of 100 crashed before), as `tso-arm run` runs it 80 of 80. The protection costs a
`mprotect` for each page a block is read from that holds no translated code yet; efficiency afterwards (README):
pigz 90, xz 88, zstd 69 %, mean 82 %, as before.

A loop on the spot (`jmp .`, which HotSpot writes over an entry for the moment between the stores of a five-byte
patch) is another matter: xmc in its first form, which patched through such a loop, did not end in any run with the
protection in place (a thread that runs into the loop stays in its translation, a branch to itself, after the
translation was thrown away). HotSpot's window is a few nanoseconds; it was not seen in any of its runs.
