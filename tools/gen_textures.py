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
# round background for item button
size=128
im = Image.new("RGBA",(size,size),(0,0,0,0)); d=ImageDraw.Draw(im)
d.ellipse((4,4,size-4,size-4), fill=(0,0,0,170), outline=(255,210,0,255), width=5)
im.save(os.path.join(OUT,"ring.tga")); print("wrote ring")
