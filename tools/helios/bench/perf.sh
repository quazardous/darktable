#!/usr/bin/env bash
# perf bench: time catalog operations on a synthetic 100,000-image library,
# <runs> times, and write <outdir>/perf.tsv (operation, run, seconds) plus
# the median per operation in <outdir>/median.tsv. Compare two builds with
#   tools/helios/bench/perf_compare.py <before> <after>
# Never run it while building: CPU load moves every timing.
#
# usage: tools/helios/bench/perf.sh <outdir> [runs] [install prefix]

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
outdir="$(realpath -m "$1")"
runs="${2:-5}"
prefix="$(realpath "${3:-$src/build/helios-prefix}")"
base="${HELIOS_BENCH_WORK:-${TMPDIR:-/tmp}/helios-bench-work}-perf"
integ="$src/src/tests/integration"
fixture="$base/fixture"

. "$here/lib.sh"
. "$here/lock.sh"
heavy_lock
export HELIOS_PREFIX="$prefix" HELIOS_QUIT_TIMEOUT=600

# the synthetic library is built once and reused by every run and build;
# delete $fixture to rebuild it (e.g. after a schema change)
if [ ! -e "$fixture/done" ]; then
  work="$base/build"
  init_library
  cp "$integ/images/mire1.cr2" "$work/images/"
  status=$(session "require('darktable').database.import('$work/images/mire1.cr2'); io.open('$work/imported', 'w'):close()" "$work/imported" '')
  if [ "$status" != ok ]; then
    echo "perf bench: fixture import failed: $status" >&2
    exit 1
  fi
  python3 -I "$here/make_perf_library.py" "$work/config/library.db" "$work/config/data.db"
  rm -rf "$fixture"
  cp -r "$work/config" "$fixture"
  touch "$fixture/done"
fi

rm -rf "$outdir"
mkdir -p "$outdir"
for i in $(seq 1 "$runs"); do
  work="$base/run"
  rm -rf "$work"
  mkdir -p "$work"
  cp -r "$fixture" "$work/config"
  rm -f "$work/config/done"
  export HELIOS_CONFIGDIR="$work/config" HELIOS_CACHEDIR="$work/cache" HELIOS_DT_LOG="$work/darktable.log"
  export HELIOS_PERF_OUT="$work/perf.txt"
  set_collection "%"
  t0=$(date +%s.%N)
  status=$(session "io.open('$work/started', 'w'):close(); dofile('$here/perf.lua')" "$work/perf.txt" '^PERF (OK|FAILED)')
  [ "$status" = ok ] && grep -qx 'PERF OK' "$work/perf.txt" || {
    echo "perf bench: run $i failed: $status $(tail -1 "$work/perf.txt" 2> /dev/null)" >&2
    exit 1
  }
  started=$(stat -c %.9Y "$work/started")
  printf 'startup to lua\t%s\t%.3f\n' "$i" "$(echo "$started - $t0" | bc)" >> "$outdir/perf.tsv"
  grep -v '^PERF' "$work/perf.txt" | awk -F'\t' -v run="$i" '{ printf "%s\t%s\t%s\n", $1, run, $2 }' >> "$outdir/perf.tsv"
  echo "perf run $i done"
done

python3 -I - "$outdir/perf.tsv" > "$outdir/median.tsv" << 'PY'
import statistics, sys
times = {}
order = []
for line in open(sys.argv[1]):
    op, _, t = line.rstrip("\n").split("\t")
    if op not in times:
        order.append(op)
    times.setdefault(op, []).append(float(t))
for op in order:
    v = times[op]
    print(f"{op}\t{statistics.median(v):.3f}\t{min(v):.3f}\t{max(v):.3f}")
PY
cat "$outdir/median.tsv"
