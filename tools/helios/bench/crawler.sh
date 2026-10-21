#!/usr/bin/env bash
# bench for the XMP crawler (control/crawler.c): import images, then add a
# .txt and a .wav next to two of them and remove a third one's file, and
# start darktable again with run_crawler_on_start. The crawler sets the
# has-txt/has-wav flags in the database; dump the flags and timestamps of
# every image to <outdir>/images.txt, to compare across builds with diff.
#
# usage: tools/helios/bench/crawler.sh <outdir> [install prefix]

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../.." && pwd)"
outdir="$(realpath -m "$1")"
prefix="$(realpath "${2:-$src/build/helios-prefix}")"
work="${HELIOS_BENCH_WORK:-${TMPDIR:-/tmp}/helios-bench-work}-crawler"
integ="$src/src/tests/integration"

. "$here/lib.sh"
. "$here/lock.sh"
heavy_lock

rm -rf "$outdir"
mkdir -p "$outdir"
export HELIOS_PREFIX="$prefix"
init_library
cp "$integ"/images/{mire1.cr2,hlrecovery.arw,bayer4.crw} "$work/images/"

set_collection /helios-bench-no-such-film
status=$(session "local dt = require 'darktable'; dt.database.import('$work/images'); io.open('$work/ready-import', 'w'):close()" "$work/ready-import" '')
[ "$status" = ok ] || { echo "crawler bench: import failed: $status" >&2; exit 1; }

# what the crawler has to notice
echo note > "$work/images/mire1.txt"
: > "$work/images/hlrecovery.wav"
echo "run_crawler_on_start=TRUE" >> "$work/config/darktablerc"

status=$(session "io.open('$work/ready-crawl', 'w'):close()" "$work/ready-crawl" '')
[ "$status" = ok ] || { echo "crawler bench: crawl session failed: $status" >&2; exit 1; }

sqlite3 "$work/config/library.db" \
  "SELECT filename, version, flags, write_timestamp > 0 FROM main.images ORDER BY filename, version" \
  > "$outdir/images.txt"
echo "crawler bench results in $outdir: ok"
