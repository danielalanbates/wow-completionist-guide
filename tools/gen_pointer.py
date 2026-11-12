#!/usr/bin/env python3
# CompletionRoute :: tools/gen_pointer.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
"""Draw the pointer textures: an archery arrow (broadhead, shaft, fletching, nock) pointing up.

    python3 tools/gen_pointer.py        (needs Pillow)

Writes CompletionRoute/Textures/arrow.tga, arrow_green.tga, arrow_red.tga, arrow_blue.tga (128x128, 32-bit TGA).
The owner asked for a bow-and-arrow arrow instead of a chevron (2026-11-11). Our own drawing; no outside art.
"""
import os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "CompletionRoute", "Textures")
SIZE, S = 128, 6          # final size, supersample


def arrow(name, fill, dark, feather):
    w = SIZE * S
    im = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    def P(pts): return [(x * w, y * w) for x, y in pts]
    ow = int(w * 0.022)                                   # outline width
    cx = 0.5
    # fletching: two swept vanes at the tail, drawn first so the shaft sits on top
    for sgn in (-1, 1):
        vane = [(cx, 0.70), (cx + sgn * 0.17, 0.80), (cx + sgn * 0.17, 0.93), (cx, 0.86)]
        d.polygon(P(vane), fill=feather)
        d.line(P(vane + [vane[0]]), fill=dark, width=ow, joint="curve")
        d.line(P([(cx + sgn * 0.02, 0.775), (cx + sgn * 0.15, 0.865)]), fill=dark, width=max(1, ow // 2))
    # shaft
    shaft = [(cx - 0.035, 0.36), (cx + 0.035, 0.36), (cx + 0.035, 0.90), (cx - 0.035, 0.90)]
    d.polygon(P(shaft), fill=fill)
    d.line(P(shaft + [shaft[0]]), fill=dark, width=ow, joint="curve")
    # nock
    nock = [(cx - 0.05, 0.89), (cx + 0.05, 0.89), (cx + 0.05, 0.955), (cx, 0.925), (cx - 0.05, 0.955)]
    d.polygon(P(nock), fill=dark)
    # broadhead: a barbed point
    head = [(cx, 0.04), (cx + 0.19, 0.40), (cx + 0.06, 0.33), (cx, 0.40), (cx - 0.06, 0.33), (cx - 0.19, 0.40)]
    d.polygon(P(head), fill=fill)
    d.line(P(head + [head[0]]), fill=dark, width=ow, joint="curve")
    d.line(P([(cx, 0.09), (cx, 0.36)]), fill=dark, width=max(1, ow // 2))   # the head's centre ridge
    im = im.resize((SIZE, SIZE), Image.LANCZOS)
    im.save(os.path.join(OUT, name + ".tga"))
    print("wrote", name)


arrow("arrow", (255, 210, 0, 255), (60, 40, 0, 255), (255, 240, 170, 255))
arrow("arrow_green", (80, 230, 90, 255), (0, 50, 0, 255), (200, 255, 200, 255))
arrow("arrow_red", (240, 70, 60, 255), (60, 0, 0, 255), (255, 200, 195, 255))
arrow("arrow_blue", (62, 198, 255, 255), (0, 40, 70, 255), (200, 235, 255, 255))
