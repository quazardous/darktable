#!/usr/bin/env bash
# which modules each integration test really runs (darktable #3986): the
# suite is run without dE through a darktable-cli wrapper that adds -d pipe
# and keeps the operations of the "process" lines. The tests' XMP
# histories, which the CI test selection reads, miss the modules the pipe
# runs by default (highlights, finalscale).
#
# usage: tools/helios/bench/modules_index.sh <install prefix> <out dir> [test...]
#   writes <out dir>/<test>.txt (one operation a line) and
#   <out dir>/modules.json ({test: [operations]})

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
prefix="$(realpath "$1")"
out="$(realpath -m "$2")"
shift 2
integ="$src/src/tests/integration"

. "$here/lock.sh"
heavy_lock

rm -rf "$out"
mkdir -p "$out/raw"
wrapper="$out/darktable-cli"
cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# run from the test's directory by ./run
"$prefix/bin/darktable-cli" "\$@" -d pipe > "$out/raw/\$(basename "\$PWD").log" 2>&1
EOF
chmod +x "$wrapper"

(cd "$integ" && DARKTABLE_CLI="$wrapper" ./run --disable-opencl --no-deltae "$@") > "$out/run.log" 2>&1

for log in "$out"/raw/*.log; do
  grep -E '^ *[0-9,.]+ +process ' "$log" | awk '{ print $5 }' | sort -u > "$out/$(basename "$log" .log).txt"
done
python3 -I - "$out" <<'EOF'
import glob, json, os, sys
out = sys.argv[1]
index = {os.path.basename(f)[:-4]: open(f).read().split()
         for f in sorted(glob.glob(os.path.join(out, "*.txt")))}
json.dump(index, open(os.path.join(out, "modules.json"), "w"), indent=1, sort_keys=True)
print(f"{len(index)} tests, {sum(1 for ops in index.values() if not ops)} without any module")
EOF
