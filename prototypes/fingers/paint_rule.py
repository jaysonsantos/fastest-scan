"""Prototype of the paint rule: which fingers have blank paper around them.

    python3 prototypes/fingers/paint_rule.py DIR/layers/p_*_00.jpg --out OUT

A finger is painted (green) when the cells around its mask have no ink. A finger
with ink around it stays (magenta); the cells with ink are red.
"""

import argparse
import pathlib
import sys

import numpy as np
from PIL import Image

import finger_mask as fm

INK_PIXELS = 4


def ink_values(luma: np.ndarray) -> np.ndarray:
    """The mean of the darkest pixels of each cell."""
    height, width = luma.shape
    grid_h, grid_w = height // fm.CELL, width // fm.CELL
    blocks = luma[: grid_h * fm.CELL, : grid_w * fm.CELL].reshape(grid_h, fm.CELL, grid_w, fm.CELL)
    flat = blocks.transpose(0, 2, 1, 3).reshape(grid_h, grid_w, fm.CELL * fm.CELL)
    return np.partition(flat, INK_PIXELS, axis=2)[..., :INK_PIXELS].mean(axis=2)


def regions(mask: np.ndarray):
    """The connected regions of a mask, 8 neighbours."""
    todo = mask.copy()
    while todo.any():
        y, x = np.argwhere(todo)[0]
        region = np.zeros_like(mask)
        region[y, x] = True
        while True:
            grown = fm.dilate(region, 1) & mask
            if (grown == region).all():
                break
            region = grown
        todo &= ~region
        yield region


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("layers", nargs="+", type=pathlib.Path)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--edge-cells", type=int, default=1)
    parser.add_argument("--margin-cells", type=int, default=3)
    parser.add_argument("--ring-cells", type=int, default=2)
    parser.add_argument("--ring-ink", type=float, default=0.7)
    parser.add_argument("--max-ink-cells", type=int, default=2)
    parser.add_argument("--border-cells", type=int, default=2)
    parser.add_argument("--red-green", type=float, default=0.08)
    parser.add_argument("--skin-tint", type=float, default=0.15)
    parser.add_argument("--yellow-margin", type=float, default=0.05)
    parser.add_argument("--min-luma", type=float, default=0.25)
    parser.add_argument("--max-luma", type=float, default=0.92)
    parser.add_argument("--max-contrast", type=float, default=0.35)
    parser.add_argument("--open-cells", type=int, default=2)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    painted_total = left_total = 0
    for path in args.layers:
        rgb, _, _, outside = fm.measure(path)
        luma = 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]
        ink = ink_values(luma) < args.ring_ink
        raw_skin = fm.skin_mask(path, args)
        skin = fm.finger_mask(raw_skin, outside, args)
        # A dark line next to skin is the shadow of the finger or the edge of the desk.
        ink &= ~fm.dilate(raw_skin, 1)
        # The edge of the page has a shadow and a strip of the desk: no ink of the page.
        inner = np.zeros_like(skin)
        inner[args.border_cells : -args.border_cells, args.border_cells : -args.border_cells] = True
        ink &= inner
        out = rgb.copy()
        grid_h, grid_w = skin.shape
        area = out[: grid_h * fm.CELL, : grid_w * fm.CELL]
        notes = []
        for region in regions(fm.dilate(skin, args.margin_cells) & ~outside):
            core = region & skin
            near = fm.dilate(core, args.edge_cells)
            ring = fm.dilate(core, args.margin_cells + args.ring_cells) & ~near & ~outside
            ring_ink = ring & ink
            painted = int(ring_ink.sum()) <= args.max_ink_cells
            painted_total += painted
            left_total += not painted
            notes.append(f"{int(region.sum())}:{int(ring.sum())}:{int(ring_ink.sum())}{'P' if painted else 'L'}")
            colour = (0.1, 0.8, 0.2) if painted else (1.0, 0.0, 1.0)
            for mask, tint in ((region, colour), (ring_ink, (1.0, 0.0, 0.0))):
                big = np.kron(mask, np.ones((fm.CELL, fm.CELL), dtype=bool))
                area[big] = 0.55 * area[big] + 0.45 * np.array(tint, dtype=np.float32)
        Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8)).save(args.out / path.name, quality=85)
        print(path.name, " ".join(notes))
    print(f"painted {painted_total}, left {left_total}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
