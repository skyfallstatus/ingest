#!/usr/bin/env python3
"""Turns an iotrace dump into wall-clock attribution. Every instant is shared equally between what was running then;
an instant with no system call running anywhere counts as user-space (hashing, Swift, waiting on a lock not traced)."""
import struct, sys, collections

CATS = "read write fullsync fsync msync mmap munmap open close meta rename unlink mkdir times trunc prealloc fcntl syncvol wait list".split()
SIDE = {0: "", 1: " card", 2: " drive"}

def load(path):
    d = open(path, "rb").read()
    numer, denom = struct.unpack_from("II", d, 0)
    k = numer / denom / 1e9
    out = [struct.unpack_from("QQQIBB2x", d, o) for o in range(8, len(d) - 31, 32)]
    t0 = min(e[0] for e in out)
    return [((a - t0) * k, (b - t0) * k, n, th, CATS[c] + SIDE[s]) for a, b, n, th, c, s in out], k

def attribute(ev):
    points = []
    for i, e in enumerate(ev):
        if e[4] == "wait": continue      # a parked thread isn't doing anything: what it waits for is on the other thread
        points.append((e[0], 1, e[4])); points.append((e[1], -1, e[4]))
    points.sort(key=lambda p: (p[0], p[1]))
    active = collections.Counter()
    share = collections.Counter()
    last = points[0][0]
    for t, d, c in points:
        dt = t - last
        if dt > 0:
            n = sum(active.values())
            if n:
                for k, v in active.items():
                    if v: share[k] += dt * v / n
            else:
                share["(user space)"] += dt
        last = t
        active[c] += d
    return share, points[-1][0]

def main():
    ev, _ = load(sys.argv[1])
    share, wall = attribute(ev)
    total = collections.Counter(); count = collections.Counter(); byts = collections.Counter(); worst = {}
    for a, b, n, th, c in ev:
        total[c] += b - a; count[c] += 1; byts[c] += n; worst[c] = max(worst.get(c, 0), b - a)
    print(f"wall {wall:.2f} s, {len(ev)} calls, {len({e[3] for e in ev})} threads")
    print(f"{'stage':<16}{'wall s':>9}{'%':>7}{'busy s':>9}{'calls':>9}{'mean ms':>10}{'max ms':>10}{'MB/s':>9}")
    for k, v in share.most_common():
        mean = total[k] / count[k] * 1e3 if count[k] else 0
        rate = byts[k] / total[k] / 1e6 if total[k] and byts[k] and k.split()[0] in ("read", "write") else 0
        print(f"{k:<16}{v:>9.2f}{v / wall * 100:>6.1f}%{total[k]:>9.2f}{count[k]:>9}{mean:>10.3f}{worst.get(k, 0) * 1e3:>10.1f}{rate:>9.0f}")
    print(f"accounted {sum(share.values()):.2f} s of {wall:.2f} s; 'wait' is parked threads and is not in the sum: {total['wait']:.2f} thread-seconds")

if __name__ == "__main__":
    main()
