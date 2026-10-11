#!/usr/bin/env bash
# darktable #3768, step 1: do the pixel integration tests give byte-identical
# outputs with fewer OpenMP threads? Runs the given tests (default: the first
# 20) twice under the heavy job lock, with all cores and with --threads <n>,
# and compares the pixels of every output.png (ImageMagick AE metric: the
# number of differing pixels must be 0; the files themselves can differ in
# metadata).
#
# darktable ignores OMP_NUM_THREADS: dt_init() calls omp_set_num_threads()
# with the number of cores unless --threads is given, so a darktable-cli
# wrapper adds --threads after --core.
#
# usage: tools/helios/bench/omp_compare.sh <install prefix> <outdir> [threads, default 4] [test...]

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
prefix="$(realpath "$1")"
out="$(realpath -m "$2")"
threads="${3:-4}"
shift 3 2> /dev/null || shift $#
integ="$src/src/tests/integration"

. "$here/lock.sh"
heavy_lock

tests=("$@")
[ ${#tests[@]} -eq 0 ] && mapfile -t tests < <(cd "$integ" && ls -d [0-9]* | head -20)

rm -rf "$out"
mkdir -p "$out/all" "$out/t$threads"
cat > "$out/cli-threads" << SH
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  args+=("\$a")
  [ "\$a" = --core ] && args+=(--threads $threads)
done
exec "$prefix/bin/darktable-cli" "\${args[@]}"
SH
chmod +x "$out/cli-threads"

# pass <name> <cli>: run the tests, keep each output.png and the timing
pass() {
  local name="$1" cli="$2" t0=$SECONDS
  (cd "$integ" \
    && DARKTABLE_TESTS_VENV="${DARKTABLE_TESTS_VENV:-$src/build/integration-venv}" \
       DARKTABLE_CLI="$cli" ./run --disable-opencl "${tests[@]}") > "$out/$name.log" 2>&1
  echo "$name: $((SECONDS - t0)) s"
  for t in "${tests[@]}"; do
    [ -f "$integ/$t/output.png" ] && cp "$integ/$t/output.png" "$out/$name/$t.png"
  done
}

pass all "$prefix/bin/darktable-cli"
pass "t$threads" "$out/cli-threads"

same=0 diff=0 missing=0
for t in "${tests[@]}"; do
  if [ ! -f "$out/all/$t.png" ] || [ ! -f "$out/t$threads/$t.png" ]; then
    missing=$((missing + 1)); echo "missing: $t"
  else
    ae=$(compare -metric AE "$out/all/$t.png" "$out/t$threads/$t.png" null: 2>&1)
    if [ "$ae" = 0 ]; then
      same=$((same + 1))
    else
      diff=$((diff + 1)); echo "differs: $t ($ae pixels)"
    fi
  fi
done
echo "pixel-identical: $same, different: $diff, missing: $missing (of ${#tests[@]})"
