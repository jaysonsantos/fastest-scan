"""Prototype of the finger mask of the fusion, on the layer pictures of the CLI.

Run the CLI with `--debug-dir DIR --debug-layers`, then:

    python3 prototypes/fingers/finger_mask.py DIR/layers/p_005_0_*.jpg --out OUT

Each output picture shows a layer with the masks on it: purple where the old rule
and the new rule agree, blue for the old rule alone, red for the new rule alone.
The numbers mirror `src/lib/fuse.zig`.
"""

import argparse
import pathlib
import sys

import numpy as np
from PIL import Image

CELL = 8
DARK_LUMA = 0.7
SKIN_TINT = 0.15
MIN_SKIN_LUMA = 0.3
MARGIN_CELLS = 3
OUTSIDE_GRAY = 128 / 255
OUTSIDE_TOLERANCE = 0.03


def cells(plane: np.ndarray) -> np.ndarray:
    """The mean of each cell of a plane."""
    height, width = plane.shape
    grid_h, grid_w = height // CELL, width // CELL
    cropped = plane[: grid_h * CELL, : grid_w * CELL]
    return cropped.reshape(grid_h, CELL, grid_w, CELL).mean(axis=(1, 3))


def smooth(grid: np.ndarray) -> np.ndarray:
    """A 3x3 mean, with the border cells repeated."""
    padded = np.pad(grid, 1, mode="edge")
    out = np.zeros_like(grid)
    for dy in range(3):
        for dx in range(3):
            out += padded[dy : dy + grid.shape[0], dx : dx + grid.shape[1]]
    return out / 9


def flood(seeds: np.ndarray, passable: np.ndarray) -> np.ndarray:
    """The passable cells that connect to a seed through passable cells."""
    marked = seeds & passable
    while True:
        grown = marked.copy()
        grown[1:, :] |= marked[:-1, :]
        grown[:-1, :] |= marked[1:, :]
        grown[:, 1:] |= marked[:, :-1]
        grown[:, :-1] |= marked[:, 1:]
        grown &= passable
        if (grown == marked).all():
            return marked
        marked = grown


def dilate(mask: np.ndarray, rounds: int) -> np.ndarray:
    out = mask.copy()
    for _ in range(rounds):
        padded = np.pad(out, 1)
        grown = np.zeros_like(out)
        for dy in range(3):
            for dx in range(3):
                grown |= padded[dy : dy + out.shape[0], dx : dx + out.shape[1]]
        out = grown
    return out


def border(shape: tuple[int, int]) -> np.ndarray:
    seeds = np.zeros(shape, dtype=bool)
    seeds[0, :] = seeds[-1, :] = True
    seeds[:, 0] = seeds[:, -1] = True
    return seeds


def cell_range(plane: np.ndarray) -> np.ndarray:
    """The largest minus the smallest value of each cell of a plane."""
    height, width = plane.shape
    grid_h, grid_w = height // CELL, width // CELL
    blocks = plane[: grid_h * CELL, : grid_w * CELL].reshape(grid_h, CELL, grid_w, CELL)
    return blocks.max(axis=(1, 3)) - blocks.min(axis=(1, 3))


def measure(path: pathlib.Path):
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255
    luma = 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]
    spread = rgb.max(axis=2) - rgb.min(axis=2)
    outside_px = (np.abs(luma - OUTSIDE_GRAY) < OUTSIDE_TOLERANCE) & (spread < OUTSIDE_TOLERANCE)
    outside = cells(outside_px.astype(np.float32)) > 0.5
    mean = smooth(cells(luma))
    tint = cells(rgb[..., 0] - rgb[..., 2])
    return rgb, mean, tint, outside


def erode(mask: np.ndarray, rounds: int) -> np.ndarray:
    """A cell stays when its 8 neighbours are set. Beyond the grid counts as set."""
    out = mask.copy()
    for _ in range(rounds):
        padded = np.pad(out, 1, constant_values=True)
        kept = np.ones_like(out)
        for dy in range(3):
            for dx in range(3):
                kept &= padded[dy : dy + out.shape[0], dx : dx + out.shape[1]]
        out = kept
    return out


def skin_mask(path: pathlib.Path, options):
    """The cells with the colour of skin, without texture."""
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255
    luma = 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]
    red, green, blue = (cells(rgb[..., channel]) for channel in range(3))
    mean = cells(luma)
    contrast = cell_range(luma)
    red_green = red - green
    green_blue = green - blue
    return (
        (red_green >= options.red_green)
        & (blue - red <= options.blue_red)
        & (green_blue <= red_green + options.yellow_margin)
        & (mean >= options.min_luma)
        & (mean <= options.max_luma)
        & (contrast <= options.max_contrast)
    )


def finger_mask(skin, outside, options):
    skin = skin & ~outside
    # A finger is a wide blob. A thin strip of desk at the edge of the page is not.
    core = erode(skin | outside, options.open_cells) & ~outside
    blob = dilate(core, options.open_cells + 1) & skin
    seeds = border(skin.shape) | dilate(outside, 1)
    return flood(seeds, blob)


def old_mask(mean, tint, outside):
    dark = (mean < DARK_LUMA) & ~outside
    mask = flood(border(mean.shape), dark)
    mask &= (tint >= SKIN_TINT) & (mean >= MIN_SKIN_LUMA)
    return dilate(mask, MARGIN_CELLS) & ~outside


def new_mask(mean, tint, outside, skin_tint, bridge_tint):
    skin = (tint >= bridge_tint) & (mean >= MIN_SKIN_LUMA) & ~outside
    thing = ((mean < DARK_LUMA) | skin) & ~outside
    seeds = border(mean.shape) | dilate(outside, 1)
    mask = flood(seeds, thing)
    mask &= (tint >= skin_tint) & (mean >= MIN_SKIN_LUMA)
    return dilate(mask, MARGIN_CELLS) & ~outside


def overlay(rgb, old, new):
    out = rgb.copy()
    grid_h, grid_w = old.shape
    for mask, colour in ((old & new, (0.6, 0.2, 0.9)), (old & ~new, (0.1, 0.3, 1.0)), (new & ~old, (1.0, 0.1, 0.1))):
        big = np.kron(mask, np.ones((CELL, CELL), dtype=bool))
        area = out[: grid_h * CELL, : grid_w * CELL]
        area[big] = 0.6 * area[big] + 0.4 * np.array(colour, dtype=np.float32)
    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("layers", nargs="+", type=pathlib.Path)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--skin-tint", type=float, default=SKIN_TINT)
    parser.add_argument("--red-green", type=float, default=0.08)
    parser.add_argument("--blue-red", type=float, default=0.05)
    parser.add_argument("--yellow-margin", type=float, default=0.05)
    parser.add_argument("--min-luma", type=float, default=0.25)
    parser.add_argument("--max-luma", type=float, default=0.92)
    parser.add_argument("--max-contrast", type=float, default=0.35)
    parser.add_argument("--open-cells", type=int, default=2)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    for path in args.layers:
        rgb, mean, tint, outside = measure(path)
        old = old_mask(mean, tint, outside)
        new = dilate(finger_mask(skin_mask(path, args), outside, args), MARGIN_CELLS) & ~outside
        overlay(rgb, old, new).save(args.out / path.name, quality=85)
        print(f"{path.name}: old {old.mean():.4f} new {new.mean():.4f} outside {outside.mean():.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
