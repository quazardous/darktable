#!/usr/bin/env bash
# darktable as launched inside the wbox compositor. The bench sets the
# HELIOS_* variables; interactive use gets a persistent dev library under
# profile/. OpenCL stays off: probing the GPU from a fresh config froze
# the development machine once.

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
prefix="${HELIOS_PREFIX:-$src/build/helios-prefix}"
configdir="${HELIOS_CONFIGDIR:-$here/profile/config}"
cachedir="${HELIOS_CACHEDIR:-$here/profile/cache}"
log="${HELIOS_DT_LOG:-$here/log/darktable.log}"

mkdir -p "$configdir" "$cachedir" "$(dirname "$log")"
# the welcome dialog of a fresh config is modal and blocks every input,
# quit included (gui/welcome.c)
args=(--configdir "$configdir" --cachedir "$cachedir" --disable-opencl
      --conf ui/show_welcome_screen=false)
if [ -n "${HELIOS_LUACMD:-}" ]; then
  args+=(--luacmd "$HELIOS_LUACMD")
fi
exec "$prefix/bin/darktable" "${args[@]}" "$@" > "$log" 2>&1
