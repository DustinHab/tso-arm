#!/usr/bin/env python3
"""Test machine: chooses the functions of a static x86-64 program to translate ahead of time from a profile, and
builds the library FEX loads with TSO_AOT.

  1. One run under FEX without ordering, with perf and FEX naming its blocks: cycles per guest function.
  2. The hottest functions (at least --share percent of the guest cycles each, at most --max), glibc's string
     functions left to --strings (aot/strings_specs.sh adds them as units).
  3. Each one alone through aot/lift.py and a compile check; what the translator cannot take stays with FEX.
  4. The functions they call directly, as long as they translate too, so that translated code does not go back
     into the guest for them (up to --max functions in all).
  5. The library (aot/build.sh), then the program's output with it, without ordering and under the page protocol,
     against a run without it; a function whose library alone changes the output is left out.
  6. With --timed (as `tso-arm learn` runs it): the program as `tso-arm run` runs it, with the library and without,
     in alternating rounds (TSO_ARM_LEARN_ROUNDS, default 3); a library that makes it more than 3 % slower on this
     machine becomes OUT.slower and is not used.

The chosen functions go to OUT.list, one per line.
  aot/auto.py BINARY OUT.so [--share PCT] [--max N] [--timed] -- ARGS...
"""
import argparse
import bisect
import collections
import hashlib
import os
import re
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


def run(cmd, env=None, timeout=None):
    return subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=timeout)


def symbols(binary):
    """(address, lift.py name) of the functions, sorted (aot/elfsyms.py: the symbol table, or a stripped program's
    unwind information); a name that occurs more than once gets @address"""
    syms = [(a, n) for a, _, n in elfsyms.functions(binary)]
    counts = collections.Counter(n for _, n in syms)
    return [(a, n if counts[n] == 1 else f"{n}@{a:x}") for a, n in syms]


def load_base(binary):
    for line in run(["readelf", "-lW", binary]).stdout.splitlines():
        p = line.split()
        if p and p[0] == "LOAD":
            return int(p[2], 16)
    raise SystemExit("no LOAD segment")


def profile(binary, args, syms, work):
    data = os.path.join(work, "profile.data")
    # block by block: a block named by its start then lies within one function (a multiblock spans many)
    env = dict(os.environ, FEX_TSOENABLED="0", FEX_BLOCKJITNAMING="1", FEX_DISABLETELEMETRY="1", FEX_MULTIBLOCK="0",
               LC_ALL="C")
    subprocess.run(["perf", "record", "-q", "-e", "cycles:u", "-o", data, FEX_PROFILE, binary, *args], env=env,
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    report = run(["perf", "report", "-i", data, "--sort", "sym", "--stdio"], env=dict(os.environ, LC_ALL="C")).stdout
    base = load_base(binary)
    addrs = [a for a, _ in syms]
    pat = re.compile(re.escape(os.path.basename(binary)) + r"\+0x([0-9a-f]+)")
    share = collections.Counter()
    for line in report.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        m = pat.search(line)
        if not m:
            continue
        i = bisect.bisect_right(addrs, base + int(m.group(1), 16)) - 1
        if i >= 0:
            share[syms[i][1]] += float(line.split()[0].rstrip("%"))
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
    # direct calls of other guest functions (in a position-independent program relative to aot_base)
    return True, {int(x, 16) for x in re.findall(r"aot_guest_call\(c, (?:\(aot_base \+ )?0x([0-9a-f]+)ULL", text)}


def output_hash(env, binary, args):
    r = subprocess.run([FEX_VIEWS, binary, *args], env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=1800)
    return hashlib.md5(r.stdout).hexdigest(), r.returncode


def configs(lib):
    base = dict(os.environ, FEX_MULTIBLOCK="0", FEX_DISABLETELEMETRY="1")
    off = dict(base, FEX_TSOENABLED="0", TSO_AOT=lib)
    protocol = dict(base, TSO_VIEWS="1", TSO_VIEWS_PROFILE="none", FEX_VECTORTSOENABLED="1",
                    FEX_MEMCPYSETTSOENABLED="1", TSO_AOT=lib)
    return {"off": off, "protocol": protocol}


def run_env(lib):
    """the environment of `tso-arm run` (x86 order kept), with the library or without"""
    env = dict(os.environ, TSO_VIEWS="1", FEX_VECTORTSOENABLED="1", FEX_MEMCPYSETTSOENABLED="1",
               FEX_DISABLETELEMETRY="1")
    for k in ("TSO_AOT", "FEX_MULTIBLOCK", "FEX_TSOENABLED", "TSO_VIEWS_PROFILE"):
        env.pop(k, None)
    if lib:
        env.update(TSO_AOT=lib, FEX_MULTIBLOCK="0")
    return env


def wall(env, binary, args):
    t = time.monotonic()
    subprocess.run([FEX_VIEWS, binary, *args], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=1800)
    return time.monotonic() - t


def timed(binary, args, out):
    """step 6: keeps the library only if it does not make the program slower here"""
    rounds = max(1, int(os.environ.get("TSO_ARM_LEARN_ROUNDS", "3")))
    wall(run_env(None), binary, args)  # the page cache, and the page protocol's profile of the program
    with_lib, without = [], []
    for _ in range(rounds):
        without.append(wall(run_env(None), binary, args))
        with_lib.append(wall(run_env(out), binary, args))
    w, wo = min(with_lib), min(without)
    how = f"{w * 1000:.0f} ms with the library, {wo * 1000:.0f} ms without (x86 order kept, best of {rounds})"
    if w > wo * 1.03:
        os.replace(out, out + ".slower")
        print(f"timed: {how}: slower on this machine, not used")
    else:
        print(f"timed: {how}: kept")


def build(binary, names, out_so, work):
    specs = run(["sh", os.path.join(ROOT, "aot", "strings_specs.sh"), binary]).stdout.split()
    c = os.path.splitext(out_so)[0] + ".c"
    r = run([sys.executable, LIFT, binary, c, *names, "--strings", *specs])
    if r.returncode:
        raise SystemExit("lift failed: " + r.stderr[-400:])
    r = run(["sh", os.path.join(ROOT, "aot", "build.sh"), c, out_so])
    if r.returncode:
        raise SystemExit("build failed: " + r.stderr[-400:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("out")
    ap.add_argument("--share", type=float, default=0.2, help="least share of the guest cycles, percent")
    ap.add_argument("--max", type=int, default=40, help="most functions in all")
    ap.add_argument("--timed", action="store_true", help="keep the library only if it does not make the program slower")
    # the program's own arguments after "--", apart from ours (argparse's REMAINDER took options of ours as well)
    argv = sys.argv[1:]
    i = argv.index("--") if "--" in argv else len(argv)
    a = ap.parse_args(argv[:i])
    args = argv[i + 1:]
    binary, out = os.path.abspath(a.binary), os.path.abspath(a.out)
    for old in (out, out + ".slower", out + ".list"):
        if os.path.exists(old):
            os.remove(old)
    work = tempfile.mkdtemp(prefix="tso-auto-")
    syms = symbols(binary)
    by_addr = {addr: name for addr, name in syms}

    # the reference output; a program that fails with these arguments gives nothing to learn from
    ref, rc = output_hash(dict(os.environ, FEX_TSOENABLED="0", FEX_DISABLETELEMETRY="1"), binary, args)
    if rc:
        raise SystemExit(f"the program ends with exit status {rc} under FEX with these arguments; learn needs a run "
                         "that goes through")

    share = profile(binary, args, syms, work)
    total = sum(share.values())
    print(f"profile: {len(share)} guest functions, {total:.1f} % of the cycles in guest code")
    candidates = [n for n, s in share.most_common() if s >= a.share and not STRING_FUNCS.match(n.split("@")[0])]

    chosen, callees, failed = [], {}, {}
    for name in candidates:
        if len(chosen) >= a.max:
            break
        ok, info = try_lift(binary, name, work)
        if ok:
            chosen.append(name)
            callees[name] = info
            print(f"  hot     {share[name]:6.2f} %  {name}")
        else:
            failed[name] = info
            print(f"  stays   {share[name]:6.2f} %  {name}: {info}")

    # functions the chosen ones call directly, if they translate as well
    queue = [t for n in chosen for t in sorted(callees[n])]
    while queue and len(chosen) < a.max:
        target = queue.pop(0)
        name = by_addr.get(target)
        if not name or name in chosen or name in failed or STRING_FUNCS.match(name.split("@")[0]):
            continue
        ok, info = try_lift(binary, name, work)
        if ok:
            chosen.append(name)
            queue.extend(sorted(info))
            print(f"  callee  {share.get(name, 0):6.2f} %  {name}")
        else:
            failed[name] = info

    covered = sum(share.get(n, 0) for n in chosen)
    print(f"chosen: {len(chosen)} functions, {covered:.1f} of {total:.1f} % of the guest cycles")
    if not chosen:
        print("nothing to translate")
        return

    # build, check the output, leave out what changes it
    while True:
        build(binary, chosen, out, work)
        bad = [cfg for cfg, env in configs(out).items() if output_hash(env, binary, args)[0] != ref]
        if not bad:
            break
        print(f"output differs ({', '.join(bad)}): checking the functions one by one")
        wrong = []
        for name in chosen:
            env = dict(configs(out)[bad[0]], TSO_AOT_ONLY=name.replace("@", "_"))  # the library's name for it
            if output_hash(env, binary, args)[0] != ref:
                wrong.append(name)
        if not wrong:
            raise SystemExit("the output differs, but with no single function: not resolved")
        for name in wrong:
            print(f"  left out: {name}")
            chosen.remove(name)
        if not chosen:
            os.remove(out)
            print("nothing left to translate")
            return
    with open(out + ".list", "w") as f:
        f.write("".join(n + "\n" for n in chosen))
    print(f"library {out}: {len(chosen)} functions, output checked without ordering and under the protocol")
    if a.timed:
        timed(binary, args, out)


if __name__ == "__main__":
    main()
