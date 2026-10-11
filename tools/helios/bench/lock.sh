# shared by the heavy bench scripts (check.sh, integration.sh, perf.sh,
# timeline.sh): only one of them runs at a time. Each test of the pixel
# suite already takes every core through OpenMP, and the GUI benches
# diverge under CPU load, so overlapping jobs are both slower and wrong.
# Nested calls (check.sh running other scripts) inherit the lock.

heavy_lock() {
  [ -n "${HELIOS_HEAVY_LOCKED:-}" ] && return
  # a fixed path, not $TMPDIR: two shells with different TMPDIR must still
  # see the same lock
  local lock="/tmp/helios-heavy-$(id -u).lock"
  exec 9> "$lock"
  if ! flock -n 9; then
    echo "waiting for another heavy bench job to finish (lock $lock)" >&2
    flock 9
  fi
  export HELIOS_HEAVY_LOCKED=1
}
