# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Find the paper as the region that a flood from the frame border does not reach.

When the surface around the book is as bright as the paper, no brightness
threshold separates the two. But the book has an outline: a step of brightness or
of colour, or a thin shadow line. This prototype marks the pixels with a strong
gradient of luma or chroma as walls, and lets a flood run from the frame border
over all other pixels. What the flood does not reach is the walls and all that
they enclose: the book with its text, and thin lines such as the edge of a wall.
An opening removes the thin lines, and the largest region that stays holds the
paper. A hand on the book stays too, when a bracelet or a shadow closes its
outline: the bright pixels of the paper mask of the detector of today take the
hand off again.

The detector of today stays the first choice: its region is good on a dark desk,
also for a page that runs out of the frame. The region of this prototype takes
its place only when it is clearly more like a sheet of paper.

The flood enters a page that runs out of the frame: this rule is for a book that
lies inside the frame.

Run, with frames of 960 x 540 pixels:

    uv run prototypes/detect/edge_flood.py out/detect/frames/*.png --out out/detect/flood

Each output picture shows the walls in blue and the outline of the region in
green. The table on the standard output has one line for each frame.
"""

import argparse
import pathlib

import numpy as np
from PIL import Image
from scipy import ndimage
from scipy.spatial import ConvexHull, QhullError

MIN_AREA_FRACTION = 0.04
CHROMA_WEIGHT = 1.5
WHITE_PERCENTILE = 90
# The region of today stays when it is this much like a sheet of paper.
GOOD_QUALITY = 0.5
# The new region must be better than the region of today by this much.
QUALITY_MARGIN = 0.15
# The walls have this many pixels on each side of an outline.
WALL_HALF_WIDTH = 2
# How many codes of chroma count as one code of luma in the gradient.
CHROMA_GAIN = 3.0
SMOOTH_SIGMA = 1.0


def load_yuv(path: pathlib.Path) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """The luma and the chroma of a picture at half the size, as 8-bit video codes."""
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32)
    height, width = rgb.shape[0] // 2 * 2, rgb.shape[1] // 2 * 2
    rgb = rgb[:height, :width].reshape(height // 2, 2, width // 2, 2, 3).mean(axis=(1, 3))
    red, green, blue = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
    return luma, 128 + (blue - luma) / 1.8556, 128 + (red - luma) / 1.5748


def gradient(luma: np.ndarray, u: np.ndarray, v: np.ndarray) -> np.ndarray:
    """The strength of the step at each pixel: luma, and chroma with a gain."""
    total = np.zeros_like(luma)
    for plane, gain in ((luma, 1.0), (u, CHROMA_GAIN), (v, CHROMA_GAIN)):
        smooth = ndimage.gaussian_filter(plane, SMOOTH_SIGMA)
        total += gain * np.hypot(ndimage.sobel(smooth, axis=0) / 8, ndimage.sobel(smooth, axis=1) / 8)
    return total


def enclosed_region(walls: np.ndarray, thin: int) -> np.ndarray | None:
    """The largest region that a flood from the frame border does not reach.

    `thin` is the half width of the lines that the opening removes.
    """
    labels, count = ndimage.label(~walls)
    on_border = np.unique(np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]]))
    reached = np.isin(labels, on_border[on_border > 0])
    solid = ndimage.binary_opening(~reached, np.ones((3, 3)), iterations=thin)
    labels, count = ndimage.label(solid)
    if count == 0:
        return None
    sizes = ndimage.sum_labels(np.ones_like(labels), labels, index=np.arange(1, count + 1))
    best = int(np.argmax(sizes))
    if sizes[best] < MIN_AREA_FRACTION * walls.size:
        return None
    return labels == best + 1


def bright_mask(luma: np.ndarray, u: np.ndarray, v: np.ndarray) -> np.ndarray:
    """The paper mask of the detector of today: Otsu on the paper score, and an opening."""
    white = luma >= np.percentile(luma, WHITE_PERCENTILE)
    score = np.clip(luma - CHROMA_WEIGHT * (np.abs(u - u[white].mean()) + np.abs(v - v[white].mean())), 0, 255)
    histogram = np.bincount(score.astype(np.uint8).ravel(), minlength=256).astype(np.float64)
    codes = np.arange(256)
    low = np.cumsum(histogram)
    low_sum = np.cumsum(histogram * codes)
    high = histogram.sum() - low
    with np.errstate(divide="ignore", invalid="ignore"):
        between = low * high * (low_sum / low - (low_sum[-1] - low_sum) / high) ** 2
    return ndimage.binary_opening(score > np.nanargmax(between), np.ones((3, 3)))


def largest(mask: np.ndarray) -> np.ndarray | None:
    labels, count = ndimage.label(mask)
    if count == 0:
        return None
    sizes = ndimage.sum_labels(np.ones_like(labels), labels, index=np.arange(1, count + 1))
    best = int(np.argmax(sizes))
    if sizes[best] < MIN_AREA_FRACTION * mask.size:
        return None
    return labels == best + 1


def quality(mask: np.ndarray | None) -> float:
    """How much a region is like a sheet of paper that lies inside the frame: 0 to 1."""
    if mask is None:
        return 0.0
    outline = mask & ~ndimage.binary_erosion(mask, np.ones((3, 3)), border_value=0)
    on_border = mask[0].sum() + mask[-1].sum() + mask[:, 0].sum() + mask[:, -1].sum()
    solidity, fill = shape(mask)
    return solidity * fill * max(0.0, 1.0 - 3.0 * on_border / max(int(outline.sum()), 1))


def shape(mask: np.ndarray) -> tuple[float, float]:
    """How much of its convex hull the region fills, and the hull of its smallest rectangle."""
    ys, xs = np.nonzero(mask)
    try:
        hull = ConvexHull(np.column_stack([xs, ys]).astype(np.float64))
    except QhullError:
        return 0.0, 0.0
    points = hull.points[hull.vertices]
    best = np.inf
    for index in range(len(points)):
        edge = points[(index + 1) % len(points)] - points[index]
        length = np.hypot(*edge)
        if length == 0:
            continue
        axis = edge / length
        along, across = points @ axis, points @ np.array([-axis[1], axis[0]])
        best = min(best, (along.max() - along.min()) * (across.max() - across.min()))
    return mask.sum() / hull.volume, hull.volume / best


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("frames", nargs="+", type=pathlib.Path)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--step", type=float, default=4.0, help="a gradient above this value is a wall")
    parser.add_argument("--grow", type=int, default=1, help="make the walls thicker by this many pixels")
    parser.add_argument("--thin", type=int, default=4, help="the opening removes lines up to two times this width")
    arguments = parser.parse_args()
    arguments.out.mkdir(parents=True, exist_ok=True)
    for path in arguments.frames:
        luma, u, v = load_yuv(path)
        walls = gradient(luma, u, v) > arguments.step
        if arguments.grow > 0:
            walls = ndimage.binary_dilation(walls, np.ones((3, 3)), iterations=arguments.grow)
        bright = bright_mask(luma, u, v)
        today = largest(bright)
        region = enclosed_region(walls, arguments.thin)
        if region is not None:
            # The outline of the paper is in the middle of its walls, and a hand is not bright.
            region = largest(ndimage.binary_erosion(region, np.ones((3, 3)), iterations=WALL_HALF_WIDTH) & bright)
        today_quality, region_quality = quality(today), quality(region)
        take_new = today_quality < GOOD_QUALITY and region_quality > today_quality + QUALITY_MARGIN
        print(f"{path.name}: today {today_quality:.2f}, new {region_quality:.2f} -> {'new' if take_new else 'today'}")
        region = region if take_new else today
        picture = np.asarray(Image.open(path).convert("RGB").resize((luma.shape[1], luma.shape[0])), dtype=np.float32)
        picture[walls] = 0.5 * picture[walls] + 0.5 * np.array([60, 90, 255])
        if region is not None:
            grown = region
            edge = grown & ~ndimage.binary_erosion(grown, np.ones((3, 3)), iterations=2, border_value=0)
            picture[edge] = (40, 230, 40)
        Image.fromarray(picture.astype(np.uint8)).save(arguments.out / path.name)


if __name__ == "__main__":
    main()
