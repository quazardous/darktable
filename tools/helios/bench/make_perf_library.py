#!/usr/bin/env python3
"""Grow a darktable library to a synthetic collection for the perf bench.

Clones the image row of a library holding one real imported image into
<count> images spread over film rolls of 1000, with seeded ratings, color
labels, tags, titles and duplicates. The files do not exist: thumbnails show
the missing-file placeholder, so timings cover the catalog and the GUI, not
raw decoding. Images have no capture date, which keeps the lighttable
timeline (quadratic in the collection size) out of the measurements.

usage: make_perf_library.py <library.db> <data.db> [count] [seed]
"""

import random
import sqlite3
import sys

FILM_SIZE = 1000
TAGS = 20


def main():
    library, data = sys.argv[1], sys.argv[2]
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 100000
    rng = random.Random(int(sys.argv[4]) if len(sys.argv) > 4 else 1)

    db = sqlite3.connect(library)
    db.execute(f"ATTACH DATABASE '{data}' AS data")
    cols = [r[1] for r in db.execute("PRAGMA main.table_info(images)")]
    template = dict(zip(cols, db.execute("SELECT * FROM main.images ORDER BY id LIMIT 1").fetchone()))
    title_key = db.execute(
        "SELECT key FROM data.meta_data WHERE tagname = 'Xmp.dc.title'").fetchone()[0]

    db.execute("DELETE FROM main.images")
    db.execute("DELETE FROM main.film_rolls")
    db.execute("DELETE FROM main.color_labels")
    db.execute("DELETE FROM main.tagged_images")
    db.execute("DELETE FROM main.meta_data")
    db.execute("DELETE FROM main.selected_images")

    films = (count + FILM_SIZE - 1) // FILM_SIZE
    db.executemany("INSERT INTO main.film_rolls (id, access_timestamp, folder) VALUES (?, 0, ?)",
                   [(f + 1, f"/helios-perf/film-{f + 1:03d}") for f in range(films)])

    db.executemany("INSERT INTO data.tags (name, synonyms, flags) VALUES (?, '', 0)",
                   [(f"helios|perf|tag-{t:02d}",) for t in range(TAGS)])
    tag_ids = [r[0] for r in db.execute(
        "SELECT id FROM data.tags WHERE name LIKE 'helios|perf|%' ORDER BY name")]

    rows, labels, tagged, meta = [], [], [], []
    group = 0
    for i in range(count):
        imgid = i + 1
        film = i // FILM_SIZE + 1
        # about 5% are duplicates (version 1) of the image before them
        duplicate = i % FILM_SIZE and rng.random() < 0.05
        if not duplicate:
            group = imgid
        row = dict(template)
        row.update(
            id=imgid, group_id=group, film_id=film,
            filename=f"img-{group:06d}.cr2", version=1 if duplicate else 0,
            max_version=0, position=imgid << 32,
            # no capture date: the lighttable timeline skips undated images,
            # which keeps it out of the measurements (timeline.sh dates them)
            datetime_taken=None,
            history_end=0)
        rating = rng.choice((0, 1, 1, 2, 3, 3, 4, 5))
        flags = (template["flags"] & ~0xF) | rating
        if rng.random() < 0.03:
            flags |= 8  # rejected
        row["flags"] = flags
        rows.append(tuple(row[c] for c in cols))
        if rng.random() < 0.3:
            for color in rng.sample(range(5), rng.choice((1, 1, 2))):
                labels.append((imgid, color))
        if rng.random() < 0.5:
            for tag in rng.sample(tag_ids, rng.choice((1, 2, 3))):
                tagged.append((imgid, tag, 0))
        if rng.random() < 0.1:
            meta.append((imgid, title_key, f"title {rng.randrange(500)}"))

    marks = ", ".join("?" * len(cols))
    db.executemany(f"INSERT INTO main.images ({', '.join(cols)}) VALUES ({marks})", rows)
    db.executemany("INSERT INTO main.color_labels (imgid, color) VALUES (?, ?)", labels)
    db.executemany("INSERT INTO main.tagged_images (imgid, tagid, position) VALUES (?, ?, ?)", tagged)
    db.executemany("INSERT INTO main.meta_data (id, key, value) VALUES (?, ?, ?)", meta)
    db.commit()
    # the template library's sqlite_stat1 describes a handful of images; left
    # stale, it makes SQLite skip the automatic indexes darktable's joins rely
    # on (the timeline query goes quadratic, darktable #3715), which a real
    # library avoids through darktable's ANALYZE and PRAGMA optimize
    db.execute("ANALYZE")
    db.commit()
    print(f"{count} images, {films} film rolls, {len(labels)} labels, "
          f"{len(tagged)} tag links, {len(meta)} titles")


if __name__ == "__main__":
    main()
