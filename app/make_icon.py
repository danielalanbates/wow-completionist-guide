#!/usr/bin/env python3
"""Generate AppIcon.icns for Completionist's Guide."""
import os
import subprocess
from PIL import Image, ImageDraw

def create_icon_set(output_icns_path):
    iconset_dir = "/tmp/CompletionistGuide.iconset"
    os.makedirs(iconset_dir, exist_ok=True)
    
    # Base canvas 1024x1024
    S = 1024
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    
    # Outer dark rounded square with subtle border
    r = 220
    d.rounded_rectangle([(32, 32), (S - 32, S - 32)], radius=r, fill=(24, 28, 36, 255), outline=(50, 60, 80, 255), width=16)
    
    # Inner circular navigation ring
    cx, cy = S // 2, S // 2
    ring_radius = 380
    d.ellipse([(cx - ring_radius, cy - ring_radius), (cx + ring_radius, cy + ring_radius)], outline=(40, 150, 255, 180), width=12)
    
    # Subtle compass ticks
    for angle_deg in range(0, 360, 45):
        import math
        rad = math.radians(angle_deg)
        r1 = ring_radius - 24
        r2 = ring_radius + 24
        x1 = cx + r1 * math.cos(rad)
        y1 = cy + r1 * math.sin(rad)
        x2 = cx + r2 * math.cos(rad)
        y2 = cy + r2 * math.sin(rad)
        d.line([(x1, y1), (x2, y2)], fill=(40, 180, 255, 200), width=8)

    # Golden Waypoint Chevron / 3D Arrow pointing up
    w = S
    pts = [
        (w * 0.50, w * 0.18),  # tip
        (w * 0.82, w * 0.68),  # right wing
        (w * 0.64, w * 0.68),  # right inner
        (w * 0.64, w * 0.86),  # right stem
        (w * 0.36, w * 0.86),  # left stem
        (w * 0.36, w * 0.68),  # left inner
        (w * 0.18, w * 0.68),  # left wing
    ]
    # Gold gradient fill approximation: main body + outline
    d.polygon(pts, fill=(255, 204, 0, 255), outline=(180, 130, 0, 255))
    
    # Left half highlight for 3D effect
    pts_left = [
        (w * 0.50, w * 0.18),
        (w * 0.18, w * 0.68),
        (w * 0.36, w * 0.68),
        (w * 0.36, w * 0.86),
        (w * 0.50, w * 0.86),
    ]
    d.polygon(pts_left, fill=(255, 228, 80, 255))
    d.line(pts + [pts[0]], fill=(120, 80, 0, 255), width=10, joint="curve")
    
    # Center node dot
    d.ellipse([(cx - 20, cy - 20), (cx + 20, cy + 20)], fill=(255, 255, 255, 255), outline=(0, 0, 0, 255), width=4)

    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for sz in sizes:
        resized = im.resize((sz, sz), Image.LANCZOS)
        resized.save(os.path.join(iconset_dir, f"icon_{sz}x{sz}.png"))
        if sz <= 512:
            resized_2x = im.resize((sz * 2, sz * 2), Image.LANCZOS)
            resized_2x.save(os.path.join(iconset_dir, f"icon_{sz}x{sz}@2x.png"))
            
    subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", output_icns_path], check=True)
    # clean up iconset dir in /tmp
    import shutil
    shutil.rmtree(iconset_dir, ignore_errors=True)
    print(f"Generated icon: {output_icns_path}")

if __name__ == "__main__":
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.icns"
    create_icon_set(out)
