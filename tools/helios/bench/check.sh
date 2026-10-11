#!/usr/bin/env bash
# per-commit checks (tier T1 of the test strategy): unit and catalog tests
# of the build tree, then the Lua equivalence bench and the GUI benches of
# the given domains on two installed builds, compared before/after. One line
# per check with its verdict and duration; exit status 1 on any difference,
# failure or a run over the time budget.
#
# usage: tools/helios/bench/check.sh <before prefix> <after prefix> [--integration] [domain...|auto [base]]
#   domains: labels metadata tags (default: all)
#   auto: the domains touched by `git diff --name-only <base>` (default HEAD~1);
#         all of them when the change touches CMake, the schema or an unknown path;
#         also --integration when it touches the pixelpipe, export or jobs
#   --integration: the fast subset of the pixel tests (integration-fast.txt) on
#         the after build; a failure not in integration-known-failures.txt (the
#         failures of the base reference run) fails the check
#
# Checks run one after the other, never in parallel: CPU load re-exposes
# darktable's late writes and makes the benches differ. Do not build while
# this runs.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
before="$(realpath "$1")"
after="$(realpath "$2")"
shift 2
all_domains=(labels metadata tags)
integration=0
args=()
for a in "$@"; do
  if [ "$a" = --integration ]; then integration=1; else args+=("$a"); fi
done
set -- "${args[@]}"

# auto_domains <base>: map the files changed since <base> to bench domains
auto_domains() {
  local f d=() unknown=0
  while read -r f; do
    case "$f" in
      src/common/colorlabels.*|src/common/ratings.*|src/dtgtk/thumbnail.c|src/views/view.*) d+=(labels) ;;
      src/common/metadata.*|src/libs/metadata.c|src/libs/duplicate.c|src/lua/image.c) d+=(metadata) ;;
      src/common/tags.*|src/libs/tagging.c|src/libs/metadata_view.c|src/lua/tags.c) d+=(tags) ;;
      src/tests/*|tools/*|doc/*|*.md) ;;
      *) unknown=1 ;;
    esac
  done < <(git -C "$src" diff --name-only "$1")
  if [ $unknown = 1 ]; then echo "${all_domains[@]}"; else printf '%s\n' "${d[@]}" | sort -u | tr '\n' ' '; fi
}

# pixel_paths <base>: whether the diff since <base> can change rendered pixels
pixel_paths() {
  git -C "$src" diff --name-only "$1" \
    | grep -qE '^src/(develop|iop|control/jobs|imageio)/|^src/common/(imageio|colorspaces|mipmap_cache)'
}

if [ "${1:-}" = auto ]; then
  read -r -a domains <<< "$(auto_domains "${2:-HEAD~1}")"
  echo "domains from the diff: ${domains[*]:-none}"
  if pixel_paths "${2:-HEAD~1}"; then
    integration=1
    echo "pixel paths in the diff: running the integration subset"
  fi
else
  domains=("$@")
  [ ${#domains[@]} -eq 0 ] && domains=("${all_domains[@]}")
fi
. "$here/lock.sh"
heavy_lock

# a branch that drifts from upstream gets harder to rebase and its PRs
# harder to review: say so on every check (rebase recipe in PHASE0.md)
if git -C "$src" fetch -q upstream master 2> /dev/null; then
  behind=$(git -C "$src" rev-list --count HEAD..upstream/master)
  [ "$behind" -gt 0 ] && echo "upstream/master is $behind commits ahead of this branch: rebase it"
fi
budget="${HELIOS_CHECK_BUDGET:-300}"
out="$(mktemp -d "${TMPDIR:-/tmp}/helios-check-XXXXXX")"
durations="$here/durations.tsv"
failed=0
start_all=$SECONDS

# run <name> <command...>: time it, print one verdict line
run() {
  local name="$1" t0=$SECONDS status
  shift
  if "$@" > "$out/$name.log" 2>&1; then status=ok; else status=FAIL; failed=1; fi
  printf '%-22s %-5s %4ds\n' "$name" "$status" $((SECONDS - t0))
  printf '%s\t%s\t%s\t%d\n' "$(date +%F)" "$name" "$status" $((SECONDS - t0)) >> "$durations"
}

unit() {
  (cd "$src/build" && ctest -j0 --output-on-failure)
}

lua_bench() {
  "$here/run.sh" "$out/lua-before" "$before" \
    && "$here/run.sh" "$out/lua-after" "$after" \
    && diff -r -x timing.txt "$out/lua-before" "$out/lua-after"
}

# gui_bench <script>: same screenshots before and after
gui_bench() {
  local script="$1"
  "$here/$script" "$out/$script-before" "$before" \
    && "$here/$script" "$out/$script-after" "$after" \
    && diff -r "$out/$script-before" "$out/$script-after"
}

run unit unit
run lua-equivalence lua_bench
# integration_fast: the fast subset on the after build, known base failures
# ignored
integration_fast() {
  local tests failed new
  mapfile -t tests < <(sed 's/#.*//' "$here/integration-fast.txt" | awk 'NF { print $1 }')
  "$here/integration.sh" "$after" "$out/integration.log" "${tests[@]}"
  failed=$(sed -n '/^Errors /,$p' "$out/integration.log" | sed -n 's/^   - //p')
  new=$(comm -23 <(printf '%s\n' $failed | sort -u) \
          <(sed 's/#.*//' "$here/integration-known-failures.txt" 2> /dev/null | awk 'NF { print $1 }' | sort -u))
  if [ -n "$new" ]; then
    echo "new failures: $new"
    return 1
  fi
}

[ $integration = 1 ] && run integration integration_fast
for d in "${domains[@]}"; do
  case "$d" in
    labels) run gui-labels gui_bench gui_labels.sh ;;
    metadata) run gui-metadata gui_bench gui_metadata.sh ;;
    tags) run gui-tags gui_bench gui_tags.sh ;;
    *) echo "unknown domain: $d" >&2; failed=1 ;;
  esac
done

total=$((SECONDS - start_all))
if [ $total -gt "$budget" ]; then
  echo "total ${total}s, over the ${budget}s budget"
  failed=1
else
  echo "total ${total}s (budget ${budget}s)"
fi
[ $failed = 0 ] && echo "CHECK OK" || echo "CHECK FAILED, logs in $out"
exit $failed
