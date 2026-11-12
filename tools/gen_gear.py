#!/usr/bin/env python3
# CompletionRoute :: tools/gen_gear.py
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Licensed under PolyForm Noncommercial 1.0.0 + 10% commercial-revenue rider (see LICENSE). https://batesai.org help@batesai.org
"""Draw the options button's icon: a steel gear (64x64, 32-bit TGA).

    python3 tools/gen_gear.py        (needs Pillow; CR_GEAR_PREVIEW=<png> also writes a preview on dark and light ground)

Writes CompletionRoute/Textures/gear.tga.  Eight rounded teeth, a bevel (light top-left, dark bottom-right), a hub
and a hole, with a thin dark outline so it reads on any ground; the same palette as the arrow (tools/gen_pointer.py).
The owner asked for a gear in place of the "..." button (2026-11-12).  Our own drawing; no outside art.
"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "CompletionRoute", "Textures")
SIZE, S = 64, 8
OUTLINE = (24, 16, 10, 255)
STEEL, LIGHT, DARK, HUB = (150, 158, 166, 255), (214, 220, 226, 255), (92, 98, 106, 255), (120, 128, 136, 255)


def gear_polygon(cx, cy, r_out, r_in, teeth, tooth_frac=0.5, steps=12):
    """the outline of a gear: teeth of angular width tooth_frac of a pitch, flat tops, sloped flanks"""
    pts = []
    pitch = 2 * math.pi / teeth
    for i in range(teeth):
        a0 = i * pitch
        top0, top1 = a0 + pitch * (0.5 - tooth_frac / 2) + pitch * 0.06, a0 + pitch * (0.5 + tooth_frac / 2) - pitch * 0.06
        base0, base1 = a0 + pitch * (0.5 - tooth_frac / 2) - pitch * 0.04, a0 + pitch * (0.5 + tooth_frac / 2) + pitch * 0.04
        # root arc from the previous tooth to this one
        for k in range(steps):
            a = a0 + (base0 - a0) * k / steps
            pts.append((cx + r_in * math.cos(a), cy + r_in * math.sin(a)))
        pts.append((cx + r_in * math.cos(base0), cy + r_in * math.sin(base0)))
        for k in range(steps + 1):
            a = top0 + (top1 - top0) * k / steps
            pts.append((cx + r_out * math.cos(a), cy + r_out * math.sin(a)))
        pts.append((cx + r_in * math.cos(base1), cy + r_in * math.sin(base1)))
        for k in range(1, steps):
            a = base1 + (a0 + pitch - base1) * k / steps
            pts.append((cx + r_in * math.cos(a), cy + r_in * math.sin(a)))
    return pts


def draw():
    w = SIZE * S
    c = w / 2
    body = Image.new("L", (w, w), 0)
    gear = gear_polygon(c, c, w * 0.47, w * 0.36, 8)
    ImageDraw.Draw(body).polygon(gear, fill=255)
    hole_r = w * 0.12
    ImageDraw.Draw(body).ellipse((c - hole_r, c - hole_r, c + hole_r, c + hole_r), fill=0)

    # shading: a diagonal gradient (light top-left to dark bottom-right) clipped to the gear
    shade = Image.new("RGBA", (w, w))
    px = shade.load()
    for y in range(w):
        for x in range(w):
            t = min(1.0, max(0.0, (x + y) / (2 * w) * 1.2 - 0.1))
            col = tuple(int(LIGHT[i] * (1 - t) + DARK[i] * t) for i in range(3)) + (255,)
            px[x, y] = col
    im = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    im.paste(shade, (0, 0), body)
    d = ImageDraw.Draw(im)
    # hub ring around the hole
    hub_r = w * 0.22
    d.ellipse((c - hub_r, c - hub_r, c + hub_r, c + hub_r), outline=HUB, width=int(w * 0.035))
    # outline of the gear and of the hole
    ow = int(w * 0.03)
    d.line(gear + [gear[0]], fill=OUTLINE, width=ow, joint="curve")
    d.ellipse((c - hole_r, c - hole_r, c + hole_r, c + hole_r), outline=OUTLINE, width=ow)
    im = im.filter(ImageFilter.SMOOTH)
    im = im.resize((SIZE, SIZE), Image.LANCZOS)
    im.save(os.path.join(OUT, "gear.tga"))
    preview = os.environ.get("CR_GEAR_PREVIEW")
    if preview:
        big = im.resize((SIZE * 3, SIZE * 3), Image.LANCZOS)
        sheet = Image.new("RGBA", (SIZE * 6, SIZE * 3), (40, 46, 38, 255))
        sheet.paste((196, 186, 160, 255), (SIZE * 3, 0, SIZE * 6, SIZE * 3))
        sheet.alpha_composite(big, (0, 0))
        sheet.alpha_composite(big, (SIZE * 3, 0))
        sheet.save(preview)
    print("wrote gear")


if __name__ == "__main__":
    draw()
