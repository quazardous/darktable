#!/usr/bin/env python3
# Drop the page cache of every file under the given paths, without root
# (posix_fadvise DONTNEED), so the next run reads them from disk as on a
# freshly booted box (darktable #3955).
#
# usage: evict.py <path>...
import os
import sys

n = 0
for root in sys.argv[1:]:
  for d, _, files in os.walk(root):
    for f in files:
      try:
        fd = os.open(os.path.join(d, f), os.O_RDONLY)
      except OSError:
        continue
      try:
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        n += 1
      finally:
        os.close(fd)
print(f"evict: {n} files")
