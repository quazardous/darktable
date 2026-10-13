#!/usr/bin/env bash
# Compare the kept outputs of two commits, on the bench box: the verdict of
# a base-vs-branch check, computed where the outputs are rather than
# downloaded (darktable #3958). The pixel, run and gui-* jobs keep their
# outputs under <results>/<job>/<commit>; whichever jobs both commits have
# are compared.
#
# usage: tools/helios/bench/compare_results.sh <results> <base commit> <new commit> <out>
#   prints one line per check; exit status 1 when anything changed or is
#   missing on one side; pixel difference maps go to <out>/maps

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
results="$1" base="$2" new="$3" out="$4"
python="${DARKTABLE_TESTS_VENV:-/opt/dt-tests-venv}/bin/python"
status=0 compared=0

for job in pixel pixel-fast run gui-labels gui-metadata gui-tags; do
  a="$results/$job/$base" b="$results/$job/$new"
  if [ ! -d "$a" ] || [ ! -d "$b" ]; then
    [ -d "$a" ] || [ -d "$b" ] && { echo "$job: only on one side"; status=1; }
    continue
  fi
  compared=$((compared + 1))
  case "$job" in
    pixel|pixel-fast)
      "$python" "$here/compare_outputs.py" "$a" "$b" "$out/maps-$job" > "$out/$job.txt" || status=1
      echo "$job: $(tail -1 "$out/$job.txt")"
      grep -E '^(noise|changed|missing)' "$out/$job.txt" | sed 's/^/  /' ;;
    run)
      if diff -rq -x timing.txt "$a" "$b" > "$out/run.txt"; then
        echo "run: identical"
      else
        echo "run: differs"; sed 's/^/  /' "$out/run.txt"; status=1
      fi ;;
    gui-*)
      for f in $(cd "$a" && find . -name '*.png' | sort); do
        if [ ! -f "$b/$f" ]; then echo "$job ${f#./}: missing"; status=1; continue; fi
        if "$python" -c 'import sys, numpy, imageio.v3 as iio
sys.exit(0 if numpy.array_equal(iio.imread(sys.argv[1]), iio.imread(sys.argv[2])) else 1)' "$a/$f" "$b/$f"; then
          echo "$job ${f#./}: identical"
        else
          echo "$job ${f#./}: differs"; status=1
        fi
      done ;;
  esac
done
[ $compared -gt 0 ] || { echo "nothing to compare between $base and $new"; status=1; }
exit $status
