#!/usr/bin/env bash
# GUI bench for the presets popup menus: open a utility module's menu
# (module groups) and a processing module's menu (color calibration), both
# in the darkroom, by clicking their presets button, and save
# a screenshot of each to <outdir>/lib-menu.png and <outdir>/iop-menu.png, to
# compare across builds with
#   cmp <before>/lib-menu.png <after>/lib-menu.png
# The menus are built by dt_gui_presets_popup_menu_show() (gui/presets.c),
# which no other bench reaches.
#
# usage: tools/helios/bench/gui_presets.sh <outdir> [install prefix]

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
outdir="$(realpath -m "$1")"
prefix="$(realpath "${2:-$src/build/helios-prefix}")"
work="${HELIOS_BENCH_WORK:-${TMPDIR:-/tmp}/helios-bench-work}-gui"
integ="$src/src/tests/integration"

. "$here/lib.sh"

rm -rf "$outdir"
mkdir -p "$outdir"
export HELIOS_PREFIX="$prefix"
init_dirs
cp "$integ"/images/mire1.cr2 "$work/images/"
set_collection /helios-bench-no-such-film

# screenshot <name>: wait until two screenshots in a row are identical,
# blank the version string under the logo, save to <outdir>/<name>.png
screenshot() {
  local prev="" shot="" stable=0 deadline=$((SECONDS + 60))
  while [ $SECONDS -lt $deadline ]; do
    sleep 2
    shot=$(ctl shot --name "gui-presets-$1-$SECONDS" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["path"])')
    if [ -n "$prev" ] && cmp -s "$prev" "$shot"; then stable=1; break; fi
    prev="$shot"
  done
  [ $stable = 1 ] || return 1
  python3 -I -c 'import sys; from PIL import Image, ImageDraw
im = Image.open(sys.argv[1]); ImageDraw.Draw(im).rectangle((50, 66, 300, 86), fill=(0, 0, 0)); im.save(sys.argv[2])' \
    "$shot" "$outdir/$1.png"
}

status=$(dbus_session_start)
if [ "$status" = ok ] && ! dtlua "
local dt = require 'darktable'
local img = dt.database.import('$work/images/mire1.cr2')
dt.gui.selection({img})
return 'ok'" > /dev/null; then
  status="import failed"
fi
# the darkroom, on the selected image
if [ "$status" = ok ] && ! dtlua "
local dt = require 'darktable'
dt.gui.current_view(dt.gui.views.darkroom)
return 'ok'" > /dev/null; then
  status="darkroom failed"
fi
[ "$status" = ok ] && sleep 5
# the presets buttons sit at fixed places in the bench's 1600x1000 window.
# module groups' is right of the group icons, and it ships presets (the
# workflows), which a fresh config gives no other utility module
[ "$status" = ok ] && ctl click 1574 287 > /dev/null
[ "$status" = ok ] && { screenshot lib-menu || status="lib menu never settled"; }
[ "$status" = ok ] && ctl key Escape > /dev/null
# color calibration is the last module of the default group, applied by
# the scene-referred workflow, so it has built-in presets
[ "$status" = ok ] && ctl click 1558 559 > /dev/null
[ "$status" = ok ] && { screenshot iop-menu || status="iop menu never settled"; }
[ "$status" = ok ] && ctl key Escape > /dev/null
quit=$(session_quit)
[ "$status" = ok ] && status="$quit"
echo "gui bench results in $outdir: $status"
[ "$status" = ok ]
