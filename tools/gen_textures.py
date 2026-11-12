#!/usr/bin/env python3
"""Generate CompletionRoute/Textures/*.tga (uncompressed 32-bit TGA, power-of-two)."""
from PIL import Image, ImageChops, ImageDraw, ImageFilter
import os
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "CompletionRoute", "Textures")
os.makedirs(OUT, exist_ok=True)

# The pointer (arrow*.tga) is drawn by tools/gen_pointer.py: an archery arrow, since 2026-11-11.

# round background for item button
size=128
im = Image.new("RGBA",(size,size),(0,0,0,0)); d=ImageDraw.Draw(im)
d.ellipse((4,4,size-4,size-4), fill=(0,0,0,170), outline=(255,210,0,255), width=5)
im.save(os.path.join(OUT,"ring.tga")); print("wrote ring")
