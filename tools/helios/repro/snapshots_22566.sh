#!/usr/bin/env bash
# run the Lua reproducers of darktable-org/darktable#22559 / #22566 (from the
# issue's logs-and-reproducers.zip) in wbox on one build: each script in a
# fresh library, image A opened in the darkroom, and reports whether
# darktable crashed or reached "still alive", with its log lines and the
# screenshots the scripts take. The scripts call `import -window root`,
# which is X11 only: their captures go through wbox_ctl.py shot instead.
#
# usage: tools/helios/repro/snapshots_22566.sh <scripts dir> <outdir> [install prefix]

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
scripts="$(realpath "$1")"
outdir="$(realpath -m "$2")"
prefix="$(realpath "${3:-$src/build/helios-prefix}")"
work="${HELIOS_BENCH_WORK:-${TMPDIR:-/tmp}/helios-bench-work}-snapshots"

. "$src/tools/helios/bench/lib.sh"
. "$src/tools/helios/bench/lock.sh"
heavy_lock
export HELIOS_PREFIX="$prefix"
rm -rf "$outdir"
mkdir -p "$outdir"

# a capture command for the scripts: wbox screenshot copied to $1
cat > "$outdir/wboxshot" << SH
#!/usr/bin/env bash
mkdir -p "\$(dirname "\$1")"
p=\$("$wbox_python" "$src/tools/helios/wbox/wbox_ctl.py" shot "$wbox_config" -s name=darktable-bench --name "snap-\$(basename "\$1" .png)" \
  | "$wbox_python" -I -c 'import json,sys; print(json.load(sys.stdin)["path"])')
cp "\$p" "\$1"
SH
chmod +x "$outdir/wboxshot"

for script in "$scripts"/*.lua; do
  name=$(basename "$script" .lua)
  init_library
  mkdir -p "$work/snaprepro/imgs"
  # two distinct color images: monochrome and vignetting must show
  magick rose: -resize 1200x800\! "$work/images/imgA.jpg"
  magick logo: -resize 1200x800\! "$work/snaprepro/imgs/imgB.jpg"
  status=$(session "local dt = require 'darktable'; dt.database.import('$work/images/imgA.jpg'); io.open('$work/ready-import', 'w'):close()" "$work/ready-import" '')
  if [ "$status" != ok ]; then echo "$name: setup failed: $status"; continue; fi
  set_collection "$work/images"

  sed -e "s|import -window root |$outdir/wboxshot |" \
      -e "s|/tmp/snaprepro|$outdir/$name|g" \
      -e "s|$outdir/$name/imgs|$work/snaprepro/imgs|g" \
      "$script" > "$work/$name.lua"
  cat > "$work/start.lua" << LUA
local dt = require "darktable"
dofile("$work/$name.lua")
local img = nil
for _, i in ipairs(dt.database) do if i.filename == "imgA.jpg" then img = i end end
dt.gui.selection({img})
dt.gui.views.darkroom.display_image(img)
dt.gui.current_view(dt.gui.views.darkroom)
LUA
  HELIOS_START_TIMEOUT=300 status=$(session_start "dofile('$work/start.lua')" "$work/darktable.log" 'still alive')
  sleep 1
  quit=$(session_quit)
  cp "$work/darktable.log" "$outdir/$name.log"
  crashed=$(grep -cE "reporting a segfault|backtrace|Segmentation" "$outdir/$name.log")
  echo "$name: $status (quit: $quit, crash markers: $crashed)"
  grep -E "^\[(ten|ids)\]" "$outdir/$name.log" | sed 's/^/    /'
done
