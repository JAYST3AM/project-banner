#!/usr/bin/env python3
"""Compare two checksum traces and report the first divergence.

The determinism gate's tracer. Given the same seed and the same scripted events, two runs of the
battle must produce identical authoritative state tick by tick. This reports the first tick where
they part company, and which part of the state (men's positions, their condition, the formations,
or how many men each body still has) parted first - the difference between "the battle came out
differently" and "the battle is not reproducible", which is the thing being tested.

Usage:
    python trace_diff.py <trace_a.log> <trace_b.log>

Exit code 0 when every shared tick matches, 1 when one does not, 2 when there is nothing to
compare. Traces come from `gpu_crowd.tscn -- --checksum-every=N`.
"""
import re
import sys

PATTERN = re.compile(
    r"checksum \| tick\s+(\d+)\s+positions ([0-9a-f]+)\s+condition ([0-9a-f]+)"
    r"\s+formations ([0-9a-f]+)\s+standing ([0-9a-f]+)")
FIELDS = ["positions", "condition", "formations", "standing"]


def trace(path):
    """tick -> the four hashes, from whatever the log has to say about itself."""
    out = {}
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = PATTERN.search(line)
            if match:
                out[int(match.group(1))] = match.groups()[1:]
    return out


def main(path_a, path_b):
    a, b = trace(path_a), trace(path_b)
    shared = sorted(set(a).intersection(b))
    if not shared:
        print("no shared ticks: nothing to compare")
        return 2
    print("ticks traced: %d (tick %d to %d)" % (len(shared), shared[0], shared[-1]))
    first = None
    for tick in shared:
        if a[tick] != b[tick]:
            first = tick
            break
    if first is None:
        print("IDENTICAL on every traced tick - the battle is reproducible at this granularity")
        return 0
    print("first divergent tick: %d" % first)
    for index, name in enumerate(FIELDS):
        if a[first][index] != b[first][index]:
            print("  first divergent field: %-10s A=%s  B=%s"
                  % (name, a[first][index], b[first][index]))
    for index, name in enumerate(FIELDS):
        differs = sum(1 for tick in shared if a[tick][index] != b[tick][index])
        print("  %-10s differs on %d of %d traced ticks" % (name, differs, len(shared)))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
