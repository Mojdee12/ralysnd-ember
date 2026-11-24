#!/usr/bin/env python3
"""Bake the Map Control MOBILE backdrop (Android 2.2.0).

Renders the dotted world map as a high-resolution raster asset from
the SAME source data and the SAME equirectangular projection the live
painter uses (app/lib/ui/ember/world_map_data.dart: land raster over
lat 84..-60 mapped onto a 360x180 field), but with the full detail
stack the approved samples show and per-frame painting cannot reach:

  * multi-tier dot luminance with per-dot variance (interior /
    dense-node / coastal tiers from the gemini token sheet),
  * dots on a 1-unit field lattice (~4.3 screen px pitch at the
    1200x780 cover scale, radius ~1.2 screen px),
  * the quiet lat/long HUD grid (~70 screen px spacing),
  * subtle circuit/HUD traces with node dots in the ocean voids,
  * a radial vignette and faint grain.

The live actors (pins, arc, badges) keep using the painter's
projection; this asset is the full field, drawn with BoxFit.cover,
which is the identical transform, so the two stay aligned at any
window size.

Usage: python3 tool/bake_backdrop.py
Output: app/assets/backdrop/map_backdrop.png (3600x1800, 10 px/unit)
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
OUT = ROOT / "assets" / "backdrop" / "map_backdrop.png"

FIELD_W, FIELD_H = 360.0, 180.0
SCALE = 13  # bake px per field unit -> 4680x2340 (portrait cover ~14 device px/unit)
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
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    cx, cy = 0.48 * W, 0.42 * H
    dist = np.sqrt(((xx - cx) / (0.72 * W)) ** 2 + ((yy - cy) / (0.72 * H)) ** 2)
    t = np.clip(dist, 0, 1)
    inner = np.array([16, 28, 44], np.float32)   # #101C2C
    mid = np.array([11, 19, 31], np.float32)     # #0B131F
    edge = np.array([7, 12, 19], np.float32)     # #070C13
    base = np.where(
        (t < 0.5)[..., None],
        inner + (mid - inner) * (t / 0.5)[..., None],
        mid + (edge - mid) * ((t - 0.5) / 0.5)[..., None],
    )
    img = Image.fromarray(base.astype(np.uint8), "RGB").convert("RGBA")
    draw = ImageDraw.Draw(img, "RGBA")

    # ---- HUD grid: ~70 screen px spacing, quiet ----
    # Build 2118 (appearance fix round): alpha 0.26 -> 0.15 — at
    # display scale the old grid read as a harsh coordinate cage
    # next to the samples' near-invisible one.
    grid_rgba = (32, 51, 77, int(0.15 * 255))
    step = 16.0 * SCALE  # 16 field units = ~69 screen px
    x = 8.0 * SCALE
    while x < W:
        draw.line([(x, 0), (x, H)], fill=grid_rgba, width=2)
        x += step
    y = 8.0 * SCALE
    while y < H:
        draw.line([(0, y), (W, y)], fill=grid_rgba, width=2)
        y += step

    # ---- circuit / HUD traces in ocean voids (seeded) ----
    rng = np.random.default_rng(20261102)
    traces = 0
    attempts = 0
    while traces < 46 and attempts < 900:
        attempts += 1
        ox, oy = rng.uniform(6, FIELD_W - 40), rng.uniform(6, FIELD_H - 26)
        # The whole neighbourhood must be water (2-unit margin).
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
        alpha = int(rng.uniform(26, 42))
        color = (42, 66, 99, alpha)
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
        alpha = int(rng.uniform(30, 46))
        color = (42, 66, 99, alpha)
        cxp, cyp = ox * SCALE, oy * SCALE
        arm = 2.2 * SCALE
        draw.line([(cxp - arm, cyp), (cxp + arm, cyp)], fill=color, width=2)
        draw.line([(cxp, cyp - arm), (cxp, cyp + arm)], fill=color, width=2)
        ticks += 1

    # ---- the dot field: 1-unit lattice, land-sampled ----
    # Build 2118 (appearance fix round): the palette is greyer
    # and paler (the old saturated steel blues read as blue
    # blocks), the core is smaller (r 1.22 -> 1.02 screen px)
    # and the soft skirt narrower and fainter (1.55x/0.16 ->
    # 1.35x/0.10), so dots stay separate round points at
    # display scale instead of merging into clusters — the
    # samples' fine dotted map.
    interior = (64, 82, 102)    # #405266
    dense = (82, 102, 124)      # #52667C
    coastal = (104, 124, 146)   # #687C92
    r_screen = 1.02             # dot radius in screen px at reference size
    r_bake = r_screen * SCALE / COVER
    dots = 0
    for gx in range(0, int(FIELD_W)):
        for gy in range(0, int(FIELD_H)):
            fx, fy = gx + 0.5, gy + 0.5
            if not land_at(fx, fy):
                continue
            coast = not (
                land_at(fx + 1, fy)
                and land_at(fx - 1, fy)
                and land_at(fx, fy + 1)
                and land_at(fx, fy - 1)
            )
            jx = (h2(gx, gy, 1) - 0.5) * 0.28
            jy = (h2(gx, gy, 2) - 0.5) * 0.28
            px, py = (fx + jx) * SCALE, (fy + jy) * SCALE
            roll = h2(gx, gy, 3)
            if coast:
                color, alpha = coastal, 0.82 + 0.12 * roll
                radius = r_bake * (0.92 + 0.26 * h2(gx, gy, 4))
            elif roll < 0.22:
                color, alpha = dense, 0.70 + 0.14 * roll
                radius = r_bake * (0.88 + 0.3 * h2(gx, gy, 4))
            else:
                color, alpha = interior, 0.55 + 0.22 * roll
                radius = r_bake * (0.85 + 0.3 * h2(gx, gy, 4))
            a = int(alpha * 255)
            # Soft skirt, then the core.
            sr = radius * 1.35
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

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT, optimize=True)
    size_mb = OUT.stat().st_size / 1e6
    print(f"baked {OUT}  {W}x{H}  dots={dots} traces={traces} ticks={ticks}  {size_mb:.2f} MB")


if __name__ == "__main__":
    sys.exit(bake())
