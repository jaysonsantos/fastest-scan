"""Measure the colour of hands on the layer pictures of other videos.

The skin test of `src/lib/finger.zig` got its numbers from one video. This script
shows what the test does on other hands and in other light.

Run the CLI on a video with `--debug-dir DIR --debug-layers`, then:

    python3 prototypes/fingers/skin_samples.py DIR/layers/p_*_00.jpg --out OUT

The script finds blobs of cells with a red tint. Its rule is much wider than the
skin test, so it also finds hands that the skin test does not accept. For each
blob it prints the mean colour, and the share of the cells that fail each part of
the skin test. A picture per layer shows the blobs: a person must check that a
blob is a hand, and not a printed picture.

With `--rule 0014`, the numbers and the pictures use the skin test of decision
0014 in place of the one of decision 0018.
"""

import argparse
import dataclasses
import pathlib
import sys

import numpy as np
from PIL import Image, ImageDraw

CELL = 8
OUTSIDE_GRAY = 128 / 255
OUTSIDE_TOLERANCE = 0.03
# Rec. 709 luma weights, as `color.rgbLuma`.
LUMA_WEIGHTS = np.array([0.2126, 0.7152, 0.0722])

# The wide rule of this script for a cell that can be skin.
WIDE_MIN_RED_OVER_GREEN = 0.02
WIDE_MIN_RED_OVER_BLUE = 0.05
WIDE_MIN_LUMA = 0.04
WIDE_MAX_LUMA = 0.95
WIDE_MAX_CONTRAST = 0.6
MIN_BLOB_CELLS = 12
PICTURE_SCALE = 3


@dataclasses.dataclass(frozen=True)
class SkinRule:
    """The numbers of `finger.Options` that the skin test of a cell uses."""

    min_red_over_green: float = 0.08
    min_red_fraction: float = 0.12
    min_dark_red_over_green: float = 0.04
    max_blue_over_red: float = 0.05
    max_yellow_excess: float = 0.05
    min_luma: float = 0.15
    dark_luma: float = 0.25
    max_dark_yellow_fraction: float = 0.75
    max_luma: float = 0.92
    max_cell_contrast: float = 0.35


RULES = {
    # Decision 0014: one difference for all cells, and no cell below a luma of 0.25.
    "0014": SkinRule(min_dark_red_over_green=0.08, min_luma=0.25, dark_luma=0.0),
    "0018": SkinRule(),
}


def cell_view(plane: np.ndarray) -> np.ndarray:
    """A plane as (grid_h, CELL, grid_w, CELL, ...)."""
    height, width = plane.shape[:2]
    grid_h, grid_w = height // CELL, width // CELL
    cropped = plane[: grid_h * CELL, : grid_w * CELL]
    return cropped.reshape(grid_h, CELL, grid_w, CELL, *plane.shape[2:])


def measure(rgb: np.ndarray):
    """The mean colour, the luma range, and the outside flag of each cell."""
    luma = rgb @ LUMA_WEIGHTS
    mean = cell_view(rgb).mean(axis=(1, 3))
    luma_cells = cell_view(luma)
    contrast = luma_cells.max(axis=(1, 3)) - luma_cells.min(axis=(1, 3))
    gray = np.abs(rgb - OUTSIDE_GRAY).max(axis=2) <= OUTSIDE_TOLERANCE
    outside = cell_view(gray).mean(axis=(1, 3)) > 0.5
    return mean, contrast, outside


def skin_tests(mean: np.ndarray, contrast: np.ndarray, rule: SkinRule) -> dict:
    """Each part of the skin test of `finger.isSkin`, as a mask of the cells that pass."""
    red, green, blue = mean[..., 0], mean[..., 1], mean[..., 2]
    luma = mean @ LUMA_WEIGHTS
    needed_red = np.clip(rule.min_red_fraction * red, rule.min_dark_red_over_green, rule.min_red_over_green)
    max_green_over_blue = np.where(
        luma < rule.dark_luma,
        rule.max_dark_yellow_fraction * (red - green),
        red - green + rule.max_yellow_excess,
    )
    return {
        "red_over_green": red - green >= needed_red,
        "blue_over_red": blue - red <= rule.max_blue_over_red,
        "yellow": green - blue <= max_green_over_blue,
        "min_luma": luma >= rule.min_luma,
        "max_luma": luma <= rule.max_luma,
        "contrast": contrast <= rule.max_cell_contrast,
    }


def wide_rule(mean: np.ndarray, contrast: np.ndarray, outside: np.ndarray) -> np.ndarray:
    red, green, blue = mean[..., 0], mean[..., 1], mean[..., 2]
    luma = mean @ LUMA_WEIGHTS
    return (
        (red - green >= WIDE_MIN_RED_OVER_GREEN)
        & (red - blue >= WIDE_MIN_RED_OVER_BLUE)
        & (luma >= WIDE_MIN_LUMA)
        & (luma <= WIDE_MAX_LUMA)
        & (contrast <= WIDE_MAX_CONTRAST)
        & ~outside
    )


def blobs(mask: np.ndarray) -> list:
    """The groups of set cells that touch at a side, as lists of (y, x)."""
    seen = np.zeros_like(mask)
    found = []
    for start in zip(*np.nonzero(mask)):
        if seen[start]:
            continue
        stack = [start]
        seen[start] = True
        members = []
        while stack:
            y, x = stack.pop()
            members.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < mask.shape[0] and 0 <= nx < mask.shape[1] and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        found.append(members)
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("layers", nargs="+", type=pathlib.Path)
    parser.add_argument("--out", type=pathlib.Path, help="directory for the pictures")
    parser.add_argument("--rule", choices=sorted(RULES), default="0018")
    parser.add_argument("--cells", type=pathlib.Path, help="write the colour of each blob cell to this CSV file")
    arguments = parser.parse_args()
    rule = RULES[arguments.rule]
    if arguments.out:
        arguments.out.mkdir(parents=True, exist_ok=True)

    cell_rows = []
    print("layer blob cells border red green blue luma accepted " + " ".join(f"fail_{name}" for name in skin_tests(np.zeros((1, 1, 3)), np.zeros((1, 1)), rule)))
    for path in arguments.layers:
        rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255
        mean, contrast, outside = measure(rgb)
        tests = skin_tests(mean, contrast, rule)
        accepted = np.logical_and.reduce(list(tests.values())) & ~outside
        candidates = wide_rule(mean, contrast, outside)

        picture = Image.open(path).convert("RGB")
        picture = picture.resize((picture.width * PICTURE_SCALE, picture.height * PICTURE_SCALE), Image.NEAREST)
        draw = ImageDraw.Draw(picture)
        side = CELL * PICTURE_SCALE
        grid_h, grid_w = candidates.shape
        blob_index = 0
        for members in blobs(candidates):
            if len(members) < MIN_BLOB_CELLS:
                continue
            ys = np.array([y for y, _ in members])
            xs = np.array([x for _, x in members])
            colors = mean[ys, xs]
            luma = colors @ LUMA_WEIGHTS
            border = bool((ys == 0).any() or (xs == 0).any() or (ys == grid_h - 1).any() or (xs == grid_w - 1).any())
            border = border or any(
                outside[min(max(y + dy, 0), grid_h - 1), min(max(x + dx, 0), grid_w - 1)]
                for y, x in members
                for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1))
            )
            fails = " ".join(f"{1 - tests[name][ys, xs].mean():.2f}" for name in tests)
            print(
                f"{path.stem} {blob_index} {len(members)} {int(border)} "
                f"{colors[:, 0].mean():.3f} {colors[:, 1].mean():.3f} {colors[:, 2].mean():.3f} {luma.mean():.3f} "
                f"{accepted[ys, xs].mean():.2f} {fails}"
            )
            for (y, x), color, cell_luma in zip(members, colors, luma):
                cell_rows.append(f"{path.stem},{blob_index},{color[0]:.4f},{color[1]:.4f},{color[2]:.4f},{cell_luma:.4f},{contrast[y, x]:.4f},{int(accepted[y, x])}")
                box = (x * side, y * side, (x + 1) * side - 1, (y + 1) * side - 1)
                draw.rectangle(box, outline=(0, 200, 0) if accepted[y, x] else (255, 0, 0))
            draw.text((xs.min() * side + 2, ys.min() * side + 2), str(blob_index), fill=(0, 0, 255))
            blob_index += 1
        if arguments.out:
            picture.save(arguments.out / f"{path.stem}.png")

    if arguments.cells:
        arguments.cells.write_text("layer,blob,red,green,blue,luma,contrast,accepted\n" + "\n".join(cell_rows) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
