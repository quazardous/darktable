#!/usr/bin/env bash
# run lua_library.lua <runs> times, each in a fresh config, under a wbox
# compositor (darktable calls gtk_init), and summarize the outcomes
#
# usage: tools/helios/repro/lua_library.sh <outdir> [runs] [install prefix]

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
outdir="$(realpath -m "$1")"
runs="${2:-20}"
prefix="$(realpath "${3:-$src/build/helios-prefix}")"
integ="$src/src/tests/integration"
wbox_config="$src/tools/helios/wbox/config.yaml"
wbox_python="${WBOX_PYTHON:-$(head -1 "$(readlink -f "$(command -v wbox-mcp)")" | sed 's/^#!//')}"

mkdir -p "$outdir"
# require "darktable" looks for darktable.so on LUA_CPATH
mkdir -p "$outdir/lib"
ln -sf "$prefix/lib64/darktable/libdarktable.so" "$outdir/lib/darktable.so"

for i in $(seq 1 "$runs"); do
  run="$outdir/run$i"
  rm -rf "$run"; mkdir -p "$run/config" "$run/images"
  cp "$integ"/images/{bayer4.crw,hlrecovery.arw,mire1.cr2,mire1-xtrans.raf,xtransIV.raf} "$run/images/"
  cat > "$run/launch.sh" << SH
#!/usr/bin/env bash
cd "$run"
LUA_CPATH="$outdir/lib/?.so;;" timeout 120 lua "$here/lua_library.lua" "$prefix" "$run/config" "$run/images" "$run/out.txt" > "$run/log.txt" 2>&1
echo \$? > "$run/status"
SH
  chmod +x "$run/launch.sh"
  "$wbox_python" "$src/tools/helios/wbox/wbox_ctl.py" up "$wbox_config" \
    -s name=darktable-repro -s app.command="$run/launch.sh" > /dev/null 2>&1
  for _ in $(seq 1 130); do [ -e "$run/status" ] && break; sleep 1; done
  "$wbox_python" "$src/tools/helios/wbox/wbox_ctl.py" down "$wbox_config" -s name=darktable-repro > /dev/null 2>&1
  status=$(cat "$run/status" 2>/dev/null || echo none)
  result=$(tail -1 "$run/out.txt" 2>/dev/null || echo "no output")
  echo "run $i: exit=$status $result"
done
