#!/usr/bin/env bash
# renders an integration test with its history cut after step N, for each
# N given, <reps> times each, and prints the pixel hash of every render:
# the first N whose hashes differ between runs (non-determinism) or
# between machines (a CPU-dependent module) names the module at fault
# (darktable #3986)
#
# usage: tools/helios/bench/history_sweep.sh <darktable-cli> <test dir> <reps> <N>...
#   prints "<N> <operation of step N> <hash>..." with 12-character hashes

set -uo pipefail

cli="$1" dir="${2%/}" reps="$3"
shift 3
integ="$(cd "$dir/.." && pwd)"
xmp=$(ls "$dir"/*.xmp | head -1)
img=$(grep -o 'xmpMM:DerivedFrom="[^"]*"' "$xmp" | cut -d'"' -f2)
mapfile -t ops < <(grep -o 'darktable:operation="[a-z0-9_]*"' "$xmp" | cut -d'"' -f2)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for n in "$@"; do
  sed "s/darktable:history_end=\"[0-9]*\"/darktable:history_end=\"$n\"/" "$xmp" > "$work/step.xmp"
  hashes=
  for _ in $(seq "$reps"); do
    rm -rf "$work/config" "$work/out.png"
    # the options of src/tests/integration/run
    OMP_THREAD_LIMIT=4 "$cli" "$integ/images/$img" "$work/step.xmp" "$work/out.png" \
      --width 2048 --height 2048 --hq true --apply-custom-presets false \
      --core --disable-opencl --configdir "$work/config" -t 4 \
      --conf host_memory_limit=8192 --conf resourcelevel=reference --conf worker_threads=4 \
      --conf plugins/lighttable/export/force_lcms2=FALSE \
      --conf plugins/lighttable/export/pixel_interpolator=lanczos3 \
      --conf plugins/lighttable/export/pixel_interpolator_warp=bicubic \
      --conf plugins/lighttable/export/iccintent=0 > /dev/null 2>&1
    hash=$(identify -format '%#' "$work/out.png" 2> /dev/null | cut -c1-12)
    hashes="$hashes ${hash:-missing}"
  done
  op=none
  [ "$n" -ge 1 ] && [ "$n" -le "${#ops[@]}" ] && op=${ops[$((n - 1))]}
  echo "$n $op$hashes"
done
