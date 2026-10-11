# shared by the bench scripts: drive darktable in a wbox compositor.
# Expects $src and $work to be set by the caller.

# numbers are printed with the locale decimal separator otherwise
export LC_ALL=C.UTF-8 LANG=C.UTF-8 LANGUAGE=

wbox_config="$src/tools/helios/wbox/config.yaml"
wbox_python="${WBOX_PYTHON:-$(head -1 "$(readlink -f "$(command -v wbox-mcp)")" | sed 's/^#!//')}"

ctl() {
  "$wbox_python" "$src/tools/helios/wbox/wbox_ctl.py" "$1" "$wbox_config" \
    -s name=darktable-bench "${@:2}"
}

dt_running() {
  pgrep -f -- "--configdir $work/config" > /dev/null
}

# start darktable and wait for <pattern> in <file>, or for <file> to exist
# when <pattern> is empty, written by the Lua command. Prints "ok" or what
# went wrong; darktable is left running.
session_start() {
  local luacmd="$1" file="$2" pattern="$3"
  ctl down > /dev/null 2>&1 || true
  HELIOS_LUACMD="$luacmd" ctl up > "$work/wbox-up.json"
  local deadline=$((SECONDS + ${HELIOS_START_TIMEOUT:-600}))
  until if [ -z "$pattern" ]; then [ -e "$file" ]; else grep -qE "$pattern" "$file" 2> /dev/null; fi; do
    if ! dt_running; then echo "darktable exited early"; return; fi
    if [ $SECONDS -ge $deadline ]; then echo "timeout"; return; fi
    sleep 0.5
  done
  echo ok
}

# quit the way a user does, so that darktable's own shutdown runs. Prints
# "ok" or what went wrong.
session_quit() {
  local status=ok deadline next
  if dt_running; then
    # a key press can be lost while darktable's GUI thread is catching up
    # (perf.sh: minutes of queued collection reloads), so press it again
    # every 10 s until darktable goes
    deadline=$((SECONDS + ${HELIOS_QUIT_TIMEOUT:-60}))
    next=$SECONDS
    while dt_running && [ $SECONDS -lt $deadline ]; do
      if [ $SECONDS -ge $next ]; then
        ctl key ctrl+q > /dev/null
        next=$((SECONDS + 10))
      fi
      sleep 0.5
    done
    if dt_running; then status="darktable did not quit"; fi
  fi
  ctl down > /dev/null 2>&1 || true
  echo "$status"
}

# one whole session: start, wait, quit
session() {
  local status quit
  status=$(session_start "$@")
  [ "$status" = ok ] || ctl shot --name "bench-failure" > /dev/null 2>&1 || true
  quit=$(session_quit)
  [ "$status" = ok ] && status="$quit"
  echo "$status"
}

# set the lighttable collection to film roll <folder>
set_collection() {
  sed -i -e '/^plugins\/lighttable\/collect\/\(num_rules\|item0\|mode0\|string0\)=/d' \
    "$work/config/darktablerc"
  cat >> "$work/config/darktablerc" << RC
plugins/lighttable/collect/num_rules=1
plugins/lighttable/collect/item0=0
plugins/lighttable/collect/mode0=0
plugins/lighttable/collect/string0=$1
RC
}

# first session of a fresh library: let darktable create its config. A
# fresh config also resets the collection on first start
# (libs/collect.c gui_reset), so set_collection only sticks after it.
init_library() {
  rm -rf "$work"
  mkdir -p "$work/config" "$work/cache" "$work/images"
  export HELIOS_CONFIGDIR="$work/config"
  export HELIOS_CACHEDIR="$work/cache"
  export HELIOS_DT_LOG="$work/darktable.log"
  local status
  status=$(session "io.open('$work/ready', 'w'):close()" "$work/ready" '')
  if [ "$status" != ok ]; then
    echo "bench: init session failed: $status" >&2
    exit 1
  fi
  # the background thumbnail crawler starts after a few idle seconds and
  # loads full images; that load writes back an image struct copied before
  # decoding (common/mipmap_cache.c, DT_MIPMAP_FULL), undoing any rating
  # set meanwhile
  # HELIOS_BENCH_RACY=1 keeps the race, to check a darktable fix for it
  [ -n "${HELIOS_BENCH_RACY:-}" ] || echo "backthumbs_mipsize=never" >> "$work/config/darktablerc"
}
