#!/usr/bin/env python3
"""Extract road polylines from a zone-map image on which the paths were marked in a solid colour.

Workflow (Daniel's "download each zone map, mark the paths" pipeline):
  1. Save the in-game / wowhead zone map as PNG (the FULL map, no cropping, so pixels map to 0-100%).
  2. In any paint program draw the roads in pure red (#FF0000, 3-6 px brush). Optionally mark points of
     interest in pure blue (#0000FF) - they are emitted as comments with their coordinates.
  3. python3 tools/trace_roads.py elwynn_marked.png "Elwynn Forest" >> CompletionRoute/Data/Roads_ek.lua

The red mask is down-sampled to a grid (--cell px), turned into a pixel graph, split at junctions, each
branch simplified with Douglas-Peucker and written as {x%, y%} polylines. Branch ends that meet at a
junction share the exact same point, so TravelGraph snaps them into one vertex.
Needs Pillow + numpy (both already on this Mac).
"""
import argparse, math, sys
from collections import defaultdict, deque
import numpy as np
from PIL import Image

def mask_colour(img, rgb, tol):
    a = np.asarray(img.convert('RGB')).astype(int)
    d = np.abs(a - np.array(rgb)).sum(axis=2)
    return d <= tol

def grid_cells(mask, cell):
    h, w = mask.shape
    cells = set()
    for y in range(0, h, cell):
        for x in range(0, w, cell):
            if mask[y:y+cell, x:x+cell].any(): cells.add((x // cell, y // cell))
    return cells

N8 = [(-1,-1),(0,-1),(1,-1),(-1,0),(1,0),(-1,1),(0,1),(1,1)]
def neighbours(c, cells):
    return [(c[0]+dx, c[1]+dy) for dx, dy in N8 if (c[0]+dx, c[1]+dy) in cells]

def thin(cells):
    """Crude thinning: drop a cell if its removal keeps its neighbourhood connected and it has >2 neighbours."""
    changed = True
    cells = set(cells)
    while changed:
        changed = False
        for c in sorted(cells):
            nb = neighbours(c, cells)
            if len(nb) <= 2: continue
            # connected without c?
            seen = {nb[0]}; q = deque([nb[0]])
            while q:
                u = q.popleft()
                for v in neighbours(u, cells):
                    if v != c and v in nb and v not in seen: seen.add(v); q.append(v)
            if len(seen) == len(nb): cells.remove(c); changed = True
    return cells

def branches(cells):
    """Split the pixel graph into chains between junctions/endpoints."""
    deg = {c: len(neighbours(c, cells)) for c in cells}
    nodes = {c for c in cells if deg[c] != 2}
    if not nodes and cells: nodes = {min(cells)}  # pure loop
    used = set(); out = []
    for s in sorted(nodes):
        for n in neighbours(s, cells):
            edge = frozenset((s, n))
            if edge in used: continue
            chain = [s, n]; used.add(edge); prev, cur = s, n
            while cur not in nodes:
                nxt = [v for v in neighbours(cur, cells) if v != prev]
                if not nxt: break
                prev, cur = cur, nxt[0]; chain.append(cur); used.add(frozenset((prev, cur)))
            out.append(chain)
    return out

def dp(pts, tol):
    if len(pts) < 3: return pts
    (ax, ay), (bx, by) = pts[0], pts[-1]
    dx, dy = bx-ax, by-ay; L = math.hypot(dx, dy) or 1e-9
    best, bi = 0, 0
    for i in range(1, len(pts)-1):
        px, py = pts[i]; d = abs(dx*(ay-py) - (ax-px)*dy) / L
        if d > best: best, bi = d, i
    return dp(pts[:bi+1], tol)[:-1] + dp(pts[bi:], tol) if best > tol else [pts[0], pts[-1]]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('image'); ap.add_argument('zone')
    ap.add_argument('--cell', type=int, default=4); ap.add_argument('--tol', type=float, default=1.5, help='DP tolerance in grid cells')
    ap.add_argument('--road', default='255,0,0'); ap.add_argument('--poi', default='0,0,255'); ap.add_argument('--ctol', type=int, default=90)
    ap.add_argument('--flavors', default=None, help='e.g. era=true,tbc=true'); ap.add_argument('--fac', default=None)
    a = ap.parse_args()
    img = Image.open(a.image); W, H = img.size
    road = mask_colour(img, [int(v) for v in a.road.split(',')], a.ctol)
    cells = thin(grid_cells(road, a.cell))
    chains = branches(cells)
    extra = ''
    if a.flavors: extra += ', flavors = { %s }' % a.flavors
    if a.fac: extra += ', fac = "%s"' % a.fac
    print(f'-- traced from {a.image} ({W}x{H}) by tools/trace_roads.py: {len(chains)} road segments')
    for i, ch in enumerate(chains, 1):
        pts = dp(ch, a.tol)
        pct = ['{%.1f, %.1f}' % ((x + 0.5) * a.cell * 100.0 / W, (y + 0.5) * a.cell * 100.0 / H) for x, y in pts]
        if len(pct) >= 2:
            print('add{ zone = "%s", name = "%s traced %d", pts = { %s }%s }' % (a.zone, a.zone, i, ', '.join(pct), extra))
    poi = mask_colour(img, [int(v) for v in a.poi.split(',')], a.ctol)
    pcells = grid_cells(poi, a.cell)
    seen = set()
    for c in sorted(pcells):
        if c in seen: continue
        comp = {c}; q = deque([c])
        while q:
            u = q.popleft()
            for v in neighbours(u, pcells):
                if v not in comp: comp.add(v); q.append(v)
        seen |= comp
        cx = sum(x for x, _ in comp) / len(comp); cy = sum(y for _, y in comp) / len(comp)
        print('-- POI at {%.1f, %.1f}' % ((cx + 0.5) * a.cell * 100.0 / W, (cy + 0.5) * a.cell * 100.0 / H))
    if not chains: print('-- no road pixels found: is the road colour %s within tolerance %d?' % (a.road, a.ctol), file=sys.stderr)

if __name__ == '__main__': main()
