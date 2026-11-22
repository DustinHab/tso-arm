# Changes

## 0.4.2 (not released yet)

- Fixed in FEX: a fault of the program's own through the page protocol's views (an address it never mapped, a page
  it protected, past the end of a file it mapped) reached it with the address in the view instead of its own
  (0x6000000000 for a nil pointer). Go's runtime compares it with the address it dereferenced and took its own nil
  pointer panics for fatal faults: `go test` failed in sync/atomic, runtime/debug and time once these ran with the
  views. SIGSEGV and SIGBUS name the program's address now (`tests/faultaddr.c` in `tests/ci.sh`).
- `tso-arm learn`: a program that falls back to full ordering is timed with migratory ownership as well, where a page
  another thread writes moves to that thread instead of becoming shared (aot/stage.py); where that is more than 3 %
  faster, its profile says `migrate` and `tso-arm run` uses it. zstd, translated ahead of time, 656 instead of 721
  ms at 1.8 GHz (median of 12); Node, CPython and sort are slower with it and keep full ordering (notes section 55).
  With migration, full ordering comes when the faults hold the protocol's lock for more than 900 per mille of the
  time in three windows of 1,000 faults in a row (`TSO_VIEWS_HELD`). `TSO_VIEWS_MIGRATE=1` migrates for one run,
  `=0` not even where the profile says so.
- A change of hands within 3 ms of the one before counts as quick (was 1 ms; `TSO_VIEWS_QUICK`): fewer pages move
  back and forth.
- Translated code: an unaligned ordered store follows `dmb ishst` instead of `dmb ish`; every earlier load is
  ordered before it already. 1 to 2 % fewer cycles for zstd in full ordering; `AOT_STFULL=1` builds the old barrier.
- Fixed in FEX: a read or write past the end of a file a program mapped shared, under the page protocol, raised
  SIGBUS while FEX completed the access in its fault handler, under the protocol's lock; a handler of the program's
  that left by `siglongjmp` kept the lock, and the next fault of any thread waited forever. FEX checks first whether
  the access can be made and lets the instruction fault where it belongs otherwise.
- Fixed in FEX: processes of one program that ended at the same time wrote their profiles through the same
  temporary file.
- README: efficiency 85 % (pigz 92, xz 88, zstd 77 %), the configuration with translated functions measured as
  `tso-arm learn` leaves a program.
- `litmus/run_views.sh`, `litmus/run_aot.sh`: `FEXV` names the FEX to test, `VIEWS_ENV` adds protocol settings to
  the protocol's runs.

## 0.4.1 (2026-11-22)

A crash with signals sent from outside fixed, and the check for held-back signals made cheaper. Update from 0.4.0.
The FEX patch changed, so this release brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.4.0 or
older.

- The check at every block entry and branch back for a signal held back is a load instead of a store: no slot in the
  store buffer, pigz as FEX translates it 1.30 instead of 1.32 s (notes section 54).
- Fixed in FEX: FEX's handler for SIGSEGV ran with SIGSEGV blocked (taken from the guest's action), and a fault of
  FEX's own in it ended the process: the store at the end of a signal-deferring section to the interrupt page that a
  signal sent meanwhile by another thread had armed (`tests/sigsync.c` on GitHub's N2, 6 of 60 runs without a
  profile), or a fault of the page protocol while FEX wrote a guest frame. It runs with SIGSEGV open now.

## 0.4.0 (2026-11-22)

Asynchronous signals reach a program at an instruction start, and Go's preemption works: Go programs run with it
on, and Go's own tests under `go test` pass with it. Update from 0.3.11. The FEX patch changed, so this release
brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.11 or older.

- Fixed in FEX: a signal sent to a program (not a fault of its own) that came in while translated code, FEX's
  dispatcher or FEX's own helpers ran was delivered at once, with the state of the middle of an instruction's
  translation, or the state in memory while the registers were live elsewhere. A handler that resumes the thread
  elsewhere took that state for the truth: Go programs crashed or computed wrong results with Go's asynchronous
  preemption, under FEX without the patches as well. Such a signal now goes back into the kernel's queue, blocked
  until the thread's next block entry, branch back or system call, where the kernel delivers it with the state of
  an instruction start (notes section 54); `TSO_EXACT_SIGNALS=0` turns it off. The checks cost about 4 % in pigz's
  loops as FEX translates them, nothing measurable with the hot functions translated ahead of time (which deliver a
  signal at once, as before).
- Fixed in FEX: a signal FEX deferred in a handler and delivered after the handler had returned put the handler's
  signal mask back for good, and a signal the handler blocked was never delivered again.
- Fixed in FEX: SIGSEGV, SIGBUS, SIGILL, SIGTRAP and SIGFPE sent by another thread or process in quick succession
  (FEX leaves them open in its handlers, for faults of its own) were delivered to the program from inside FEX's
  handler, whose stack then ran the program's handler, and the next ones nested deeper until that stack ran out and
  the process crashed. They wait for the thread's next check now. During a translation FEX queued every such
  signal, past the room it reserved, and grew the queue inside the signal handler while handlers nested in it read
  it: a signal of a number that waits already merges with it now, and the queue never grows.
- `tso-arm run` no longer turns Go's preemption off (`GODEBUG=asyncpreemptoff=1`, still so with
  `TSO_EXACT_SIGNALS=0`); goroutines in long loops without calls are preempted again.
- `tests/preempt.c` (in `tests/ci.sh`): a handler that makes the interrupted thread call a routine at the
  interrupted address, as Go's preemption does, many times a second.
- `tests/sigspin.c` (in `tests/ci.sh`): a loop that waits for its signal handler, also with the loop translated
  ahead of time, where a signal is still delivered at once; and a loop of register arithmetic in Go's layout, during
  which a timer's signal must come in.
- `tests/sigsync.c` (in `tests/ci.sh`): SIGSEGV, SIGBUS, SIGILL, SIGTRAP and SIGFPE sent by another thread to a
  running loop, also without pauses between them.
- README: efficiency measured with these patches, 83 % (pigz 91, xz 88, zstd 70 %).

## 0.3.11 (2026-11-21)

Programs started under nohup keep SIGHUP ignored. Update from 0.3.10. The FEX patch changed, so this release brings
FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.10 or older.

- Fixed in FEX: a program started with a signal ignored (nohup's SIGHUP; execve keeps it ignored) saw that signal
  at its default instead. A Go program under nohup installed its handler for SIGHUP and died of the hangup nohup was
  there to keep away. FEX takes such signals as ignored for the program now (notes section 53).
- `tests/sigign.c` (in `tests/ci.sh`): signals ignored across execve.
- The patches apply to FEX's newest commit again (an include next to one FEX added).
- Go's own tests (go1.27.4, 20 packages): the same results under tso-arm and under FEX's full ordering.
- `tests/rootfs_check.sh` and `tests/soak.sh` start their programs with SIGPIPE at its default (GitHub's runner
  ignores it), and `tests/compat.sh` takes a crash without x86 order for what that mode shows.

## 0.3.10 (2026-11-21)

A thread no longer waits for good in code another thread patched. Update from 0.3.9. The FEX patch changed, so this
release brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.9 or older.

- Fixed in FEX: a thread could stay in the translation of code that another thread had overwritten. FEX's block
  linker looked up a branch's target, let go of its lock, and linked the branch after it took the lock again; when
  another thread's store threw the target away in between, the link pointed to the old translation and nothing
  undid it. A `jmp .` (which HotSpot writes over a method's entry for a moment while it patches five bytes) then
  waited there for good. The linker links to the translation the block list holds now (none: through the
  dispatcher), and a jump to itself leaves its block through a linked exit (notes section 52).
- `tests/xmc.c` patches through a `jmp .` as well (`xmc N loop`, in `tests/ci.sh`).

## 0.3.9 (2026-11-21)

Java no longer crashes now and then. Update from 0.3.8. The FEX patch changed, so this release brings FEX prebuilt
anew; `tso-arm install` replaces the one of 0.3.8 or older.

- Fixed in FEX: code another thread wrote while FEX translated it could stay translated as it was before the write,
  or as a mix of old and new bytes. FEX protected a page of guest code against writes only after it had translated
  from it; a store in between went unseen. A JIT that patches a method's entry while another thread runs into it
  was concerned: HotSpot (Java) crashed now and then, under FEX without the patches as well (4 of 80 runs). The page
  is protected before its bytes are read now, and a store waits until the translation is done and throws it away
  (notes section 52): no crash in 260 runs since.
- `tests/xmc.c` (in `tests/ci.sh`): a function patched two bytes at a time while another thread calls it; under FEX
  without the patches every run crashed.
- `tests/ci.sh` takes the test programs' exit status: a pipe into `tail` had passed one that crashed or reported a
  failure only by its status (the litmus tests report a forbidden outcome so).

## 0.3.8 (2026-11-21)

What CPython's whole test suite found with the views throughout (no fallback by fault rate). Update from 0.3.7.
The FEX patch changed, so this release brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.7 or
older.

- Fixed: a thread sent back to the dispatcher at an instruction start could go on with a guest register already set
  for a later instruction. FEX shares a constant within a block, and its register allocator put a 0 into rcx where
  the 0 was first made, before the store ahead of the `xor %ecx, %ecx` that wanted it; repeated from its start, the
  store wrote to address 8 (CPython's garbage collector unlinking an object, about one run of `test_import` in ten
  crashed; notes section 51). Constants are not shared across such instruction starts now.
- Fixed: with nearly all of a program's descriptors in use, a `vfork` (Python's `subprocess`) closed one of the
  program's own. The views took two descriptors for a pipe at every fork, which left none for FEX's pipe for vfork,
  and FEX then closed whatever numbers its pair held. A fork under the views needs no descriptor now (a word in
  shared memory and a futex), nor does FEX's vfork under the views or without a descriptor left.
- Fixed: a program could start only about a hundred threads under the views on a 39-bit address space (the
  Raspberry Pi 5's kernel): the views reserved 13 slots, 416 of its 512 GB, and FEX took some 700 MB of address
  space per thread. Now 300: the views leave a quarter to the host (11 slots there, all 15 on 48 bits), FEX's
  allocator gives back the half of each 256 MB span it only mapped for the alignment, and each thread's lookup
  cache covers the views' 16 GB window instead of 64 GB. Beyond that the program gets EAGAIN for a new thread
  instead of FEX dying.
- `TSO_VIEWS_LOG=/path` writes the views' log to a file (a vfork child logging into a pipe its waiting parent reads
  stopped both); `TSO_VIEWS_SLOTS` lowers the number of view slots.
- `tests/exactstart.c` and `tests/fdfull.c` (in `tests/ci.sh`): the unlink from CPython at a thread's exit to the
  dispatcher, and fork, vfork and posix_spawn's clone with 0 to 10 descriptors left.

## 0.3.7 (2026-11-21)

Self-modifying code under the views: a multithreaded program that wrote over code it had run could keep running
the old code. Update from 0.3.6. The FEX patch changed, so this release brings FEX prebuilt anew; `tso-arm install`
replaces the one of 0.3.6 or older.

- Fixed: code that a multithreaded program wrote over while it ran under the views kept running in its old
  translation (FEX protects the pages it translated from against writes only where FEX itself addresses guest
  memory, not in the views the translated code writes through; notes section 50). A JIT that reuses or patches its
  code was concerned, HotSpot made FEX crash at once when the protocol did not fall back. No view writes such a page
  now before FEX has seen the store and thrown the translations away.
- `tests/smc.c` (in `tests/ci.sh`): code rewritten while a second thread runs, and code written by one thread for
  another.

## 0.3.6 (2026-11-21)

FEX's own file descriptors stay out of a program's way, and `fexecve` works. Update from 0.3.5. The FEX patch
changed, so this release brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.5 or older.

- Fixed in FEX: its own descriptors (its server's socket, the root file system's directory and others) took the
  lowest free numbers, so a program started with its standard input closed read FEX's socket as stdin, a program
  run after a `posix_spawn` that closed descriptor 0 got its own executable as stdin, and a child could find and write
  into FEX's socket on a number it had not inherited. They live just below the limit on open files now, and the
  socket is hidden from `/proc/self/fd` like the others (notes section 49).
- Fixed in FEX: a program started with `fexecve` saw its arguments shifted by one (its `argv[0]` went).

## 0.3.5 (2026-11-21)

Go programs run. Nothing changed in the FEX patch: update from 0.3.4 by fetching this tso-arm; FEX stays.

- Go programs run: Go's runtime preempts goroutines with a signal and resumes them with the state its handler saw,
  which FEX does not give exactly in the middle of translated code (Go programs crashed within a second, under FEX
  without the patches as well; notes section 48). `tso-arm run` turns that preemption off
  (`GODEBUG=asyncpreemptoff=1`; `TSO_ARM_GO_PREEMPT=1` keeps it); goroutines stop at Go's own safe points then.
- `tests/compat.sh` runs a Go program as well (goroutines, channels, a mutex, and message passing through
  sync/atomic that only x86 order keeps right).

## 0.3.4 (2026-11-21)

Single-threaded programs run without the views, and signal delivery fixed: a thread that got a signal during a
system call could crash in its handler, and two faults of FEX's own crashed CPython's `test_signal`. Update from
0.3.3. The FEX patch changed, so this release brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.3
or older.

- A process with a single thread runs without views and without ordering until a second thread starts or it maps
  memory shared with another process (notes section 46). Most commands never get there: a program start costs what
  it does under FEX (40.9 against 46.8 ms), and Ubuntu's gzip, bzip2 and openssl run at 84, 75 and 68 % of the
  host's builds with the page protocol (were 79, 70 and 59 %); the distribution table's mean with learned functions
  83 instead of 80 %. `TSO_VIEWS_ASLEEP=0` starts with the views awake.
- `tests/wake.c` (in `tests/ci.sh`): code translated while the views slept does not run on with two threads.
- Fixed: a thread that got a signal during a system call could go on in its handler with registers of the
  interrupted code (its stack pointer among them) and crash, under the views whenever the handler met memory that
  another thread uses (notes section 47). FEX left the handler its "in a system call" state, and the page
  protocol's exits from a block then spilled none of the handler's registers.
- Fixed in FEX's signal delivery (FEX without the patches crashes in both, CPython's `test_signal` too): a signal
  that came in while another thread changed its action could take the handler of one action and the checks of
  the other (a guest jumping to address 1); a second signal during FEX's handler for the first ran FEX's handler
  inside it and lost the first one's frame. The action is now read as a whole, and FEX's handler runs with every
  signal blocked that it does not need itself.
- Fixed: the layer for translated libraries wrote its notes to the program's standard error, which belongs to the
  program (a test that wants it empty failed); now only on a terminal or with `TSO_AOT_LOG`. It also finds room for
  its stubs next to more libraries (every 2 MiB within branch range instead of four places).
- `tso-arm run` says so when FEX's server, which a program still running started, serves another root file system
  than `FEX_ROOTFS` names: FEX takes the root file system from its server.
- `tests/sigrace.c` (in `tests/ci.sh`): two signals at once, and one raised while another thread changes its
  action. `tests/cpython_suite.sh`: CPython's own tests of threads, signals, fork, queues and memory maps (750
  cases) against FEX's full ordering, case by case. `tests/compat.sh` runs Java as well (a parallel sort, a
  concurrent map, and message passing that only x86 order keeps right).

## 0.3.3 (2026-11-20)

Programs with large libraries start faster and need much less memory. The FEX patch changed, so this release brings
FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.2 or older.

- Programs with large libraries start faster and need much less memory: code and read-only data of a program and its
  libraries are mapped from their files instead of copied into every process (notes section 45). `ffmpeg -version`
  0.26 instead of 0.56 s and 93 instead of 266 MB, `node -e 0` 121 instead of 216 MB; a program start 46.8 instead
  of 50.5 ms (FEX's full TSO: 40.6 ms).
- `madvise(MADV_DONTNEED)` on a read-only private file mapping: its pages read the file again afterwards, not zeros.
- `tests/filemap.c` (in `tests/ci.sh`): private file mappings under the views behave as private ones.

## 0.3.2 (2026-11-20)

A crash fix, and programs with large functions much faster (ffmpeg, Node). Update from 0.3.1: a thread could die of
a segmentation fault there. The FEX patch changed, so this release brings FEX prebuilt anew; `tso-arm install`
replaces the one of 0.3.1 or older.

- Programs with large functions much faster: `tso-arm` has FEX compile multiblock units of at most 150 guest
  instructions (`FEX_MAXINST`, FEX's default 5000), so a function entered at many points is no longer compiled whole
  again from each (notes section 43). ffmpeg with x264 1.7 instead of 2.9 s, its first run 2.4 instead of 5.3 s;
  Node 5.0 instead of 8.2 s; both now faster than FEX without any ordering. Set `FEX_MAXINST` to override.
- Fixed: a thread could die of a segmentation fault (git's `pack-objects` with 4 threads, about 1 run in 5 when FEX
  compiled block by block, as it does with translated libraries). It had run into a boundary trap at the start of a
  guest jump, and before its fault handler read the trap, another thread linked the jump to its target over it; the
  handler now recognizes that case (notes section 44).
- `tests/rootfs_check.sh` also packs a git repository with 4 threads, runs make with 4 jobs and rsync.

## 0.3.1 (2026-11-20)

Faster code under the page protocol, and a profile that forgets one run's accident. Ubuntu's programs (xz, gzip,
bzip2, openssl) at 80 % of the host's own Arm builds instead of 78 %, openssl now ahead of FEX's full TSO. The FEX
patch changed, so this release brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.0 or older.

- Faster translated code under the page protocol: the full guest state is written back only at the instruction
  starts where a thread can leave its block (accesses to memory, control flow, block ends), no longer at every
  instruction (notes section 42). The views' cost for openssl's sha512 went from 31 to 13 %, for xz from 14 to 9 %;
  pigz ahead of time 92 instead of 90 %.
- The page protocol's profile no longer takes one run's accident for good: after a program's first run, a code range
  that met shared memory enters the profile only when it does so again in the next run that changes the profile
  (notes section 41). One run of Ubuntu's xz with 4 threads had added 801 ranges that every later run then ordered
  (1.4 instead of 1.26 s).
- Fixed: with `XDG_CACHE_HOME` set, FEX kept the page protocol's profiles in `~/.cache/tso-arm` anyway, so
  `tso-arm status` and `forget` did not see them; they go to `$XDG_CACHE_HOME/tso-arm` now, beside what `learn` keeps.

## 0.3.0 (2026-11-20)

Programs as distributions ship them: `tso-arm learn` translates the hot functions of a program's shared libraries
as well. And a fix for 0.2.3's vfork, which programs that start others with Python's subprocess hit: update from
0.2.3. The FEX patch changed, so this release brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.2.3
or older.

- **Shared libraries ahead of time.** `learn` splits its profile between the program and the shared libraries it
  runs and translates the hot functions of each, with the functions they call. A shared library's translation is
  kept under the library's name and build ID and serves every program that maps that library; what several programs
  learned in one library is merged. FEX takes it when the guest maps the library and gives it up when the guest
  unmaps it (dlclose). Ubuntu's xz, whose work is all in liblzma, runs at 96 % of the host's own Arm xz on the Pi
  with one thread (31.0 s against 36.9 s without the translation), 86 % with four.
- `bench/distro.sh` measures programs of the root file system (xz, gzip, bzip2, openssl) against the host's own Arm
  builds: 78 % in the geometric mean with what `learn` translated, against 61 % under FEX's full TSO; the table is
  in the README.
- `learn` times each variant with a page protocol profile of its own: one shared profile grows from run to run and
  made the later runs slower, which once had it leave out a library that made xz 30 % faster.
- Fixed (from 0.2.3): the parent of a vfork could go on while its child still ran on the parent's memory, when the
  child closed all its descriptors before execve, as Python's subprocess does; both then ran on one stack (a wrong
  byte in the child's output, or `FileNotFoundError` for a program that exists). The kernel now holds the parent
  until the child has called execve or exited.
- Fixed: `aot/elfsyms.py` missed functions without a stack frame in stripped programs and libraries (their unwind
  entry has no instructions of its own), so their callers went back into the guest for them.
- A program started with execve no longer checks the library `tso-arm run` named for its parent against its code
  (one message per function); it looks its own up.
- `tso-arm status PROGRAM` lists the shared libraries learned for it.

## 0.2.3 (2026-11-20)

Shells and programs with signal handlers. The FEX patch changed, so this release brings FEX prebuilt anew;
`tso-arm install` replaces the one of 0.2.2 or older.

- Fixed: a signal handler of the program crashed FEX, in every mode and since 0.1.0 (bash reaping a child, a timer,
  `raise`). The handler's stack overwrote the host state FEX had saved at the signal.
- Fixed: a process forked without calling execve (bash's command substitution `$(...)`, pipelines, shell scripts,
  Python's multiprocessing) went on sharing the memory that is private for the program with its parent: under the
  page protocol that memory is shared memory, mapped again into the views. Parent and child wrote into each other's
  stacks and heaps and one of them crashed. The child gets its own copy of the writable memory now, made while the
  parent waits; read-only memory stays shared until either side makes it writable, memory the program mapped shared
  stays shared, and a vfork child runs on its parent's memory as the program asked (so `posix_spawn` of a missing
  program reports the error). A fork costs about 1 ms more on the Pi (2.8 against 1.8 ms), plus the copy of a large
  heap.
- Fixed: x87 arithmetic (`long double`) could crash under the page protocol (Ubuntu's `seq`): FEX's accesses to the
  x87 registers in the thread's context went through the views.
- `tests/fork.c`, `tests/signals.c` and `tests/x87.c` run in the CI; `tests/rootfs_check.sh` compares 25 everyday
  commands of the root file system (shells, coreutils, compression, perl, Python with fork and signals) with FEX's
  full ordering.

## 0.2.2 (2026-11-20)

Programs of an x86-64 root file system learn from their earlier runs. The FEX patch changed, so this release brings
FEX prebuilt anew; `tso-arm install` replaces the one of 0.2.0 or 0.2.1.

- Fixed: programs of an x86-64 root file system (dynamically linked ones) got no page protocol profile, or one bound
  to a host program of the same path, so their later runs did not start from what the first had learned. On
  GitHub's Neoverse N2, ffmpeg went from 2.8 s to 1.7 s (FEX's full TSO: 1.7 s) and Node from 6.1 s to 5.2 s (5.1 s).
- `tso-arm rootfs` without options fetches Ubuntu 24.04 without questions.

## 0.2.1 (2026-11-20)

Dynamically linked programs right after `tso-arm rootfs`, and x86-64 programs started directly. FEX and its patches
are the same as in 0.2.0.

- Fixed: after `tso-arm rootfs`, dynamically linked programs were refused, since `tso-arm` looked for FEX's setting
  in `~/.fex-emu` only; it reads it where FEX does (`~/.config/fex-emu` when `~/.fex-emu` does not exist). Checked
  with Ubuntu 24.04 from FEX's server: x86-64 `bash`, `python3` and `sort` run, `sort` with the Arm `sort`'s output.
- `tso-arm binfmt [register | unregister]`: x86-64 programs started directly (`./program`) run through tso-arm, for
  the whole system and after a reboot (needs root); checked in the CI.
- `tests/transitions.sh` measures what a call across the border of translated code costs (on the Pi 40 ns inward,
  81 ns outward), which is why `learn` leaves out libraries of programs that cross it all the time.

## 0.2.0 (2026-11-20)

Programs as distributions ship them. `tso-arm learn` translates stripped programs built with frame pointers, the
stack protector and gcc's split-off cold parts, keeps what it translated only where that makes the program faster
on the machine at hand, and translated code returns 16-byte results right. Programs of x86-64 Ubuntu (sort, 7-Zip,
Python, ffmpeg with x264, Node) are tested on every push: the same output in every mode, as fast as under FEX's full
TSO or faster, and message passing between Node's threads that keeps x86's order. On the Raspberry Pi 5, with x86
order kept: 82 % of native speed (pigz 90 %, xz 88 %, zstd 70 %).

Install: download `tso-arm-0.2.0-linux-arm64.tar.gz`, unpack it and run `tso-arm-0.2.0/bin/tso-arm install`, or
`bin/tso-arm install` in a clone. The FEX patches changed: `tso-arm` refuses an FEX installed for 0.1.0 until
`tso-arm install` replaces it, and FEX does not use what `learn` translated with 0.1.0 (it says so; `learn`
translates it again).

- **Programs of a distribution** (`tests/compat.sh`, `tools/compat_rootfs.sh`): sort, 7-Zip, Python with threads,
  ffmpeg with x264 and Node with worker threads from x86-64 Ubuntu, run with x86 order kept, with FEX's full TSO and
  without ordering, outputs compared, on every push (`.github/workflows/compat.yml`).
- **`learn` on such programs**: functions of stripped programs from the unwind information; frame pointers; cold
  parts; thread-local storage (the stack protector's canary); calls of guest functions whose stack arguments cannot
  be told. pigz, xz and zstd built the distributions' way translate fully.
- **`learn` measures before it keeps**: the program as `tso-arm run` runs it, with the library, with it and FEX's
  multiblock, and without; a slower library is not used (`tso-arm status` says so). It stops with the program's exit
  status when the program fails with the given arguments.
- **Fixed**: translated functions return rdx as well as rax (Rust's slices, C++'s pairs), as a pair in two
  registers; libraries carry the number of their interface. A tail call from translated code into guest code could
  overwrite the guest caller's return address when the function had been entered from guest code that translated
  code had called. The escape analysis follows addresses through vector registers.
- **Newer cores**: ordered accesses with an offset in the instruction (`ldapur`, `stlur`, FEAT_LRCPC2), and unaligned
  `ldapr`/`stlr` within 16 bytes where the kernel allows them (FEAT_LSE2), each measured against a build without it
  in the CI. The test for stack objects in host memory takes one instruction instead of four.
- **CI**: the benchmark fails on a wrong output (it went on before); `.github/workflows/profile.yml` profiles a
  workload on GitHub's Arm runner on demand, per guest function, translated against FEX's own code.

## 0.1.0 (2026-11-20)

The first release: x86-64 Linux programs on 64-bit Arm with x86's memory order kept, at 83 % of native speed on a
Raspberry Pi 5 (geometric mean of pigz 90 %, xz 90 %, zstd 70 %), against 66 % for FEX's own full TSO and 23 % for
Box64 with x86 order kept.

Install: download `tso-arm-0.1.0-linux-arm64.tar.gz`, unpack it and run `tso-arm-0.1.0/bin/tso-arm install`; it
installs the prebuilt FEX in seconds. From a clone of the repository, `bin/tso-arm install` fetches the same FEX.
The prebuilt FEX runs on 64-bit Arm Linux with glibc 2.35 or newer (Ubuntu 22.04 and newer, Debian 12 and newer,
Raspberry Pi OS) and 4 KB pages; `tso-arm check` tells whether a machine fits.

- **The command** `tso-arm`: `run` (modes `tso`, `full`, `unordered`; `--stats`), `learn`, `status`, `forget`,
  `check`, `install` (prebuilt, or from source with `--source` and `--generic`), `uninstall`, `rootfs`, `version`.
- **Page protocol** in FEX: every thread reaches guest memory through a plain and an ordered view of its own; only
  memory that a second thread touches is ordered. What a run learns is kept for the next run. A program that shares
  data constantly, or runs more threads at once than there are views, goes on with full ordering.
- **Ahead of time:** `tso-arm learn` profiles a program, translates its hot functions to Arm code through C and
  checks them against a run without; later runs use them. Static and position-independent programs, and the own
  functions of dynamically linked ones (their libraries stay with FEX). Built the way distributions build them,
  pigz reaches 82 % and xz 85 %. On cores with FEAT_LRCPC2 the ordered accesses carry their offset in the
  instruction (`ldapur`, `stlur`).
- **Correctness:** litmus tests for message passing through plain and vector memory, `rep movs`, the stack and load
  buffering show no forbidden x86 outcome, also with translated functions. Every push runs them on GitHub's
  Neoverse N2; every week they run with the patches on FEX's newest commit. Cortex-A53, A72, A710, Neoverse N1 and
  V1 were tested in a full system emulation.
- **Measured on GitHub's Neoverse N2:** with x86 order kept pigz 85 % and xz 90 %, against 71 and 70 % under FEX's
  full TSO.

Known limits:

- zstd's threads hand data back and forth constantly, so it runs with full ordering (70 % on the Pi 5, about as fast
  as FEX's full TSO; on the N2 slightly below it).
- Kernels with 16 or 64 KB pages: the views stay off and FEX orders everything itself.
- Functions of shared libraries are not translated ahead of time (in the programs measured, under 2 % of the time).
- Built on FEX be66e03 (2026-11-16); the patches are in `fex/patches/`.
