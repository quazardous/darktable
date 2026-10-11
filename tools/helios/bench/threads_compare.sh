#!/usr/bin/env bash
# darktable #3807: render pixel integration tests with several OpenMP thread
# counts and compare the outputs pixel by pixel. The integration runner
# always passes -t 4, so a bug that needs -t below (or above) the core count
# never shows on a machine with 4 cores: this rewrites -t through a
# darktable-cli wrapper. A variant "cpus2" keeps -t 4 but runs under
# taskset on 2 cores, so that darktable sees fewer cores than requested.
#
# usage: tools/helios/bench/threads_compare.sh <install prefix> <outdir> [variant...] [-- test...]
#   variants: t1 t2 t4 tall cpus2 (default: t1 t2 tall cpus2); the first one
#   is the reference the others are compared with
#   tests: default the first 20 integration tests

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
prefix="$(realpath "$1")"
out="$(realpath -m "$2")"
shift 2
variants=()
while [ $# -gt 0 ] && [ "$1" != -- ]; do variants+=("$1"); shift; done
[ "${1:-}" = -- ] && shift
tests=("$@")
[ ${#variants[@]} -eq 0 ] && variants=(t1 t2 tall cpus2)
integ="$src/src/tests/integration"
[ ${#tests[@]} -eq 0 ] && mapfile -t tests < <(cd "$integ" && ls -d [0-9]* | head -20)

. "$here/lock.sh"
heavy_lock

rm -rf "$out"
mkdir -p "$out"

# wrapper <variant>: a darktable-cli that rewrites the -t of the runner
wrapper() {
  local v="$1" threads cpus=""
  case "$v" in
    t[0-9]*) threads="${v#t}" ;;
    tall) threads="$(nproc)" ;;
    cpus2) threads=4; cpus=0-1 ;;
    *) echo "unknown variant: $v" >&2; exit 1 ;;
  esac
  cat > "$out/cli-$v" << SH
#!/usr/bin/env bash
args=()
skip=0
for a in "\$@"; do
  if [ \$skip = 1 ]; then args+=($threads); skip=0; continue; fi
  args+=("\$a")
  [ "\$a" = -t ] && skip=1
done
exec ${cpus:+taskset -c $cpus} "$prefix/bin/darktable-cli" "\${args[@]}"
SH
  chmod +x "$out/cli-$v"
}

for v in "${variants[@]}"; do
  wrapper "$v"
  t0=$SECONDS
  rm -f "$integ"/[0-9]*/output.png
  (cd "$integ" \
    && DARKTABLE_TESTS_VENV="${DARKTABLE_TESTS_VENV:-$src/build/integration-venv}" \
       DARKTABLE_CLI="$out/cli-$v" ./run --disable-opencl "${tests[@]}") > "$out/$v.log" 2>&1
  mkdir -p "$out/$v"
  for t in "${tests[@]}"; do
    [ -f "$integ/$t/output.png" ] && cp "$integ/$t/output.png" "$out/$v/$t.png"
  done
  echo "$v: $((SECONDS - t0)) s, $(ls "$out/$v" | wc -l) outputs"
done

ref="${variants[0]}"
python="${DARKTABLE_TESTS_VENV:-$src/build/integration-venv}/bin/python"
for v in "${variants[@]:1}"; do
  echo "== $ref vs $v"
  "$python" -I - "$out/$ref" "$out/$v" << 'PY'
import os, sys
import numpy as np
from PIL import Image
a_dir, b_dir = sys.argv[1], sys.argv[2]
same = 0
names = sorted(set(os.listdir(a_dir)) | set(os.listdir(b_dir)))
for n in names:
    a, b = os.path.join(a_dir, n), os.path.join(b_dir, n)
    if not (os.path.exists(a) and os.path.exists(b)):
        print(f"  {n[:-4]}: missing output")
        continue
    x = np.asarray(Image.open(a).convert("RGB"), dtype=np.int16)
    y = np.asarray(Image.open(b).convert("RGB"), dtype=np.int16)
    if x.shape != y.shape:
        print(f"  {n[:-4]}: size differs")
        continue
    d = np.abs(x - y).max(axis=2)
    if not d.any():
        same += 1
        continue
    print(f"  {n[:-4]}: {int((d > 0).sum())} px, max {int(d.max())}/255")
print(f"  identical: {same} of {len(names)}")
PY
done
