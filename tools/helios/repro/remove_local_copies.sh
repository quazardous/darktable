#!/usr/bin/env bash
# darktable #3829: remove images whose original is gone and whose local copy
# carries edits (dt_image_safe_remove() must refuse), once with one image and
# once with two in the same remove job. The job binds its id list as one
# text value, so the check is expected to find nothing with two images.
#
# usage: tools/helios/repro/remove_local_copies.sh <outdir> [install prefix]

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
outdir="$(realpath -m "$1")"
prefix="$(realpath "${2:-$src/build/helios-prefix}")"
work="${HELIOS_BENCH_WORK:-${TMPDIR:-/tmp}/helios-bench-work}-remove"
integ="$src/src/tests/integration"

. "$src/tools/helios/bench/lib.sh"
. "$src/tools/helios/bench/lock.sh"
heavy_lock
export HELIOS_PREFIX="$prefix"
mkdir -p "$outdir"

# case <n>: n images with an edited local copy and a missing original, all
# removed in one job. Prints how many are still in the library afterwards.
run_case() {
  local n="$1"
  init_library > /dev/null
  cp "$integ"/images/{mire1.cr2,hlrecovery.arw} "$work/images/"
  {
    echo "write_sidecar_files=on import"
    echo "ask_before_remove=FALSE"
  } >> "$work/config/darktablerc"
  set_collection "$work/images"
  local status
  status=$(dbus_session_start)
  [ "$status" = ok ] || { echo "case $n: start failed: $status"; session_quit > /dev/null; return; }
  dtlua "
local dt = require 'darktable'
local imgs = {}
for _, name in ipairs({'mire1.cr2', 'hlrecovery.arw'}) do
  local i = dt.database.import('$work/images/' .. name)
  i.local_copy = true
  i.rating = 3  -- an edit, written to the local copy's XMP
  table.insert(imgs, i)
end
return #dt.database" > /dev/null
  # the originals go away: the images are now served from their local copy
  mkdir -p "$work/gone"
  mv "$work"/images/*.cr2 "$work"/images/*.arw "$work/gone/"
  local sel='{dt.database[1]}'
  [ "$n" = 2 ] && sel='{dt.database[1], dt.database[2]}'
  ctl move 1400 700 > /dev/null
  dtlua "
local dt = require 'darktable'
dt.gui.selection($sel)
dt.gui.action('lib/image/remove', '', 'activate', 1.0)
return 'ok'" > /dev/null || echo "case $n: action failed"
  sleep 5
  local left
  left=$(dtlua "return #(require 'darktable').database")
  echo "case $n: removing $n edited local copies with missing originals: $left of 2 left in the library"
  session_quit > /dev/null
  cp "$work/darktable.log" "$outdir/case$n.log" 2> /dev/null
}

run_case 1
run_case 2
