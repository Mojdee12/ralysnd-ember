#!/usr/bin/env python3
"""Bake the Map Control HOME backdrop variant (fidelity batch 2,
owner order 2026-11-23).

The owner accepted Home R2 with one note: the background must be
like the pro3 sample — its dotted map is a FINE halftone (dot
pitch ~2.6 dp at the portrait cover scale), while the shared
backdrop (tool/bake_backdrop_mobile.py) bakes a 1-unit lattice
that displays at ~5.1 dp pitch and reads coarse and loud behind
the hero, even under the Home scrim.

This variant bakes the SAME field from the SAME source data and
projection (lib/ui/ember/world_map_data.dart), so the live
actors land on the same geography, but:

  * the dot lattice halves to 0.5 units (~2.55 dp display
    pitch — the sample's grain),
  * the dot core shrinks (~0.15 units) so dots stay separate
    points at the finer pitch,
  * the palette warms from steel blue to the sample's warm
    taupe-grey and lifts a step, so the field still reads
    after the shell's faint scrim settles it,
  * the base gradient darkens toward neutral black and the
    HUD grid/traces quieten a step.

Only the shell's Home tab uses this asset (MapBackdropVisual's
faint variant); every other backdrop keeps the shared asset
byte-for-byte.

Usage: python3 tool/bake_backdrop_home.py
Output: assets/backdrop/map_backdrop_home.webp (3200x1600,
the shared asset's class), via a PNG intermediate in /tmp.
"""

import hashlib
import math
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "lib" / "ui" / "ember" / "world_map_data.dart"
TMP_PNG = Path("/tmp/map_backdrop_home.png")
OUT = ROOT / "assets" / "backdrop" / "map_backdrop_home.webp"

FIELD_W, FIELD_H = 360.0, 180.0
SCALE = 13  # bake px per field unit -> 4680x2340 (as the shared bake)
W, H = int(FIELD_W * SCALE), int(FIELD_H * SCALE)
# Screen px at the reference window (1200x780, cover = 780/180).
COVER = 780 / 180.0


def load_raster():
    text = DATA.read_text()
    lat_top = float(re.search(r"worldMapLatTop = ([\d.]+)", text).group(1))
    lat_bot = float(re.search(r"worldMapLatBottom = (-?[\d.]+)", text).group(1))
    rows = re.findall(r"'([.#]+)'", text.split("worldMapRows = [")[1].split("];")[0])
    cols = len(rows[0])
    assert all(len(r) == cols for r in rows), "ragged raster"
    land = np.zeros((len(rows), cols), dtype=bool)
    for r, row in enumerate(rows):
        for c, ch in enumerate(row):
            land[r, c] = ch == "#"
    return land, lat_top, lat_bot


LAND, LAT_TOP, LAT_BOT = load_raster()
ROWS, COLS = LAND.shape


def land_at(field_x, field_y):
    """Land test for a field-space point, via the source raster."""
    lon = field_x - 180.0
    lat = LAT_TOP - field_y / (FIELD_H / (LAT_TOP - LAT_BOT))
    c = int((lon + 180.0) / 360.0 * COLS)
    r = int((LAT_TOP - lat) / (LAT_TOP - LAT_BOT) * ROWS)
    if 0 <= r < ROWS and 0 <= c < COLS:
        return bool(LAND[r, c])
    return False


def h2(a, b, salt=0):
    """Deterministic 0..1 hash of two ints (stable across runs)."""
    digest = hashlib.md5(f"{a}:{b}:{salt}".encode()).digest()
    return int.from_bytes(digest[:4], "little") / 0xFFFFFFFF


def bake():
    # ---- base: radial ocean gradient centred (0.48, 0.42) ----
    # Home variant: darker and neutral (the sample's ground is
    # a warm-neutral near-black, not the shared bake's blue).
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    cx, cy = 0.48 * W, 0.42 * H
    dist = np.sqrt(((xx - cx) / (0.72 * W)) ** 2 + ((yy - cy) / (0.72 * H)) ** 2)
    t = np.clip(dist, 0, 1)
    inner = np.array([14, 16, 21], np.float32)   # #0E1015
    mid = np.array([9, 11, 15], np.float32)      # #090B0F
    edge = np.array([5, 6, 9], np.float32)       # #050609
    base = np.where(
        (t < 0.5)[..., None],
        inner + (mid - inner) * (t / 0.5)[..., None],
        mid + (edge - mid) * ((t - 0.5) / 0.5)[..., None],
    )
    img = Image.fromarray(base.astype(np.uint8), "RGB").convert("RGBA")
    draw = ImageDraw.Draw(img, "RGBA")

    # ---- HUD grid: quieter than the shared bake (0.15 -> 0.10)
    grid_rgba = (36, 44, 58, int(0.10 * 255))
    step = 16.0 * SCALE  # 16 field units = ~69 screen px
    x = 8.0 * SCALE
    while x < W:
        draw.line([(x, 0), (x, H)], fill=grid_rgba, width=2)
        x += step
    y = 8.0 * SCALE
    while y < H:
        draw.line([(0, y), (W, y)], fill=grid_rgba, width=2)
        y += step

    # ---- circuit / HUD traces in ocean voids (seeded, as shared)
    rng = np.random.default_rng(20261102)
    traces = 0
    attempts = 0
    while traces < 46 and attempts < 900:
        attempts += 1
        ox, oy = rng.uniform(6, FIELD_W - 40), rng.uniform(6, FIELD_H - 26)
        ok = True
        for px in np.arange(ox - 2, ox + 34, 2.0):
            for py in np.arange(oy - 2, oy + 22, 2.0):
                if land_at(px, py):
                    ok = False
                    break
            if not ok:
                break
        if not ok:
            continue
        alpha = int(rng.uniform(20, 34))
        color = (48, 58, 74, alpha)
        pts = [(ox, oy)]
        segs = int(rng.integers(2, 5))
        horizontal = rng.random() < 0.5
        for _ in range(segs):
            length = rng.uniform(6, 24)
            dx, dy = (length, 0) if horizontal else (0, length)
            if rng.random() < 0.5:
                dx, dy = -dx, -dy
            nx, ny = pts[-1][0] + dx, pts[-1][1] + dy
            if not (2 < nx < FIELD_W - 2 and 2 < ny < FIELD_H - 2):
                break
            if land_at(nx, ny):
                break
            pts.append((nx, ny))
            horizontal = not horizontal
        if len(pts) < 2:
            continue
        sp = [(px * SCALE, py * SCALE) for px, py in pts]
        draw.line(sp, fill=color, width=2, joint="curve")
        for px, py in sp[:: max(1, len(sp) - 1)] + [sp[-1]]:
            r = 3.0
            draw.ellipse([px - r, py - r, px + r, py + r], fill=color)
        traces += 1
    # Sparse tick crosses in the oceans.
    ticks = 0
    attempts = 0
    while ticks < 30 and attempts < 600:
        attempts += 1
        ox, oy = rng.uniform(4, FIELD_W - 4), rng.uniform(4, FIELD_H - 4)
        if land_at(ox, oy) or land_at(ox + 3, oy) or land_at(ox, oy + 3):
            continue
        alpha = int(rng.uniform(24, 38))
        color = (48, 58, 74, alpha)
        cxp, cyp = ox * SCALE, oy * SCALE
        arm = 2.2 * SCALE
        draw.line([(cxp - arm, cyp), (cxp + arm, cyp)], fill=color, width=2)
        draw.line([(cxp, cyp - arm), (cxp, cyp + arm)], fill=color, width=2)
        ticks += 1

    # ---- the dot field: 0.5-unit lattice, coverage-dithered ----
    # Iteration 2 (after the first R3 render): sampling the 2°
    # raster nearest-cell at the finer pitch drew every cell as
    # a solid 2x2 dot block — the land read as a blocky mass,
    # louder than the 1-unit bake. A halftone instead: each
    # lattice point carries a land COVERAGE (the tent-weighted
    # land fraction of its 3x3 raster-cell neighbourhood) and
    # the dot is drawn with probability = coverage, its alpha
    # scaled by coverage — coastlines dissolve into stipple
    # the way the sample's do. The core also shrinks (0.65 ->
    # 0.45 screen px) and the tiers dim a step: the sample's
    # dots are small, dim points with black between them.
    interior = (102, 95, 87)    # warm taupe-grey
    dense = (114, 106, 97)
    coastal = (128, 120, 110)
    r_screen = 0.45             # dot radius, screen px at reference size
    r_bake = r_screen * SCALE / COVER
    # Coverage field over the lattice: rows are field-y (0.5
    # steps over the raster's lat range), cols field-x.
    lat_range = LAT_TOP - LAT_BOT
    land_f = LAND.astype(np.float32)
    padded = np.pad(land_f, 1, mode="edge")
    tent = np.array([[1, 2, 1], [2, 4, 2], [1, 2, 1]], np.float32) / 16.0
    steps_x, steps_y = int(FIELD_W * 2), int(FIELD_H * 2)
    coverage = np.zeros((steps_y, steps_x), np.float32)
    for gj in range(steps_y):
        fy = (gj + 0.5) * 0.5
        r = int(fy / FIELD_H * lat_range / (lat_range / ROWS))
        r = min(max(r, 0), ROWS - 1)
        for gi in range(steps_x):
            fx = (gi + 0.5) * 0.5
            c = int(fx / FIELD_W * COLS)
            c = min(max(c, 0), COLS - 1)
            coverage[gj, gi] = float(
                (padded[r : r + 3, c : c + 3] * tent).sum()
            )
    dots = 0
    for gi in range(steps_x):
        for gj in range(steps_y):
            cov = float(coverage[gj, gi])
            if cov <= 0.0 or h2(gi, gj, 5) >= cov:
                continue
            fx, fy = (gi + 0.5) * 0.5, (gj + 0.5) * 0.5
            jx = (h2(gi, gj, 1) - 0.5) * 0.14
            jy = (h2(gi, gj, 2) - 0.5) * 0.14
            px, py = (fx + jx) * SCALE, (fy + jy) * SCALE
            roll = h2(gi, gj, 3)
            fade = 0.30 + 0.70 * cov
            if cov < 0.99:
                color, alpha = coastal, (0.66 + 0.14 * roll) * fade
                radius = r_bake * (0.92 + 0.26 * h2(gi, gj, 4))
            elif roll < 0.22:
                color, alpha = dense, (0.55 + 0.13 * roll) * fade
                radius = r_bake * (0.88 + 0.3 * h2(gi, gj, 4))
            else:
                color, alpha = interior, (0.42 + 0.18 * roll) * fade
                radius = r_bake * (0.85 + 0.3 * h2(gi, gj, 4))
            a = int(alpha * 255)
            # Soft skirt, then the core (as the shared bake).
            sr = radius * 1.3
            draw.ellipse(
                [px - sr, py - sr, px + sr, py + sr],
                fill=color + (int(a * 0.10),),
            )
            draw.ellipse(
                [px - radius, py - radius, px + radius, py + radius],
                fill=color + (a,),
            )
            dots += 1

    # ---- vignette: radial, gentle (the shell adds its own) ----
    vig = np.clip((dist - 0.62) / 0.55, 0, 1) ** 1.6 * 0.20
    black = Image.fromarray(
        np.dstack([np.zeros((H, W), np.uint8)] * 3 + [(vig * 255).astype(np.uint8)]),
        "RGBA",
    )
    img = Image.alpha_composite(img, black)

    # ---- grain ----
    noise = np.random.default_rng(7).normal(0, 3.2, (H, W, 1)).astype(np.float32)
    arr = np.asarray(img.convert("RGB")).astype(np.float32) + noise
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")

    img.save(TMP_PNG, optimize=True)
    # The shipped asset class: 3200x1600 lossy WebP, like the
    # shared backdrop (build 2116/2118 chain).
    out = img.resize((3200, 1600), Image.LANCZOS)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    out.save(OUT, "WEBP", quality=82, method=6)
    size_mb = OUT.stat().st_size / 1e6
    print(f"baked {OUT}  3200x1600  dots={dots} traces={traces} ticks={ticks}  {size_mb:.2f} MB")


if __name__ == "__main__":
    sys.exit(bake())
