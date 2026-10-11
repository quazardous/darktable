#!/usr/bin/env bash
# run darktable's pixel integration tests (src/tests/integration) against
# an installed build, OpenCL off, under the heavy job lock. Prints the
# summary and the failed tests; the full output goes to <log>.
#
# usage: tools/helios/bench/integration.sh <install prefix> <log> [test...|--op=<op>]
#   no test: the whole suite (191 tests, ~30 min on an idle machine)
#
# Run the whole suite once on the base as the reference, then at the end
# of each phase 0 domain, never per lot (doc/helios/PHASE0.md).

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
prefix="$(realpath "$1")"
log="$(realpath -m "$2")"
shift 2
integ="$src/src/tests/integration"

. "$here/lock.sh"
heavy_lock

# a full disk turns test outputs into false results, as on 2026-10-11:
# the suite writes outputs and logs next to the tests
free_gb=$(df -P -BG "$integ" | awk 'NR == 2 { sub("G", "", $4); print $4 }')
if [ "$free_gb" -lt 5 ]; then
  echo "integration: only ${free_gb} GB free under $integ, need 5" >&2
  exit 1
fi

t0=$SECONDS
(cd "$integ" \
  && DARKTABLE_TESTS_VENV="${DARKTABLE_TESTS_VENV:-$src/build/integration-venv}" \
     DARKTABLE_CLI="$prefix/bin/darktable-cli" \
     ./run --disable-opencl "$@") > "$log" 2>&1
status=$?
grep -E '^(Total test|Errors) ' "$log"
sed -n '/^Errors /,$p' "$log" | grep '^   - '
echo "integration: exit $status in $((SECONDS - t0)) s, log $log"
exit $status
