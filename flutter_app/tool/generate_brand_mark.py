"""Derive the DRISHTI mark-only asset (no navy tile) for the splash.

The shipped brand PNG is a rounded-square navy TILE (designed for the
launcher icon and for use on light surfaces). Its tile colour is exactly the
app's canvas navy (#0B132B), so the tile disappears when painted onto the
canvas — but the FLAME canvas adds a radial glow, which makes an opaque
tile read as a dark square. Removing the tile therefore keeps the artwork
floating on the glow.

HOW THE TILE IS REMOVED (and why a threshold is wrong)
------------------------------------------------------
Naively keying every "dark" pixel (max channel < 60) also deletes the
ARTWORK's own anti-aliased edge pixels — a teal stroke blended 10% into the
navy measures (13,40,59) and would be punched out, leaving notches along
the outline (the "cut border" artefact).

Instead we remove ONLY pixels that are the tile colour itself, within a
small RGB tolerance. Every artwork pixel — including the dim blends along
its outline — is preserved, so the mark keeps smooth edges.

Deterministic and reproducible:  venv\\Scripts\\python.exe tool\\generate_brand_mark.py
"""

from __future__ import annotations

import os
from pathlib import Path

from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE = REPO_ROOT / "DRISHTI_Brand_Kit_Flutter" / "flutter_assets" / "drishti_icon_512.png"
TARGET = REPO_ROOT / "flutter_app" / "assets" / "branding" / "drishti_mark.png"

# Tile colour of the shipped brand PNG (sampled from the asset).
TILE_RGB = (11, 19, 43)
# Per-channel tolerance for "this pixel is the tile".
TILE_TOLERANCE = 8


def _is_tile(rgb: tuple[int, int, int]) -> bool:
    return all(abs(rgb[i] - TILE_RGB[i]) <= TILE_TOLERANCE for i in range(3))


def main() -> int:
    if not SOURCE.exists():
        print(f"source asset missing: {SOURCE}")
        return 1

    image = Image.open(SOURCE).convert("RGBA")
    pixels = image.load()
    removed = 0
    kept = 0
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            if _is_tile((r, g, b)):
                pixels[x, y] = (r, g, b, 0)
                removed += 1
            else:
                kept += 1

    TARGET.parent.mkdir(parents=True, exist_ok=True)
    image.save(TARGET)
    print(
        f"wrote {TARGET} ({image.width}x{image.height}; "
        f"{removed} tile pixels removed, {kept} artwork pixels kept)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
