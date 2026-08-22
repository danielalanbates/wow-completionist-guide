#!/usr/bin/env python3
"""Generate CompletionRoute/Textures/*.tga (uncompressed 32-bit TGA, power-of-two)."""
from PIL import Image, ImageChops, ImageDraw, ImageFilter
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

def _catmull(points, closed=True, steps=18):
    """smooth curve through the given points (Catmull-Rom -> polyline)"""
    pts = list(points)
    n = len(pts)
    out = []
    rng = range(n) if closed else range(n - 1)
    for i in rng:
        p0 = pts[(i - 1) % n] if closed else pts[max(0, i - 1)]
        p1 = pts[i]
        p2 = pts[(i + 1) % n]
        p3 = pts[(i + 2) % n] if closed else pts[min(n - 1, i + 2)]
        for j in range(steps):
            t = j / steps
            t2, t3 = t * t, t * t * t
            x = 0.5 * ((2*p1[0]) + (-p0[0] + p2[0]) * t +
                       (2*p0[0] - 5*p1[0] + 4*p2[0] - p3[0]) * t2 +
                       (-p0[0] + 3*p1[0] - 3*p2[0] + p3[0]) * t3)
            y = 0.5 * ((2*p1[1]) + (-p0[1] + p2[1]) * t +
                       (2*p0[1] - 5*p1[1] + 4*p2[1] - p3[1]) * t2 +
                       (-p0[1] + 3*p1[1] - 3*p2[1] + p3[1]) * t3)
            out.append((x, y))
    return out

# One continuous outline of a right hand seen palm-on, index finger up, thumb out to the left and
# the middle/ring/little fingers curled into the palm - the shape of the classic pointing cursor,
# traced as a closed curve rather than assembled from primitives (which read as stacked pills).
HAND_OUTLINE = [
    (0.385, 0.095),                                          # fingertip
    (0.443, 0.132), (0.457, 0.248), (0.468, 0.358), (0.482, 0.452),   # right side of the index
    (0.530, 0.482),                                          # web between index and middle
    (0.615, 0.430), (0.723, 0.444), (0.772, 0.514),          # curled middle finger
    (0.752, 0.552),
    (0.822, 0.564), (0.856, 0.630), (0.822, 0.676),          # curled ring finger
    (0.856, 0.708), (0.858, 0.772), (0.804, 0.812),          # curled little finger
    (0.780, 0.884), (0.672, 0.948), (0.516, 0.960),          # heel of the palm
    (0.382, 0.940), (0.302, 0.882),                          # wrist
    (0.258, 0.812), (0.212, 0.776),                          # into the thumb
    (0.166, 0.732), (0.152, 0.672), (0.196, 0.640),          # thumb tip
    (0.250, 0.638), (0.272, 0.600),                          # thumb back to the palm edge
    (0.268, 0.520), (0.283, 0.462), (0.312, 0.436),          # left palm edge into the index web
    (0.327, 0.332), (0.331, 0.228), (0.340, 0.130),          # left side of the index
]

# interior creases: where one part of the hand passes in front of another
HAND_CREASES = [
    [(0.530, 0.482), (0.610, 0.508), (0.700, 0.548), (0.752, 0.592)],   # middle finger against the palm
    [(0.712, 0.524), (0.786, 0.586), (0.822, 0.648)],                   # middle / ring
    [(0.780, 0.618), (0.840, 0.684), (0.850, 0.746)],                   # ring / little
    [(0.316, 0.440), (0.398, 0.462), (0.492, 0.452)],                   # index base knuckle
    [(0.272, 0.626), (0.344, 0.656), (0.440, 0.694), (0.552, 0.708)],   # thumb across the palm
]

def hand(name, size=128):
    """Pointing hand, drawn WHITE with baked greyscale shading: the addon tints it to the player's
    class colour with SetVertexColor, which multiplies, so the shading and the dark outline survive
    as darker shades of that colour."""
    S = 4
    w = size * S
    def L(v): return v * w
    def pxs(pts): return [(L(x), L(y)) for x, y in pts]

    silhouette = Image.new("L", (w, w), 0)
    ImageDraw.Draw(silhouette).polygon(pxs(_catmull(HAND_OUTLINE)), fill=255)

    def odd(n): return n if n % 2 == 1 else n + 1
    LW = max(3, int(w * 0.024))
    grown = silhouette.filter(ImageFilter.MaxFilter(odd(LW * 2)))
    edge = Image.composite(Image.new("L", (w, w), 0), grown, silhouette)

    creases = Image.new("L", (w, w), 0)
    cd = ImageDraw.Draw(creases)
    for line in HAND_CREASES:
        cd.line(pxs(_catmull(line, closed=False)), fill=255, width=int(w * 0.016), joint="curve")
    creases = Image.composite(creases, Image.new("L", (w, w), 0), silhouette)
    creases = creases.filter(ImageFilter.GaussianBlur(w * 0.004))

    # form: lit from the upper left, so the finger and the left of the palm are bright and the
    # curled fingers on the right fall away
    inner = silhouette.filter(ImageFilter.GaussianBlur(w * 0.05))
    shade = Image.new("L", (w, w), 0)
    sd = ImageDraw.Draw(shade)
    sd.ellipse((L(0.62), L(0.42), L(1.00), L(0.88)), fill=80)     # curled fingers
    sd.ellipse((L(0.32), L(0.78), L(0.80), L(1.02)), fill=70)     # under the palm
    sd.ellipse((L(0.438), L(0.10), L(0.510), L(0.46)), fill=55)   # right edge of the finger
    shade = shade.filter(ImageFilter.GaussianBlur(w * 0.04))
    light = Image.new("L", (w, w), 0)
    ld = ImageDraw.Draw(light)
    ld.ellipse((L(0.330), L(0.115), L(0.410), L(0.44)), fill=95)  # along the finger
    ld.ellipse((L(0.300), L(0.52), L(0.480), L(0.80)), fill=75)   # palm
    ld.ellipse((L(0.175), L(0.648), L(0.262), L(0.742)), fill=45) # thumb
    light = light.filter(ImageFilter.GaussianBlur(w * 0.03))

    base = Image.new("L", (w, w), 200)
    base = ImageChops.add(base, Image.eval(inner, lambda v: int(v * 0.16)))
    base = ImageChops.subtract(base, shade)
    base = ImageChops.add(base, light)
    base = ImageChops.subtract(base, Image.eval(creases, lambda v: int(v * 0.85)))

    im = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    im.paste(Image.merge("RGB", (base, base, base)), (0, 0), silhouette)
    # fingernail: a slightly lighter oval near the tip
    nail = Image.new("L", (w, w), 0)
    ImageDraw.Draw(nail).ellipse((L(0.352), L(0.140), L(0.432), L(0.232)), fill=255)
    nail = Image.composite(nail, Image.new("L", (w, w), 0), silhouette)
    im.paste((238, 238, 238, 255), (0, 0), Image.eval(nail.filter(ImageFilter.GaussianBlur(w * 0.004)), lambda v: int(v * 0.5)))
    im.paste((32, 30, 28, 255), (0, 0), edge)

    im = im.resize((size, size), Image.LANCZOS)
    im.save(os.path.join(OUT, name + ".tga"))
    print("wrote", name)

hand("hand")

# round background for item button
size=128
im = Image.new("RGBA",(size,size),(0,0,0,0)); d=ImageDraw.Draw(im)
d.ellipse((4,4,size-4,size-4), fill=(0,0,0,170), outline=(255,210,0,255), width=5)
im.save(os.path.join(OUT,"ring.tga")); print("wrote ring")
