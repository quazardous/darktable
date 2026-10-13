#!/usr/bin/env python3
"""Compare two perf.sh result directories, operation by operation.

An operation is flagged when its median moved by more than the tolerance and
the new median lies outside the whole range (min..max) of the old runs, so
that run-to-run noise alone does not flag it. Comparing the two ranges
instead let a bimodal regression through (3 slow runs out of 5).

usage: perf_compare.py <before dir> <after dir> [tolerance, default 0.05]
"""

import sys


def medians(path):
    rows = {}
    for line in open(f"{path}/median.tsv"):
        op, med, lo, hi = line.rstrip("\n").split("\t")
        rows[op] = (float(med), float(lo), float(hi))
    return rows


def main():
    before, after = medians(sys.argv[1]), medians(sys.argv[2])
    tolerance = float(sys.argv[3]) if len(sys.argv) > 3 else 0.05
    flagged = 0
    print(f"{'operation':24} {'before':>9} {'after':>9} {'change':>8}  verdict")
    for op, (b, blo, bhi) in before.items():
        if op not in after:
            continue
        a, alo, ahi = after[op]
        change = (a - b) / b if b else 0.0
        verdict = "ok"
        if abs(change) > tolerance:
            if a > bhi:
                verdict = "SLOWER"
            elif a < blo:
                verdict = "faster"
            else:
                verdict = "within noise"
        if verdict == "SLOWER":
            flagged += 1
        print(f"{op:24} {b:9.3f} {a:9.3f} {change:+8.1%}  {verdict}")
    sys.exit(1 if flagged else 0)


if __name__ == "__main__":
    main()
