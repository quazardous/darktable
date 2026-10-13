#!/usr/bin/env bash
# darktable #3842: a sidecar write queued just before quitting is lost.
# Sidecars are written by a background job (control/jobs/sidecar_jobs.c)
# that picks up its queue every 0.25 s and sleeps 1 s when idle; once
# darktable stops it exits without looking at the queue again. The rating
# is set through D-Bus and darktable quits from the same Lua call (or <wait>
# s later, the control), and the sidecar is compared with the database.
# Quitting with ctrl+q instead leaves the job time to pick up its queue, and
# hides the bug (darktable #3955).
#
# usage: tools/helios/repro/sidecar_at_quit.sh [runs] [wait] [install prefix]

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
runs="${1:-5}"
wait="${2:-0}"
prefix="$(realpath "${3:-$src/build/helios-prefix}")"
work="${HELIOS_BENCH_WORK:-${TMPDIR:-/tmp}/helios-bench-work}-sidecar"
integ="$src/src/tests/integration"

. "$src/tools/helios/bench/lib.sh"
export HELIOS_PREFIX="$prefix"

lost=0 failed=0
for i in $(seq "$runs"); do
  init_dirs
  cp "$integ/images/mire1.cr2" "$work/images/"
  if [ "$(dbus_session_start)" != ok ]; then
    failed=$((failed + 1)); session_quit > /dev/null; continue
  fi
  # import, then let the import's own sidecar write land
  if ! dtlua "local dt = require 'darktable' dt.database.import('$work/images/mire1.cr2') return 'ok'" > /dev/null; then
    failed=$((failed + 1)); session_quit > /dev/null; continue
  fi
  sleep 3
  quit="dt.gui.action('global/quit', '', 'activate', 1.0)"
  if [ "$wait" = 0 ]; then
    dtlua "local dt = require 'darktable' dt.database[1].rating = 3 $quit return 'ok'" > /dev/null
  else
    dtlua "local dt = require 'darktable' dt.database[1].rating = 3 return 'ok'" > /dev/null
    sleep "$wait"
    dtlua "local dt = require 'darktable' $quit return 'ok'" > /dev/null
  fi
  sleep 2
  session_quit > /dev/null
  db=$(sqlite3 "$work/config/library.db" "SELECT flags & 7 FROM images")
  xmp=$(grep -o 'xmp:Rating="[0-9-]*"' "$work/images/mire1.cr2.xmp" | grep -o '[0-9-]*')
  echo "run $i: database rating $db, sidecar rating $xmp"
  [ "$db" = "$xmp" ] || lost=$((lost + 1))
done
echo "wait ${wait}s: $lost/$((runs - failed)) sidecars stale, $failed runs failed"
