#!/usr/bin/env bash
# GUI bench for ratings and color labels: label the test images through
# Lua, then show them in the lighttable with overlays always on and save a
# screenshot to <outdir>/lighttable.png, to compare across builds with
#   cmp <before>/lighttable.png <after>/lighttable.png
# This covers the thumbnail code paths (dtgtk/thumbnail.c) that the Lua
# scenario never reaches, since run.sh keeps the lighttable empty.
#
# usage: tools/helios/bench/gui_labels.sh <outdir> [install prefix]

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
init_library
cp "$integ"/images/*.{cr2,arw,raf,crw} "$work/images/"

# keep the lighttable empty while labeling, see run.sh
set_collection /helios-bench-no-such-film
cat > "$work/labels.lua" << LUA
local dt = require "darktable"
local function import(name) return dt.database.import("$work/images/" .. name) end
local cr2 = import("mire1.cr2")
local arw = import("hlrecovery.arw")
local crw = import("bayer4.crw")
local raf = import("mire1-xtrans.raf")
local raf4 = import("xtransIV.raf")
cr2.red = true
cr2.rating = 5
arw.yellow = true
arw.green = true
arw.rating = 2
crw.blue = true
crw.purple = true
crw.rating = -1
raf.red = true
raf.yellow = true
raf.green = true
raf.blue = true
raf.purple = true
raf.rating = 1
io.open("$work/labeled", "w"):close()
LUA
status=$(session "dofile('$work/labels.lua')" "$work/labeled" '')
if [ "$status" != ok ]; then
  echo "gui bench: labeling session failed: $status" >&2
  exit 1
fi

# show the film roll, three thumbnails per row, overlays always shown. The
# overlay key is per table mode (DT_THUMBTABLE_MODE_FILEMANAGER is 1) and
# per thumbnail size category (dtgtk/thumbtable.c _thumbs_get_prefs_size);
# DT_THUMBNAIL_OVERLAYS_ALWAYS_NORMAL is 3.
set_collection "$work/images"
{
  echo "plugins/lighttable/images_in_row=3"
  for size in 0 1 2 3 4; do echo "plugins/lighttable/overlays/1/$size=3"; done
} >> "$work/config/darktablerc"

status=$(session_start "io.open('$work/shown', 'w'):close()" "$work/shown" '')
if [ "$status" = ok ]; then
  # keep the pointer off the thumbnails: hovering shows a tooltip and
  # highlights the thumbnail. This spot is the empty sixth cell.
  ctl click 1100 700 > /dev/null
  # thumbnails render in the background: wait until two screenshots in a
  # row are identical
  prev="" stable=0 deadline=$((SECONDS + 120))
  while [ $SECONDS -lt $deadline ]; do
    sleep 2
    shot=$(ctl shot --name "gui-labels-$SECONDS" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["path"])')
    if [ -n "$prev" ] && cmp -s "$prev" "$shot"; then stable=1; break; fi
    prev="$shot"
  done
  if [ $stable = 1 ]; then
    # blank the version string under the logo: it gains "-dirty" with
    # uncommitted changes
    python3 -I -c 'import sys; from PIL import Image, ImageDraw
im = Image.open(sys.argv[1]); ImageDraw.Draw(im).rectangle((50, 66, 300, 86), fill=(0, 0, 0)); im.save(sys.argv[2])' \
      "$shot" "$outdir/lighttable.png"
  else
    status="screen never settled"
  fi
fi
quit=$(session_quit)
[ "$status" = ok ] && status="$quit"
echo "gui bench results in $outdir: $status"
[ "$status" = ok ]
