#!/usr/bin/env python3
"""What each thread of the given processes waits in: its system call (/proc/PID/task/TID/syscall), for a futex its
address, which mapping holds it (/proc/PID/maps: a library's data, the stack, an anonymous one) and the word there.
Needs to be allowed to look into the processes (root, or ptrace_scope 0).
    tests/waits.py PID..."""
import sys

# Arm64 system call numbers of the waits a thread is found in
NAMES = {98: 'futex', 22: 'epoll_pwait', 73: 'ppoll', 63: 'read', 72: 'pselect6', 101: 'nanosleep',
         115: 'clock_nanosleep', 422: 'futex_time64', 449: 'futex_waitv', 441: 'epoll_pwait2'}


def maps(pid):
    out = []
    try:
        with open(f'/proc/{pid}/maps') as f:
            for line in f:
                p = line.split()
                a, b = (int(x, 16) for x in p[0].split('-'))
                out.append((a, b, p[1], int(p[2], 16), p[5] if len(p) > 5 else ''))
    except OSError:
        pass
    return out


def where(m, addr):
    for a, b, perm, off, path in m:
        if a <= addr < b:
            return f'{path or "[anonymous]"} {perm} +{addr - a + off:#x} (mapping {a:#x}-{b:#x})'
    return 'no mapping'


def word(pid, addr):
    try:
        with open(f'/proc/{pid}/mem', 'rb') as f:
            f.seek(addr)
            return int.from_bytes(f.read(4), 'little')
    except (OSError, ValueError, OverflowError):
        return None


for pid in sys.argv[1:]:
    m = maps(pid)
    try:
        import os
        tids = sorted(os.listdir(f'/proc/{pid}/task'), key=int)
    except OSError:
        continue
    print(f'== {pid}')
    for tid in tids:
        base = f'/proc/{pid}/task/{tid}'
        try:
            comm = open(f'{base}/comm').read().strip()
            sc = open(f'{base}/syscall').read().split()
        except OSError as e:
            print(f'{tid} ?: {e}')
            continue
        if not sc or sc[0] in ('running', '-1'):
            print(f'{tid} {comm}: {" ".join(sc)}')
            continue
        nr = int(sc[0])
        args = [int(x, 16) for x in sc[1:7]]
        sp, pc = (int(x, 16) for x in sc[7:9])
        s = f'{tid} {comm}: {NAMES.get(nr, nr)}'
        if nr in (98, 422):
            op = args[1] & 0x7f
            s += f' op {op}{" private" if args[1] & 0x80 else ""} val {args[2]:#x} at {args[0]:#x} (word {word(pid, args[0])}): {where(m, args[0])}'
        else:
            s += ' ' + ' '.join(f'{x:#x}' for x in args[:3])
        s += f'; pc {where(m, pc)}'
        print(s)
