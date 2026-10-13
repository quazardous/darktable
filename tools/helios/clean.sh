#!/bin/bash
# list the darktable worktrees with their upstream PR state and the size of
# their build dirs; with --apply, remove the build dirs (never sources or
# branches) of the worktrees whose PR is merged or closed upstream
#
#   tools/helios/clean.sh            # list only
#   tools/helios/clean.sh --apply    # remove build*/ where the PR is done
#
# detached worktrees (review checkouts) have no PR: they are listed, and their
# build dirs go with `rm -rf <worktree>/build*` once their ticket is closed.
# Extra install prefixes in the main tree (build/helios-prefix-*) are listed
# too; only build/helios-prefix is used by the benches.

set -euo pipefail

repo=darktable-org/darktable
apply=0
[ "${1:-}" = "--apply" ] && apply=1

top=$(git rev-parse --show-toplevel)

git -C "$top" worktree list --porcelain | awk '
  /^worktree / { wt = substr($0, 10) }
  /^branch /   { br = substr($0, 19) }
  /^detached/  { br = "-" }
  /^$/         { print wt "\t" br; br = "" }
' | while IFS=$'\t' read -r wt br; do
  state=-
  if [ "$br" != "-" ] && [ "$wt" != "$top" ]; then
    state=$(gh pr list --repo "$repo" --head "$br" --state all \
              --json number,state --jq 'map("#\(.number) \(.state)") | join(",")' \
              2>/dev/null || echo "?")
    [ -n "$state" ] || state="no PR"
  fi
  size=$(du -sch "$wt"/build*/ 2>/dev/null | tail -1 | cut -f1 || true)
  [ -n "$size" ] || size=0
  printf '%-40s %-36s %-16s build %s\n' "$(basename "$wt")" "$br" "$state" "$size"

  case "$state" in
    *MERGED*|*CLOSED*)
      if [ "$apply" = 1 ] && compgen -G "$wt/build*/" > /dev/null; then
        rm -rf "$wt"/build*/
        echo "  removed $wt/build*/"
      fi
      ;;
  esac
done

for p in "$top"/build/helios-prefix-*/; do
  [ -d "$p" ] && du -sh "$p"
done

df -h "$top" | tail -1
