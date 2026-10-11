#!/usr/bin/env bash
# run the equivalence scenario <runs> times with the race kept
# (HELIOS_BENCH_RACY=1: thumbnail crawler on, no settle) and count the runs
# where hlrecovery.arw loses the rating set by the scenario: darktable
# writes back a stale image struct after a full load (darktable #22569)
#
# usage: tools/helios/repro/lost_rating.sh <outdir> <runs> [install prefix]

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
outdir="$(realpath -m "$1")"
runs="$2"
prefix="$(realpath "${3:-$src/build/helios-prefix}")"
lost=0
for i in $(seq 1 "$runs"); do
  HELIOS_BENCH_RACY=1 "$src/tools/helios/bench/run.sh" "$outdir/run$i" "$prefix" > /dev/null 2>&1
  # rating=1 is expected after the import and after the sidecar only
  n=$(grep -c $'^hlrecovery.arw#0\trating=1\t' "$outdir/run$i/reads.txt" 2> /dev/null || echo 0)
  if [ "$n" -gt 2 ]; then lost=$((lost + 1)); echo "run $i: rating lost"; else echo "run $i: ok"; fi
done
echo "lost the rating in $lost of $runs runs"
