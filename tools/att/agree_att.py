#!/usr/bin/env python3
# CompletionRoute :: tools/att/agree_att.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE).
# https://batesai.org  help@batesai.org
"""Measurement only: on A steps that already have a wiki point, place the step again from the community collection database
(att_points) and report the distance in map units (0-100).

    python3 tools/att/agree_att.py FLAVOR GUIDEFILE.lua
"""
import re
import statistics
import sys
from pathlib import Path

sys.path[:0] = [str(Path(__file__).resolve().parents[1] / "wiki"), str(Path(__file__).resolve().parent)]
import wikimaps  # noqa: E402
import att_points as AP  # noqa: E402

M = re.compile(r"\|M\|([\d.]+),([\d.]+)")


def main(fl, path):
    q = AP.ATTPoints(fl, wikimaps.Atlas().sets[fl])
    d = []
    for ln in Path(path).read_text(encoding="utf-8").splitlines():
        m = M.search(ln)
        if not m or ln[:1] != "A" or "(location:" in ln:
            continue
        new = q.fill_line(ln[:m.start()] + ln[m.end():])
        n = new and M.search(new)
        if n:
            d.append(((float(m.group(1)) - float(n.group(1))) ** 2 + (float(m.group(2)) - float(n.group(2))) ** 2) ** .5)
    d.sort()
    if d:
        print(f"{fl}: {len(d)} steps, median {statistics.median(d):.2f}, p90 {d[int(.9 * len(d))]:.2f}, "
              f"within 3 units {100 * sum(x <= 3 for x in d) / len(d):.1f}%")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
