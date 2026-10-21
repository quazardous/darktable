#!/usr/bin/env python3
"""Dump a darktable database as stable, comparable text.

Every table is printed with its rows sorted, and columns whose value depends
on the wall clock are masked, so that two runs of the same scenario on the
same build produce identical output.
"""

import re
import sqlite3
import sys

VOLATILE = re.compile(r"timestamp|_time$|^last_|^access", re.IGNORECASE)


def dump(path, out):
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    schema = db.execute(
        "SELECT type, name, sql FROM sqlite_master"
        " WHERE sql IS NOT NULL ORDER BY type, name").fetchall()
    for kind, name, sql in schema:
        out.write(f"-- {kind} {name}\n{sql}\n")
    tables = [n for k, n, _ in schema if k == "table" and not n.startswith("sqlite_")]
    for table in tables:
        cols = [r[1] for r in db.execute(f'PRAGMA table_info("{table}")')]
        rows = []
        for row in db.execute(f'SELECT * FROM "{table}"'):
            cells = []
            for col, val in zip(cols, row):
                # the build version gains "-dirty" with uncommitted changes
                if table == "db_info" and row[0] == "dt_version":
                    val = "<version>" if col == "value" else val
                elif VOLATILE.search(col) and val is not None:
                    val = "<volatile>"
                elif isinstance(val, bytes):
                    val = "x'" + val.hex() + "'"
                cells.append(f"{col}={val!r}")
            rows.append(" | ".join(cells))
        rows.sort()
        out.write(f"== {table} ({len(rows)} rows)\n")
        for r in rows:
            out.write(r + "\n")


def normalize_xmp(path, out):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    # exiv2 does not keep the order of namespace declarations and attributes
    text = re.sub(r'<rdf:Description\b(?:[^>"]|"[^"]*")*>', _sort_attributes, text)
    text = re.sub(r'(\w*(?:timestamp|MetadataDate|ModifyDate)\w*=)"[^"]*"',
                  r'\1"<volatile>"', text, flags=re.IGNORECASE)
    out.write(text)


def _sort_attributes(m):
    tag = m.group(0)
    attrs = re.findall(r'[\w:]+="[^"]*"', tag)
    end = "/>" if tag.endswith("/>") else ">"
    return "<rdf:Description\n   " + "\n   ".join(sorted(attrs)) + end


def sidecars(path, out):
    """list the sidecar names of the images still in the library"""
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    for filename, version in db.execute(
            "SELECT filename, version FROM images ORDER BY filename, version"):
        if version > 0:
            stem, dot, ext = filename.rpartition(".")
            filename = f"{stem}_{version:02d}{dot}{ext}"
        out.write(filename + ".xmp\n")


if __name__ == "__main__":
    mode, src = sys.argv[1], sys.argv[2]
    {"db": dump, "xmp": normalize_xmp, "sidecars": sidecars}[mode](src, sys.stdout)
