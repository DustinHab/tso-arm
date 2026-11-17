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
