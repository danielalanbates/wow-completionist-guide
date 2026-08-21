#!/usr/bin/env python3
"""Generate CompletionRoute/Textures/*.tga (uncompressed 32-bit TGA, power-of-two)."""
from PIL import Image, ImageDraw, ImageFilter
import os
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "CompletionRoute", "Textures")
os.makedirs(OUT, exist_ok=True)

def arrow(name, fill, outline, size=128):
    S = 4  # supersample
    im = Image.new("RGBA", (size*S, size*S), (0,0,0,0))
    d = ImageDraw.Draw(im)
    w = size*S
    # chevron/arrow pointing up
    pts = [(w*0.5, w*0.06), (w*0.90, w*0.62), (w*0.70, w*0.62), (w*0.70, w*0.94), (w*0.30, w*0.94), (w*0.30, w*0.62), (w*0.10, w*0.62)]
    d.polygon(pts, fill=fill, outline=outline)
    d.line(pts+[pts[0]], fill=outline, width=int(w*0.035), joint="curve")
    im = im.resize((size, size), Image.LANCZOS)
    im.save(os.path.join(OUT, name + ".tga"))
    print("wrote", name)

arrow("arrow", (255, 210, 0, 255), (60, 40, 0, 255))
arrow("arrow_green", (80, 230, 90, 255), (0, 50, 0, 255))
arrow("arrow_red", (240, 70, 60, 255), (60, 0, 0, 255))
arrow("arrow_blue", (62, 198, 255, 255), (0, 40, 70, 255))

def hand(name, size=128):
    """A pointing hand (index finger up), drawn WHITE so the addon can tint it to the player's class
    colour with SetVertexColor. Shapes are unioned into one silhouette first, then the outline is
    taken from the union so the fingers/thumb read as one hand instead of separate pills. The outline
    is dark grey: vertex colour multiplies, so it stays a darker shade of the class colour."""
    S = 4
    w = size * S
    def blank():
        return Image.new("L", (w, w), 0)
    def rr(dr, x0, y0, x1, y1, r):
        dr.rounded_rectangle((w*x0, w*y0, w*x1, w*y1), radius=int(w*r), fill=255)
    def knuckle(dr, x, y):
        dr.ellipse((w*x, w*y, w*(x+0.095), w*(y+0.15)), fill=255)

    parts = []
    for draw_part in (
        lambda dr: rr(dr, 0.26, 0.53, 0.82, 0.94, 0.14),   # fist
        lambda dr: rr(dr, 0.385, 0.05, 0.585, 0.63, 0.10),  # index finger, pointing up
        lambda dr: rr(dr, 0.19, 0.575, 0.42, 0.72, 0.072),  # thumb folded across the fist
        lambda dr: knuckle(dr, 0.585, 0.510),
        lambda dr: knuckle(dr, 0.670, 0.522),
        lambda dr: knuckle(dr, 0.752, 0.540),
    ):
        m = blank(); draw_part(ImageDraw.Draw(m)); parts.append(m)

    union = blank()
    for m in parts:
        union = Image.composite(m, union, m)

    # outline = a dilated copy of the union minus the union itself
    LW = max(3, int(w * 0.022))
    def odd(n): return n if n % 2 == 1 else n + 1
    grown = union.filter(ImageFilter.MaxFilter(odd(LW * 2)))
    edge = Image.composite(Image.new("L", (w, w), 0), grown, union)

    # interior separators: each part's own edge, clipped to the union so finger creases show
    creases = blank()
    for m in parts:
        e = Image.composite(Image.new("L", (w, w), 0), m.filter(ImageFilter.MaxFilter(odd(LW))), m)
        creases = Image.composite(e, creases, e)
    creases = Image.composite(creases, blank(), union)

    im = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    im.paste((255, 255, 255, 255), (0, 0), union)
    im.paste((70, 70, 70, 255), (0, 0), Image.eval(creases, lambda v: int(v * 0.75)))
    im.paste((40, 40, 40, 255), (0, 0), edge)
    im = im.resize((size, size), Image.LANCZOS)
    im.save(os.path.join(OUT, name + ".tga"))
    print("wrote", name)

hand("hand")

# round background for item button
size=128
im = Image.new("RGBA",(size,size),(0,0,0,0)); d=ImageDraw.Draw(im)
d.ellipse((4,4,size-4,size-4), fill=(0,0,0,170), outline=(255,210,0,255), width=5)
im.save(os.path.join(OUT,"ring.tga")); print("wrote ring")
