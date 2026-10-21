#!/usr/bin/env python3
"""Compare the pixel outputs of two builds, test by test: the verdict of a
base-vs-branch pixel check (darktable #3767).

usage: compare_outputs.py <before dir> <after dir> [<maps dir>]

Both directories hold <test>.png as kept by integration.sh
(HELIOS_KEEP_OUTPUTS). Images are compared as decoded pixels, never as
bytes: darktable writes dates and the XMP into every export. The measure is
the integration suite's own (src/tests/integration/deltae): sRGB to Lab with
Bradford adaptation, CIE 2000. Per test:

  same     no pixel above dE 1
  noise    max dE under the suite's visibility threshold (2.3) and fewer
           than 0.01 % of pixels above dE 1: run-to-run variation, as some
           tests show on one build (0026, 0058, 0102, 0159, 0166 here).
           Passes, reported with its numbers.
  changed  anything else; fails, with a difference map in <maps dir>

Exit status 1 when a test changed or is missing on one side. Run it with the
integration venv's python (it needs colour-science, as the suite does).
"""

import sys
from pathlib import Path

import colour
import numpy

# the suite's visibility threshold (src/tests/integration/deltae)
MAX_DELTA_E = 2.3
NOISE_DE = 1.0
NOISE_SHARE = 0.0001


def lab(path):
    rgb = colour.read_image(str(path), method="Imageio")[..., :3]
    return colour.XYZ_to_Lab(colour.sRGB_to_XYZ(rgb, chromatic_adaptation_transform="Bradford"))


def main(before, after, maps=None):
    before, after = Path(before), Path(after)
    names = sorted({p.name for p in before.glob("*.png")} | {p.name for p in after.glob("*.png")})
    counts = {"same": 0, "noise": 0, "changed": 0, "missing": 0}
    for name in names:
        b, a = before / name, after / name
        test = name[:-4]
        if not (b.exists() and a.exists()):
            counts["missing"] += 1
            print(f"missing  {test}: only in {'before' if b.exists() else 'after'}")
            continue
        lb, la = lab(b), lab(a)
        if lb.shape != la.shape:
            counts["changed"] += 1
            print(f"changed  {test}: size {lb.shape[1]}x{lb.shape[0]} -> {la.shape[1]}x{la.shape[0]}")
            continue
        de = colour.delta_E(lb, la, method="CIE 2000")
        max_de, avg_de = float(de.max()), float(de.mean())
        over = int((de > NOISE_DE).sum())
        share = over / de.size
        if over == 0:
            counts["same"] += 1
            continue
        if max_de < MAX_DELTA_E and share < NOISE_SHARE:
            counts["noise"] += 1
            print(f"noise    {test}: {over} px over dE {NOISE_DE:g}, max {max_de:.3f}, avg {avg_de:.5f}")
            continue
        counts["changed"] += 1
        print(f"changed  {test}: {over} px over dE {NOISE_DE:g} ({share:.3%}), max {max_de:.3f}, avg {avg_de:.5f}")
        if maps:
            Path(maps).mkdir(parents=True, exist_ok=True)
            mask = (numpy.clip(de / MAX_DELTA_E, 0, 1) * 255).astype(numpy.uint8)
            colour.write_image(mask / 255.0, str(Path(maps) / f"{test}-diff.png"), bit_depth="uint8",
                               method="Imageio")
    print("outputs: " + ", ".join(f"{v} {k}" for k, v in counts.items()))
    return 1 if counts["changed"] or counts["missing"] else 0


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
