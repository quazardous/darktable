#!/usr/bin/env python3
# Per-test dE 2000 statistics of a finished integration run, for the
# fork's measurement workflow (darktable #3958): for every test directory
# holding expected.png and output.png, the max, avg and high percentiles of
# dE, and how many pixels exceed 1 and 2.3. Uses the suite's own dE path
# (sRGB -> XYZ (Bradford) -> Lab, CIE 2000), as in src/tests/integration/deltae.
#
# usage: integration_stats.py <integration dir> <out.json>

import json
import os
import sys
import time

import colour
import numpy


def lab(path):
    rgb = colour.read_image(path, method="Imageio")
    return colour.XYZ_to_Lab(colour.sRGB_to_XYZ(rgb, chromatic_adaptation_transform="Bradford"))


root, out = sys.argv[1], sys.argv[2]
stats = {}
for name in sorted(os.listdir(root)):
    d = os.path.join(root, name)
    exp, got = os.path.join(d, "expected.png"), os.path.join(d, "output.png")
    if not (os.path.isfile(exp) and os.path.isfile(got)):
        continue
    t0 = time.monotonic()
    identical = open(exp, "rb").read() == open(got, "rb").read()
    if identical:
        stats[name] = {"identical": True, "seconds": round(time.monotonic() - t0, 3)}
        continue
    a, b = lab(exp), lab(got)
    if a.shape != b.shape:
        stats[name] = {"shape": [list(a.shape), list(b.shape)]}
        continue
    de = colour.delta_E(a, b, method="CIE 2000").ravel()
    stats[name] = {
        "identical": False,
        "pixels": int(de.size),
        "max": float(de.max()),
        "avg": float(de.mean()),
        "p99": float(numpy.percentile(de, 99)),
        "p9999": float(numpy.percentile(de, 99.99)),
        "over1": int((de > 1.0).sum()),
        "over23": int((de > 2.3).sum()),
        "seconds": round(time.monotonic() - t0, 3),
    }
json.dump(stats, open(out, "w"), indent=1)
print(f"{len(stats)} tests, {sum(1 for s in stats.values() if s.get('identical'))} byte-identical,"
      f" dE time {sum(s.get('seconds', 0) for s in stats.values()):.0f} s")
