#!/usr/bin/env bash
# GUI bench for tags: tag two images through Lua, one tag shared and one
# not, then save a settled screenshot of the image information module on
# that two-image selection (libs/metadata_view.c gui_update, which decides
# from per-tag image counts whether the tags line is common), to compare
# across builds with cmp <before>/lighttable.png <after>/lighttable.png
#
# usage: tools/helios/bench/gui_tags.sh <outdir> [install prefix]

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
outdir="$(realpath -m "$1")"
prefix="$(realpath "${2:-$src/build/helios-prefix}")"
work="${HELIOS_BENCH_WORK:-${TMPDIR:-/tmp}/helios-bench-work}-gui-tags"
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
local shared = dt.tags.create("helios|shared")
local only = dt.tags.create("helios|only arw")
dt.tags.attach(shared, cr2)
dt.tags.attach(shared, arw)
dt.tags.attach(only, arw)
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
  echo "plugins/lighttable/metadata_view/expanded=TRUE"
  # only the rows this bench is about; the list is longer than the screen
  echo "plugins/lighttable/metadata_view/visible=filename,tags,categories,|filmroll,|image id,|group id,|version,|full path,|local copy,|import timestamp,|change timestamp,|export timestamp,|print timestamp,|flags,|model,|maker,|lens,|aperture,|exposure,|exposure bias,|exposure program,|white balance,|flash,|metering mode,|focal length,|35mm equiv focal length,|crop factor,|focus distance,|ISO,|datetime,|width,|height,|export width,|export height,|latitude,|longitude,|elevation,|creator,|publisher,|title,|description,|rights,|notes,|version_name,|image_id,|PreservedFileName"
  echo "plugins/lighttable/images_in_row=3"
} >> "$work/config/darktablerc"
status=$(session_start "io.open('$work/shown-lt', 'w'):close()" "$work/shown-lt" '')
if [ "$status" = ok ]; then
  # keep the pointer off the thumbnails, hovering changes the images acted
  # on: click the empty left panel. Not an empty cell of the grid (clears the
  # selection) nor the bottom panel (the timeline adds a date rule)
  ctl click 150 600 > /dev/null
  status=$(settled_shot gui-tags-lt "$outdir/lighttable.png")
fi
quit=$(session_quit)
[ "$status" = ok ] && status="$quit"
echo "gui bench results in $outdir: $status"
[ "$status" = ok ]

