#!/usr/bin/env python3
"""Test machine: chooses the functions of an x86-64 program, and of the shared libraries it runs, to translate ahead
of time from a profile, and builds the libraries FEX loads: the program's with TSO_AOT, a shared library's from
TSO_AOT_DIR, where FEX looks it up under the shared library's file name and build ID when the guest maps it.

  1. One run under FEX without ordering, with perf and FEX naming its blocks: cycles per guest function. FEX names
     the program's blocks by the program's file; a shared library's blocks carry their guest address, which perf's
     records of the guest's file mappings place in the library.
  2. Per object (the program; with --libdir each shared library with a build ID as well): its hottest functions (at
     least --share percent of the guest cycles each, at most --max per object), glibc's string functions left to
     --strings (aot/strings_specs.sh adds them as units).
  3. Each one alone through aot/lift.py and a compile check; what the translator cannot take stays with FEX.
  4. The functions they call directly within their object, as long as they translate too, so that translated code
     does not go back into the guest for them.
  5. The libraries (aot/build.sh): a shared library's with the functions learned for other programs before
     (LIBDIR/NAME-BUILDID.so.list) added. Then the program's output with them, without ordering and under the page
     protocol, against a run without them; a function whose library alone changes the output is left out.
  6. With --timed (as `tso-arm learn` runs it): the program as `tso-arm run` runs it, without the libraries, with
     them, and with them and FEX's multiblock on, in alternating rounds (TSO_ARM_LEARN_ROUNDS, default 3; each
     variant with a page protocol profile of its own, from one run before the rounds); libraries
     that make it more than 3 % slower on this machine are not used (the program's becomes OUT.slower, the shared
     libraries' are not installed), and OUT.multiblock records that multiblock was 3 % faster (when much of the
     program stays with FEX).

The program's chosen functions go to OUT.list, a shared library's to LIBDIR/NAME-BUILDID.so.list.
  aot/auto.py BINARY OUT.so [--libdir DIR] [--share PCT] [--max N] [--timed] -- ARGS...
"""
import argparse
import bisect
import collections
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

import elfsyms  # aot/elfsyms.py, beside this file

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIFT = os.path.join(ROOT, "aot", "lift.py")
# FEX with the tso-arm patches (TSO_ARM_FEX, as `tso-arm learn` sets it); it also names its blocks for perf
FEX_VIEWS = os.environ.get("TSO_ARM_FEX") or os.path.expanduser("~/opt/fex-views/bin/FEX")
FEX_PROFILE = os.environ.get("TSO_ARM_PROFILE_FEX") or FEX_VIEWS
STRING_FUNCS = re.compile(r"^__(mem(move|cpy|pcpy|set)|wmemset)_")
# perf's record of an executable file mapping: [address(length) @ file offset ...]: r-xp path
MMAP = re.compile(r"PERF_RECORD_MMAP2? \S+: \[(0x[0-9a-f]+)\((0x[0-9a-f]+)\) @ (0x[0-9a-f]+|\d+)[^\]]*\]: r-xp (/\S+)")
C_ENV = dict(os.environ, LC_ALL="C")


def run(cmd, env=None, timeout=None):
    return subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=timeout)


_symbols = {}


def symbols(binary):
    """(address, lift.py name) of the functions, sorted (aot/elfsyms.py: the symbol table, or a stripped object's
    unwind information); a name that occurs more than once gets @address"""
    if binary not in _symbols:
        syms = [(a, n) for a, _, n in elfsyms.functions(binary)]
        counts = collections.Counter(n for _, n in syms)
        _symbols[binary] = [(a, n if counts[n] == 1 else f"{n}@{a:x}") for a, n in syms]
    return _symbols[binary]


def load_base(binary):
    for line in run(["readelf", "-lW", binary]).stdout.splitlines():
        p = line.split()
        if p and p[0] == "LOAD":
            return int(p[2], 16)
    raise SystemExit("no LOAD segment")


_segments = {}


def file_to_address(path, offset):
    """the address in an object's own layout of a file offset in one of its loaded segments"""
    if path not in _segments:
        segs = []
        for line in run(["readelf", "-lW", path]).stdout.splitlines():
            p = line.split()
            if p and p[0] == "LOAD":
                segs.append((int(p[1], 16), int(p[2], 16), int(p[4], 16)))  # offset, address, size in the file
        _segments[path] = segs
    for off, addr, size in _segments[path]:
        if off <= offset < off + size:
            return addr + offset - off
    return offset


def is_x86_64(path, cache={}):
    if path not in cache:
        try:
            with open(path, "rb") as f:
                h = f.read(20)
            cache[path] = len(h) == 20 and h[:4] == b"\x7fELF" and h[4] == 2 and int.from_bytes(h[18:20], "little") == 62
        except OSError:
            cache[path] = False
    return cache[path]


def build_id_key(path):
    """NAME-BUILDID (the build ID's first 16 hex digits), under which FEX looks an object's library up in TSO_AOT_DIR;
    None without a build ID"""
    p = os.path.realpath(path)
    m = re.search(r"Build ID:\s*([0-9a-f]{16})", run(["readelf", "-n", p], env=C_ENV).stdout)
    return f"{os.path.basename(p)}-{m.group(1)}" if m else None


def profile(binary, args, work):
    """{object path: Counter(function name: percent of the cycles)}"""
    data = os.path.join(work, "profile.data")
    # block by block: a block named by its start then lies within one function (a multiblock spans many)
    env = dict(os.environ, FEX_TSOENABLED="0", FEX_BLOCKJITNAMING="1", FEX_DISABLETELEMETRY="1", FEX_MULTIBLOCK="0",
               LC_ALL="C")
    for k in ("TSO_AOT", "TSO_AOT_DIR", "TSO_AOT_FOR", "TSO_VIEWS"):
        env.pop(k, None)
    subprocess.run(["perf", "record", "-q", "-e", "cycles:u", "-o", data, FEX_PROFILE, binary, *args], env=env,
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    report = run(["perf", "report", "-i", data, "--sort", "sym", "--stdio"], env=C_ENV).stdout
    maps = []
    for m in MMAP.finditer(run(["perf", "script", "-i", data, "--show-mmap-events"], env=C_ENV).stdout):
        path = os.path.realpath(m.group(4))
        if is_x86_64(path):
            s = int(m.group(1), 16)
            maps.append((s, s + int(m.group(2), 16), int(m.group(3), 0), path))
    main = os.path.realpath(binary)
    base = load_base(binary)
    named = re.compile(re.escape(os.path.basename(binary)) + r"\+0x([0-9a-f]+)")
    jit = re.compile(r"JIT_0x([0-9a-f]+)_")
    share = collections.defaultdict(collections.Counter)

    def add(path, addr, pct):
        syms = symbols(path)
        i = bisect.bisect_right([a for a, _ in syms], addr) - 1
        if i >= 0:
            share[path][syms[i][1]] += pct

    for line in report.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        try:
            pct = float(line.split()[0].rstrip("%"))
        except ValueError:
            continue
        m = named.search(line)
        if m:
            add(main, base + int(m.group(1), 16), pct)
            continue
        m = jit.search(line)
        if m:
            rip = int(m.group(1), 16)
            for s, e, off, path in maps:
                if s <= rip < e:
                    add(path, file_to_address(path, rip - s + off), pct)
                    break
    return share


def try_lift(binary, name, work):
    """(True, set of direct guest call targets) or (False, reason)"""
    c = os.path.join(work, "one.c")
    r = run([sys.executable, LIFT, binary, c, name])
    if r.returncode:
        return False, (r.stderr.strip().splitlines() or ["?"])[-1][:120]
    r = run(["clang", "-fsyntax-only", "-march=armv8.2-a+rcpc", "-I", os.path.join(ROOT, "aot"), "-Wno-unused-label",
             "-Wno-unused-variable", "-Wno-unused-but-set-variable", c])
    if r.returncode:
        return False, "does not compile: " + (r.stderr.strip().splitlines() or ["?"])[0][:100]
    text = open(c).read()
    # direct calls of other guest functions (in a position-independent object relative to aot_base)
    return True, {int(x, 16) for x in re.findall(r"aot_guest_call\(c, (?:\(aot_base \+ )?0x([0-9a-f]+)ULL", text)}


def plain_env():
    env = dict(os.environ)
    for k in ("TSO_AOT", "TSO_AOT_DIR", "TSO_AOT_FOR", "TSO_AOT_ONLY", "FEX_MULTIBLOCK", "FEX_TSOENABLED",
              "TSO_VIEWS_PROFILE", "TSO_VIEWS"):
        env.pop(k, None)
    return env


def with_libraries(env, lib, libdir):
    if lib:
        env["TSO_AOT"] = lib
    if libdir:
        env["TSO_AOT_DIR"] = libdir
    return env


def output_hash(env, binary, args):
    r = subprocess.run([FEX_VIEWS, binary, *args], env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=1800)
    return hashlib.md5(r.stdout).hexdigest(), r.returncode


def configs(lib, libdir):
    base = dict(plain_env(), FEX_MULTIBLOCK="0", FEX_DISABLETELEMETRY="1")
    off = with_libraries(dict(base, FEX_TSOENABLED="0"), lib, libdir)
    protocol = with_libraries(dict(base, TSO_VIEWS="1", TSO_VIEWS_PROFILE="none", FEX_VECTORTSOENABLED="1",
                                   FEX_MEMCPYSETTSOENABLED="1"), lib, libdir)
    return {"off": off, "protocol": protocol}


def run_env(lib, libdir, multiblock=False):
    """the environment of `tso-arm run` (x86 order kept), with the libraries or without; with them, FEX's
    multiblock off (block by block is cheaper when the hot code is translated) or on (better when much is not)"""
    env = dict(plain_env(), TSO_VIEWS="1", FEX_VECTORTSOENABLED="1", FEX_MEMCPYSETTSOENABLED="1",
               FEX_DISABLETELEMETRY="1")
    if lib or libdir:
        with_libraries(env, lib, libdir)
        env["FEX_MULTIBLOCK"] = "1" if multiblock else "0"
    return env


def wall(env, binary, args):
    t = time.monotonic()
    subprocess.run([FEX_VIEWS, binary, *args], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=1800)
    return time.monotonic() - t


def timed(binary, args, out, lib, libdir, work):
    """step 6: True if the libraries do not make the program slower here; OUT.multiblock where multiblock is
    faster"""
    rounds = max(1, int(os.environ.get("TSO_ARM_LEARN_ROUNDS", "3")))
    # each variant with a page protocol profile of its own: a profile only grows (code ranges that met shared
    # memory run ordered from then on), and one shared by all would make the later runs slower than the earlier
    envs = {"without": run_env(None, None), "with": run_env(lib, libdir), "multiblock": run_env(lib, libdir, multiblock=True)}
    for k, env in envs.items():
        env["TSO_VIEWS_PROFILE"] = os.path.join(work, f"timed-{k}.prof")
        wall(env, binary, args)  # the page cache, and the variant's profile
    t = {k: [] for k in envs}
    for _ in range(rounds):
        for k, env in envs.items():
            t[k].append(wall(env, binary, args))
    w, wm, wo = min(t["with"]), min(t["multiblock"]), min(t["without"])
    best = min(w, wm)
    how = (f"{w * 1000:.0f} ms with the libraries, {wm * 1000:.0f} ms with them and multiblock, {wo * 1000:.0f} ms "
           f"without (x86 order kept, best of {rounds})")
    if os.path.exists(out + ".multiblock"):
        os.remove(out + ".multiblock")
    if best > wo * 1.03:
        print(f"timed: {how}: slower on this machine, not used")
        return False
    if wm < w * 0.97:
        open(out + ".multiblock", "w").close()
        print(f"timed: {how}: kept, with multiblock")
    else:
        print(f"timed: {how}: kept")
    return True


def build(binary, names, out_so):
    specs = run(["sh", os.path.join(ROOT, "aot", "strings_specs.sh"), binary]).stdout.split()
    c = os.path.splitext(out_so)[0] + ".c"
    r = run([sys.executable, LIFT, binary, c, *names, "--strings", *specs])
    if r.returncode:
        raise SystemExit("lift failed: " + r.stderr[-400:])
    r = run(["sh", os.path.join(ROOT, "aot", "build.sh"), c, out_so])
    if r.returncode:
        raise SystemExit("build failed: " + r.stderr[-400:])


def choose(obj, share, a, work):
    """steps 2 to 4 for one object: the names of its functions to translate"""
    label = os.path.basename(obj)
    by_addr = {addr: name for addr, name in symbols(obj)}
    candidates = [n for n, s in share.most_common() if s >= a.share and not STRING_FUNCS.match(n.split("@")[0])]
    chosen, callees, failed = [], {}, {}
    for name in candidates:
        if len(chosen) >= a.max:
            break
        ok, info = try_lift(obj, name, work)
        if ok:
            chosen.append(name)
            callees[name] = info
            print(f"  hot     {share[name]:6.2f} %  {label}: {name}")
        else:
            failed[name] = info
            print(f"  stays   {share[name]:6.2f} %  {label}: {name}: {info}")
    # functions the chosen ones call directly, if they translate as well
    queue = [t for n in chosen for t in sorted(callees[n])]
    while queue and len(chosen) < a.max:
        target = queue.pop(0)
        name = by_addr.get(target)
        if not name or name in chosen or name in failed or STRING_FUNCS.match(name.split("@")[0]):
            continue
        ok, info = try_lift(obj, name, work)
        if ok:
            chosen.append(name)
            queue.extend(sorted(info))
            print(f"  callee  {share.get(name, 0):6.2f} %  {label}: {name}")
        else:
            failed[name] = info
    return chosen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("out")
    ap.add_argument("--libdir", help="where the shared libraries' libraries go (FEX's TSO_AOT_DIR)")
    ap.add_argument("--share", type=float, default=0.2, help="least share of the guest cycles, percent")
    ap.add_argument("--max", type=int, default=40, help="most functions per object")
    ap.add_argument("--timed", action="store_true", help="keep the libraries only if they do not make the program slower")
    # the program's own arguments after "--", apart from ours (argparse's REMAINDER took options of ours as well)
    argv = sys.argv[1:]
    i = argv.index("--") if "--" in argv else len(argv)
    a = ap.parse_args(argv[:i])
    args = argv[i + 1:]
    binary, out = os.path.abspath(a.binary), os.path.abspath(a.out)
    libdir = os.path.abspath(a.libdir) if a.libdir else None
    for old in (out, out + ".slower", out + ".list", out + ".multiblock", out + ".libs"):
        if os.path.exists(old):
            os.remove(old)
    work = tempfile.mkdtemp(prefix="tso-auto-")
    stage = os.path.join(work, "libs")  # the shared libraries' libraries until they are checked
    os.makedirs(stage)
    main_obj = os.path.realpath(binary)

    # the reference output; a program that fails with these arguments gives nothing to learn from
    ref, rc = output_hash(dict(plain_env(), FEX_TSOENABLED="0", FEX_DISABLETELEMETRY="1"), binary, args)
    if rc:
        raise SystemExit(f"the program ends with exit status {rc} under FEX with these arguments; learn needs a run "
                         "that goes through")

    share = profile(binary, args, work)
    total = sum(sum(c.values()) for c in share.values())
    print(f"profile: {sum(len(c) for c in share.values())} guest functions, {total:.1f} % of the cycles in guest code")
    for obj, c in sorted(share.items(), key=lambda x: -sum(x[1].values())):
        print(f"  {sum(c.values()):6.2f} %  {os.path.basename(obj)}")

    # units: (object, functions, library path); the program's first
    units = []
    for obj in sorted(share, key=lambda o: (o != main_obj, -sum(share[o].values()))):
        if obj != main_obj:
            if not libdir:
                continue
            key = build_id_key(obj)
            if not key:
                print(f"  {os.path.basename(obj)}: no build ID, stays with FEX")
                continue
        chosen = choose(obj, share[obj], a, work)
        if obj == main_obj:
            if chosen:
                units.append([obj, chosen, out])
            continue
        # what other programs chose in this shared library before stays in its library
        known = os.path.join(libdir, key + ".so.list")
        if os.path.exists(known):
            for name in open(known).read().split():
                if name not in chosen and try_lift(obj, name, work)[0]:
                    chosen.append(name)
        if chosen:
            units.append([obj, chosen, os.path.join(stage, key + ".so")])
    covered = sum(share[o].get(n, 0) for o, names, _ in units for n in names)
    print(f"chosen: {sum(len(n) for _, n, _ in units)} functions in {len(units)} object(s), {covered:.1f} of "
          f"{total:.1f} % of the guest cycles")
    if not units:
        print("nothing to translate")
        return

    # build, check the output, leave out what changes it
    while True:
        for obj, names, so in units:
            build(obj, names, so)
        lib = out if any(so == out for _, _, so in units) else None
        bad = [cfg for cfg, env in configs(lib, stage).items() if output_hash(env, binary, args)[0] != ref]
        if not bad:
            break
        print(f"output differs ({', '.join(bad)}): checking the functions one by one")
        wrong = set()
        for _, names, _ in units:
            for name in names:
                env = dict(configs(lib, stage)[bad[0]], TSO_AOT_ONLY=name.replace("@", "_"))  # the library's name for it
                if output_hash(env, binary, args)[0] != ref:
                    wrong.add(name)
        if not wrong:
            raise SystemExit("the output differs, but with no single function: not resolved")
        for name in sorted(wrong):
            print(f"  left out: {name}")
        for u in units:
            u[1] = [n for n in u[1] if n not in wrong]
        for u in units:
            if not u[1] and os.path.exists(u[2]):
                os.remove(u[2])
        units = [u for u in units if u[1]]
        if not units:
            print("nothing left to translate")
            return
    for obj, names, so in units:
        with open(so + ".list", "w") as f:
            f.write("".join(n + "\n" for n in names))
        print(f"library {os.path.basename(obj)}: {len(names)} functions, output checked without ordering and under the protocol")
    lib = out if any(so == out for _, _, so in units) else None
    keep = True
    if a.timed:
        keep = timed(binary, args, out, lib, stage, work)
    if not keep:
        if lib:
            os.replace(out, out + ".slower")
        return
    # the shared libraries' libraries into LIBDIR, each in one step (a program starting meanwhile sees the old or the
    # new one)
    for obj, names, so in units:
        if so == out:
            print(f"learned: {os.path.basename(obj)}: {len(names)} functions")
            continue
        for ext in (".so", ".so.list", ".c"):
            src = os.path.splitext(so)[0] + ext
            if os.path.exists(src):
                dst = os.path.join(libdir, os.path.basename(src))
                shutil.copyfile(src, dst + ".tmp")
                os.replace(dst + ".tmp", dst)
        print(f"learned: {os.path.basename(obj)}: {len(names)} functions (for every program that runs it)")
    # the shared libraries this program learned for (`tso-arm status` and `run`)
    keys = [os.path.basename(os.path.splitext(so)[0]) for _, _, so in units if so != out]
    if keys:
        with open(out + ".libs", "w") as f:
            f.write("".join(k + "\n" for k in keys))


if __name__ == "__main__":
    main()
