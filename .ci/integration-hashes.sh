#!/usr/bin/env bash
#
#    This file is part of darktable.
#    Copyright (C) 2026 darktable developers.
#
#    darktable is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    darktable is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with darktable.  If not, see <http://www.gnu.org/licenses/>.

# Compares the pixel hash of each test's output.png with the reference
# hash for the CPU vendor of this machine, in <refs>/<vendor_id>.txt
# ("<test> <hash>" lines, # starts a comment). The outputs of the
# integration tests are exactly reproducible for a given vendor when
# darktable is built without target_clones (DT_NO_CLONE_TARGETS), so any
# difference is a change of the output.
#
# usage: integration-hashes.sh <refs dir> <hashes out> <test>...
#   run from src/tests/integration after ./run; writes "<test> <hash>"
#   for every test to <hashes out>, the lines to paste into the reference
#   file when an output changes on purpose. Exits 1 when a hash differs;
#   a test without a reference, or a vendor without a file, is reported.

set -uo pipefail

refs="$1" out="$2"
shift 2
vendor=$(awk -F': *' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo)
ref="$refs/$vendor.txt"
[ -f "$ref" ] || echo "no reference file for CPU vendor '$vendor': hashes recorded, not compared"

: > "$out"
differ=()
for test in "$@"; do
  hash=missing
  [ -f "$test/output.png" ] && hash=$(identify -format '%#' "$test/output.png" 2> /dev/null || echo unreadable)
  echo "$test $hash" >> "$out"
  [ -f "$ref" ] || continue
  expected=$(sed 's/#.*//' "$ref" | awk -v t="$test" '$1 == t { print $2 }')
  if [ -z "$expected" ]; then
    echo "$test: no reference hash for $vendor"
  elif [ "$hash" != "$expected" ]; then
    echo "$test: $hash, expected $expected"
    differ+=("$test")
  fi
done

echo "$vendor: $# tests, ${#differ[@]} with a different output"
[ ${#differ[@]} -eq 0 ]
