# gdb script: for every thread, the words on its stack (from its stack pointer up, 256 KiB at most) that point into
# a function of a loaded object with symbols: FEX's frames below translated code, which gdb's backtrace does not get
# past (a guest signal handler running on top of FEX code it interrupted, say). Used by tests/apps_check.sh:
#   gdb -p PID -batch -x tests/stackscan.py
import gdb

LIMIT = 256 * 1024


def symbol(addr):
    try:
        s = gdb.execute(f'info symbol {addr:#x}', to_string=True).strip()
    except gdb.error:
        return None
    if s.startswith('No symbol'):
        return None
    return s


inferior = gdb.selected_inferior()
# executable mappings of files (FEX, the host's libraries): only words in them are looked up
code = []
with open(f'/proc/{inferior.pid}/maps') as f:
    for line in f:
        p = line.split()
        if len(p) > 5 and 'x' in p[1] and p[5].startswith('/'):
            a, b = (int(x, 16) for x in p[0].split('-'))
            code.append((a, b))
for thread in sorted(inferior.threads(), key=lambda t: t.num):
    thread.switch()
    frame = gdb.newest_frame()
    sp = int(frame.read_register('sp'))
    print(f'== thread {thread.num} (LWP {thread.ptid[1]}) {thread.name}: sp {sp:#x}')
    data = b''
    while len(data) < LIMIT:
        at = sp + len(data)
        try:
            data += bytes(inferior.read_memory(at, 4096 - at % 4096))
        except gdb.MemoryError:
            break
    last = None
    for off in range(0, len(data) - 7, 8):
        v = int.from_bytes(data[off:off + 8], 'little')
        if not any(a <= v < b for a, b in code):
            continue
        s = symbol(v)
        # only code: names with an offset in a text section
        if s and ' in section .text' in s and s != last:
            print(f'  sp+{off:#x}: {v:#x} {s[:200]}')
            last = s
