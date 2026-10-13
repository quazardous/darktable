#!/usr/bin/env bash
# measure the lighttable timeline on the perf bench's 100,000-image library:
# a dated copy of the fixture (one capture every 10 s), bottom panel shown,
# then the time from launch until darktable has quit. The quit key is only
# handled once the GUI thread is free again, so the time includes the
# timeline draw (quadratic in the collection size, darktable #3715).
#
# usage: tools/helios/bench/timeline.sh [install prefix]
# needs the fixture built by perf.sh

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
prefix="$(realpath "${1:-$src/build/helios-prefix}")"
base="${HELIOS_BENCH_WORK:-${TMPDIR:-/tmp}/helios-bench-work}-perf"
work="$base/timeline"

. "$here/lib.sh"
. "$here/lock.sh"
heavy_lock
export HELIOS_PREFIX="$prefix" HELIOS_QUIT_TIMEOUT=3600 HELIOS_START_TIMEOUT=3600

[ -e "$base/fixture/done" ] || { echo "timeline: run perf.sh first to build the fixture" >&2; exit 1; }
rm -rf "$work"
mkdir -p "$work"
cp -r "$base/fixture" "$work/config"
rm -f "$work/config/done"
sqlite3 "$work/config/library.db" \
  "UPDATE main.images SET datetime_taken = 63325115613000000 + id * 10000000"
export HELIOS_CONFIGDIR="$work/config" HELIOS_CACHEDIR="$work/cache" HELIOS_DT_LOG="$work/darktable.log"
set_collection "%"
sed -i '/^lighttable\/ui\/1\/bottom_visible=/d' "$work/config/darktablerc"
echo 'lighttable/ui/1/bottom_visible=TRUE' >> "$work/config/darktablerc"

t0=$SECONDS
status=$(session_start "io.open('$work/started', 'w'):close()" "$work/started" '')
[ "$status" = ok ] || { echo "timeline: start failed: $status" >&2; exit 1; }
quit=$(session_quit)
echo "launch to quit: $((SECONDS - t0)) s ($quit)"
