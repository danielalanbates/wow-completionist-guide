#!/usr/bin/env python3
# CompletionRoute :: tools/gen_pointer.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
"""Draw the pointer texture: an archery arrow pointing up, in natural colours.

    python3 tools/gen_pointer.py        (needs Pillow)

Writes CompletionRoute/Textures/arrow.tga (128x128, 32-bit TGA): a steel broadhead with a bevel highlight, a wooden
shaft with grain and two thread bindings, barred cream-and-brown feather fletching and a dark nock, all with a thin
dark outline so it reads on any ground.  Our own drawing; no outside art.

History: the owner asked for a bow-and-arrow arrow instead of a chevron (2026-11-11), drawn first in flat green /
yellow / red / blue by distance; then for realistic colouring and no ETA line (2026-11-12), so there is one texture
and the distance is the text under the arrow.
"""
import os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "CompletionRoute", "Textures")
SIZE, S = 128, 8          # final size, supersample

OUTLINE = (24, 16, 10, 255)
STEEL, STEEL_LIGHT, STEEL_DARK = (150, 158, 166, 255), (214, 220, 226, 255), (92, 98, 106, 255)
WOOD, WOOD_LIGHT, WOOD_DARK = (150, 98, 52, 255), (190, 136, 82, 255), (104, 64, 30, 255)
THREAD = (70, 30, 20, 255)
FEATHER, FEATHER_BAR, FEATHER_EDGE = (232, 222, 196, 255), (126, 84, 46, 255), (196, 182, 150, 255)
NOCK = (40, 32, 28, 255)


def draw():
    w = SIZE * S
    im = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    def P(pts):
        return [(x * w, y * w) for x, y in pts]

    ow = int(w * 0.018)                                   # outline width
    cx = 0.5

    # fletching: two swept feather vanes at the tail, barred like a natural feather; drawn first, under the shaft
    for sgn in (-1, 1):
        vane = [(cx + sgn * 0.02, 0.66), (cx + sgn * 0.16, 0.76), (cx + sgn * 0.17, 0.90), (cx + sgn * 0.02, 0.86)]
        d.polygon(P(vane), fill=FEATHER)
        # bars across the vane, following its sweep
        for i in range(4):
            t0, t1 = 0.08 + i * 0.22, 0.17 + i * 0.22
            a0 = (cx + sgn * 0.02, 0.66 + (0.86 - 0.66) * t0)
            a1 = (cx + sgn * 0.02, 0.66 + (0.86 - 0.66) * t1)
            b1 = (cx + sgn * (0.16 + 0.01 * t1), 0.76 + (0.90 - 0.76) * t1)
            b0 = (cx + sgn * (0.16 + 0.01 * t0), 0.76 + (0.90 - 0.76) * t0)
            d.polygon(P([a0, a1, b1, b0]), fill=FEATHER_BAR)
        # the outer edge of the vane is a little darker, the barbs a fine line
        d.line(P([vane[1], vane[2]]), fill=FEATHER_EDGE, width=max(1, ow // 2))
        d.line(P(vane + [vane[0]]), fill=OUTLINE, width=ow, joint="curve")

    # shaft: wood, a lighter grain stripe on one side and a darker one on the other
    shaft = [(cx - 0.032, 0.34), (cx + 0.032, 0.34), (cx + 0.032, 0.90), (cx - 0.032, 0.90)]
    d.polygon(P(shaft), fill=WOOD)
    d.polygon(P([(cx - 0.032, 0.34), (cx - 0.010, 0.34), (cx - 0.010, 0.90), (cx - 0.032, 0.90)]), fill=WOOD_LIGHT)
    d.polygon(P([(cx + 0.014, 0.34), (cx + 0.032, 0.34), (cx + 0.032, 0.90), (cx + 0.014, 0.90)]), fill=WOOD_DARK)
    for y in (0.45, 0.53, 0.60):                          # a few grain lines
        d.line(P([(cx - 0.004, y), (cx + 0.006, y + 0.05)]), fill=WOOD_DARK, width=max(1, ow // 3))
    d.line(P(shaft + [shaft[0]]), fill=OUTLINE, width=ow, joint="curve")
    # thread bindings: behind the head and in front of the fletching
    for y0, y1 in ((0.34, 0.375), (0.635, 0.665)):
        band = [(cx - 0.038, y0), (cx + 0.038, y0), (cx + 0.038, y1), (cx - 0.038, y1)]
        d.polygon(P(band), fill=THREAD)
        d.line(P(band + [band[0]]), fill=OUTLINE, width=max(1, ow // 2))

    # nock: dark horn with its slot
    nock = [(cx - 0.045, 0.895), (cx + 0.045, 0.895), (cx + 0.045, 0.96), (cx, 0.93), (cx - 0.045, 0.96)]
    d.polygon(P(nock), fill=NOCK)
    d.line(P(nock + [nock[0]]), fill=OUTLINE, width=max(1, ow // 2), joint="curve")

    # broadhead: steel, a light bevel on the left blade, a dark one on the right, a central ridge
    tip, lb, rb = (cx, 0.04), (cx - 0.18, 0.37), (cx + 0.18, 0.37)
    lbarb, rbarb, neck = (cx - 0.055, 0.31), (cx + 0.055, 0.31), (cx, 0.36)
    head = [tip, rb, rbarb, neck, lbarb, lb]
    d.polygon(P(head), fill=STEEL)
    d.polygon(P([tip, (cx, 0.36), lbarb, lb]), fill=STEEL_LIGHT)
    d.polygon(P([tip, rb, rbarb, (cx, 0.36)]), fill=STEEL_DARK)
    d.polygon(P([tip, (cx + 0.025, 0.30), (cx, 0.34), (cx - 0.025, 0.30)]), fill=STEEL)   # the ridge
    d.line(P(head + [head[0]]), fill=OUTLINE, width=ow, joint="curve")
    d.line(P([tip, (cx, 0.34)]), fill=STEEL_DARK, width=max(1, ow // 3))

    im = im.resize((SIZE, SIZE), Image.LANCZOS)
    im.save(os.path.join(OUT, "arrow.tga"))
    preview = os.environ.get("CR_POINTER_PREVIEW")      # optional: a PNG on a dark and a light ground, to look at
    if preview:
        sheet = Image.new("RGBA", (2 * SIZE * 2, SIZE * 2), (0, 0, 0, 255))
        sheet.paste((40, 46, 38, 255), (0, 0, SIZE * 2, SIZE * 2))
        sheet.paste((196, 186, 160, 255), (SIZE * 2, 0, SIZE * 4, SIZE * 2))
        big = im.resize((SIZE * 2, SIZE * 2), Image.LANCZOS)
        sheet.alpha_composite(big, (0, 0))
        sheet.alpha_composite(big, (SIZE * 2, 0))
        sheet.save(preview)
    print("wrote arrow")


if __name__ == "__main__":
    draw()
