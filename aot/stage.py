#!/usr/bin/env python3
"""For a program that falls back to full ordering as `tso-arm run` runs it: whether migratory ownership is faster on
this machine (pages another thread writes move to that thread instead of becoming shared, so both keep plain
accesses; notes section 55). The program runs with full ordering as the fallback gives it and with migration from its
start, each with a page protocol profile of its own learned in two runs before, in alternating rounds; if migration is
more than 3 % faster, one more run with TSO_VIEWS_MIGRATE=learn writes the program's profile with it, and
`tso-arm run` migrates from then on. Most programs past the fault budget are slower with it (Node, CPython, sort),
zstd is faster. `tso-arm learn` runs this as its last step (aot/auto.py --timed).

  aot/stage.py BINARY [--profile PATH] [--rounds N] [--env K=V ...] -- ARGS...
    --profile   the profile to write (default: the program's own in ~/.cache/tso-arm, as `tso-arm run` uses it)
    --env       the run's environment besides the protocol's (TSO_AOT=..., FEX_MULTIBLOCK=0, ...)
    TSO_ARM_FEX the FEX to run (default ~/opt/fex-views/bin/FEX)
"""
import argparse
import os
import subprocess
import sys
import tempfile
import time

FEX = os.environ.get("TSO_ARM_FEX") or os.path.expanduser("~/opt/fex-views/bin/FEX")


def protocol_env(extra=None):
    """the environment of `tso-arm run` (x86 order kept), without a profile path of its own"""
    env = dict(os.environ)
    for k in ("TSO_VIEWS_PROFILE", "TSO_VIEWS_MIGRATE", "FEX_TSOENABLED"):
        env.pop(k, None)
    env.update(TSO_VIEWS="1", FEX_VECTORTSOENABLED="1", FEX_MEMCPYSETTSOENABLED="1", FEX_DISABLETELEMETRY="1")
    env.update(extra or {})
    return env


def wall(env, binary, args):
    t = time.monotonic()
    subprocess.run([FEX, binary, *args], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=1800)
    return time.monotonic() - t


def falls_back(profile):
    try:
        with open(profile) as f:
            return any(line.startswith("fallback") for line in f)
    except OSError:
        return False


def choose(binary, args, env, work, rounds=3, profile=None, log=print):
    """True if migration was faster and the profile now says so"""
    fb = dict(env, TSO_VIEWS_PROFILE=os.path.join(work, "stage-fallback.prof"))
    mig = dict(env, TSO_VIEWS_MIGRATE="1", TSO_VIEWS_PROFILE=os.path.join(work, "stage-migrate.prof"))
    for e in (fb, mig):
        for _ in range(2):
            wall(e, binary, args)  # the page cache, and the variant's profile
    if not falls_back(fb["TSO_VIEWS_PROFILE"]):
        log("stage: the program does not fall back to full ordering, nothing to choose")
        return False
    t = {"fallback": [], "migrate": []}
    for _ in range(max(1, rounds)):
        t["fallback"].append(wall(fb, binary, args))
        t["migrate"].append(wall(mig, binary, args))
    tf, tm = min(t["fallback"]), min(t["migrate"])
    how = f"{tm * 1000:.0f} ms with migration, {tf * 1000:.0f} ms with full ordering (best of {max(1, rounds)})"
    if falls_back(mig["TSO_VIEWS_PROFILE"]) or tm >= tf * 0.97:
        log(f"stage: {how}: full ordering kept")
        return False
    learn = dict(env, TSO_VIEWS_MIGRATE="learn")
    learn.pop("TSO_VIEWS_PROFILE", None)
    if profile:
        learn["TSO_VIEWS_PROFILE"] = profile
    wall(learn, binary, args)
    log(f"stage: {how}: the profile says migrate")
    return True


def main():
    if "--" not in sys.argv:
        sys.exit(__doc__)
    k = sys.argv.index("--")
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("--profile")
    ap.add_argument("--rounds", type=int, default=int(os.environ.get("TSO_ARM_LEARN_ROUNDS", "3")))
    ap.add_argument("--env", action="append", default=[])
    a = ap.parse_args(sys.argv[1:k])
    extra = dict(e.split("=", 1) for e in a.env)
    with tempfile.TemporaryDirectory(prefix="tso-arm-stage-") as work:
        choose(a.binary, sys.argv[k + 1:], protocol_env(extra), work, a.rounds, a.profile)


if __name__ == "__main__":
    main()
