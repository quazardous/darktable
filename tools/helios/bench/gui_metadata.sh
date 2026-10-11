#!/usr/bin/env bash
# GUI bench for metadata: set metadata and version names through Lua, then
# save two settled screenshots to compare across builds with cmp:
#   <outdir>/lighttable.png  metadata module on a two-image selection
#                            (libs/metadata.c gui_update)
#   <outdir>/darkroom.png    duplicate manager of an image with versions
#                            (libs/duplicate.c)
# Neither path is reached by the Lua scenario of run.sh.
#
# usage: tools/helios/bench/gui_metadata.sh <outdir> [install prefix]

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
outdir="$(realpath -m "$1")"
prefix="$(realpath "${2:-$src/build/helios-prefix}")"
work="${HELIOS_BENCH_WORK:-${TMPDIR:-/tmp}/helios-bench-work}-gui-metadata"
integ="$src/src/tests/integration"

. "$here/lib.sh"

rm -rf "$outdir"
mkdir -p "$outdir"
export HELIOS_PREFIX="$prefix"
init_library
cp "$integ"/images/*.{cr2,arw,raf,crw} "$work/images/"

# keep the lighttable empty while setting up, see run.sh
set_collection /helios-bench-no-such-film
cat > "$work/setup.lua" << LUA
local dt = require "darktable"
local function import(name) return dt.database.import("$work/images/" .. name) end
local cr2 = import("mire1.cr2")
local arw = import("hlrecovery.arw")
import("bayer4.crw")
-- shared and distinct values: the module shows a value common to the
-- selection differently from a mixed one
cr2.title = "shared title"
arw.title = "shared title"
cr2.description = "only on the cr2"
arw.creator = "only on the arw"
local v1 = cr2:duplicate()
local v2 = cr2:duplicate()
cr2.version_name = "original"
v1.version_name = "first version"
v2.version_name = "second version"
dt.gui.selection({cr2, arw})
io.open("$work/ready-setup", "w"):close()
LUA
status=$(session "dofile('$work/setup.lua')" "$work/ready-setup" '')
if [ "$status" != ok ]; then
  echo "gui bench: setup session failed: $status" >&2
  exit 1
fi

# blank the version string under the logo: it gains "-dirty" with
# uncommitted changes
mask_version() {
  python3 -I -c 'import sys; from PIL import Image, ImageDraw
im = Image.open(sys.argv[1]); ImageDraw.Draw(im).rectangle((50, 66, 300, 86), fill=(0, 0, 0)); im.save(sys.argv[2])' \
    "$1" "$2"
}

# wait until two screenshots in a row are identical, then save the last one
# to <file>. Prints "ok" or what went wrong.
settled_shot() {
  local name="$1" file="$2" prev="" shot deadline=$((SECONDS + 120))
  while [ $SECONDS -lt $deadline ]; do
    sleep 2
    shot=$(ctl shot --name "$name-$SECONDS" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["path"])')
    if [ -n "$prev" ] && cmp -s "$prev" "$shot"; then
      mask_version "$shot" "$file"
      echo ok
      return
    fi
    prev="$shot"
  done
  echo "screen never settled"
}

# lighttable with the film roll and the metadata module expanded; the
# selection is kept in the library from the setup session
set_collection "$work/images"
{
  echo "plugins/lighttable/metadata/expanded=TRUE"
  echo "plugins/lighttable/images_in_row=3"
} >> "$work/config/darktablerc"
status=$(session_start "io.open('$work/shown-lt', 'w'):close()" "$work/shown-lt" '')
if [ "$status" = ok ]; then
  # keep the pointer off the thumbnails, hovering changes the images acted
  # on: click the empty left panel. Not an empty cell of the grid (clears the
  # selection) nor the bottom panel (the timeline adds a date rule)
  ctl click 150 600 > /dev/null
  status=$(settled_shot gui-metadata-lt "$outdir/lighttable.png")
fi
quit=$(session_quit)
[ "$status" = ok ] && status="$quit"
if [ "$status" != ok ]; then
  echo "gui bench results in $outdir: lighttable: $status"
  exit 1
fi

# darkroom on the cr2, duplicate manager expanded
echo "plugins/darkroom/duplicate/expanded=TRUE" >> "$work/config/darktablerc"
cat > "$work/darkroom.lua" << LUA
local dt = require "darktable"
for _, img in ipairs(dt.database) do
  if img.filename == "mire1.cr2" and img.duplicate_index == 0 then
    dt.gui.selection({img})
  end
end
dt.gui.current_view(dt.gui.views.darkroom)
io.open("$work/shown-dr", "w"):close()
LUA
status=$(session_start "dofile('$work/darkroom.lua')" "$work/shown-dr" '')
if [ "$status" = ok ]; then
  status=$(settled_shot gui-metadata-dr "$outdir/darkroom.png")
fi
quit=$(session_quit)
[ "$status" = ok ] && status="$quit"
echo "gui bench results in $outdir: $status"
[ "$status" = ok ]
