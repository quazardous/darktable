#!/usr/bin/env bash
# equivalence bench: run the scenario on a throwaway library and write
# normalized results into <outdir>, to compare with
#   diff -r -x timing.txt <before> <after>
#
# usage: tools/helios/bench/run.sh <outdir> [install prefix]
#
# the prefix defaults to build/helios-prefix, filled with
#   cmake --install build --prefix build/helios-prefix
# darktable runs offscreen in a wbox compositor (tools/helios/wbox), one
# session with the scenario run through its D-Bus Lua method (lib.sh dtlua);
# WBOX_VISIBLE=1 shows the window.
#
# the work directory path is fixed (paths are stored in the database and
# the sidecars), so two runs are only comparable when made on the same
# machine with the same HELIOS_BENCH_WORK.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
outdir="$(realpath -m "$1")"
prefix="$(realpath "${2:-$src/build/helios-prefix}")"
work="${HELIOS_BENCH_WORK:-${TMPDIR:-/tmp}/helios-bench-work}"
integ="$src/src/tests/integration"

. "$here/lib.sh"

rm -rf "$outdir"
mkdir -p "$outdir/xmp"
export HELIOS_PREFIX="$prefix"
init_dirs
cp "$integ"/images/*.{cr2,arw,raf,crw} "$work/images/"

export HELIOS_BENCH_IMAGES="$work/images"
export HELIOS_BENCH_INTEG="$integ"
export HELIOS_BENCH_OUT="$outdir/reads.txt"

# the lighttable then shows a collection that matches nothing: rendering
# thumbnails in the background reloads, upgrades and rewrites histories and
# image rows, racing with the scenario and making runs differ.
set_collection /helios-bench-no-such-film

start=$(date +%s.%N)
# one darktable session, the scenario run through its D-Bus Lua method
status=$(dbus_session_start)
if [ "$status" = ok ] && ! HELIOS_DTLUA_TIMEOUT=600 dtlua "dofile('$here/scenario.lua') return 'ok'" > /dev/null; then
  status="scenario call failed"
fi
end=$(date +%s.%N)
# sidecars are written by a background job that picks up its queue every
# 0.25 s and sleeps 1 s when idle, and drops what is still queued when
# darktable quits (control/jobs/sidecar_jobs.c, darktable #3955): give it
# one full cycle so that the scenario's last writes land
sleep 1.5
quit=$(session_quit)
[ "$status" = ok ] && status="$quit"

python3 -I "$here/normalize.py" db "$work/config/library.db" > "$outdir/library.txt"
python3 -I "$here/normalize.py" db "$work/config/data.db" > "$outdir/data.txt"
# sidecars of removed images stay on disk but are no longer catalog state;
# darktable may still rewrite one late, with stale values
python3 -I "$here/normalize.py" sidecars "$work/config/library.db" | while read -r x; do
  [ -e "$work/images/$x" ] || continue
  python3 -I "$here/normalize.py" xmp "$work/images/$x" > "$outdir/xmp/$x"
done

printf 'scenario %.2fs\n' "$(echo "$end - $start" | bc)" > "$outdir/timing.txt"
echo "bench results in $outdir: $status, $(tail -1 "$outdir/reads.txt" 2> /dev/null), $(cat "$outdir/timing.txt")"
[ "$status" = ok ] && grep -qx 'SCENARIO OK' "$outdir/reads.txt"
