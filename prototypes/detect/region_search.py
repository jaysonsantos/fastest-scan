# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Find the paper region of a frame when the surface around the book is bright.

The detector of `src/lib/detect.zig` takes one threshold (Otsu) on a paper score
and then the largest bright region. A white wall or a bright floor is then the
"paper". This prototype looks at the regions above several thresholds and takes
the one that is most like a sheet of paper: it does not lie on the frame border,
and it fills its own convex hull and the smallest rectangle around the hull.

The idea to choose, among the shapes of several levels, the shape most like a
sheet of paper is from E. Carlinet and T. Géraud (the LRDE method of the SmartDoc
2015 competition), who use the tree of shapes. The regions above a threshold are
the extremal regions of J. Matas, O. Chum, M. Urban, and T. Pajdla, "Robust
wide-baseline stereo from maximally stable extremal regions", BMVC 2002.

Run, with frames of 960 x 540 pixels:

    uv run prototypes/detect/region_search.py out/detect/frames/*.png --out out/detect/result

Each output picture shows the region of the detector of today in red and the
region of the prototype in green. The table on the standard output has one line
for each frame.
"""

import argparse
import dataclasses
import pathlib

import numpy as np
from PIL import Image
from scipy import ndimage
from scipy.spatial import ConvexHull, QhullError

CHROMA_WEIGHT = 1.5
WHITE_PERCENTILE = 90
MIN_AREA_FRACTION = 0.04
# The thresholds of the search, as percentiles of the score of the frame.
LEVEL_PERCENTILES = tuple(range(20, 96, 5))
# A point of the outline has an edge when the score falls by this much from 3
# pixels inside the region to 3 pixels outside it.
EDGE_STEP = 12.0
EDGE_REACH = 3
# The width divided by the height of the smallest rectangle around a region: a
# single page from its side to a spread of two pages.
MIN_ASPECT = 0.3
MAX_ASPECT = 3.3
# Among the regions with an energy near the best one, the largest region wins: a
# spread is one region at a low threshold and two pages at a high one.
NEAR_BEST = 0.8


@dataclasses.dataclass
class Candidate:
    level: float
    mask: np.ndarray
    area_fraction: float
    border_fraction: float
    sides_touched: int
    solidity: float
    rectangle_fill: float
    contrast: float
    aspect: float
    edge_support: float

    @property
    def quality(self) -> float:
        """How much the region is like a sheet of paper: 0 to 1."""
        if not MIN_ASPECT <= self.aspect <= MAX_ASPECT:
            return 0.0
        inside = max(0.0, 1.0 - 3.0 * self.border_fraction)
        return self.solidity * self.rectangle_fill * inside * self.edge_support


def load_yuv(path: pathlib.Path) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """The luma and the chroma of a picture at half the size, as 8-bit video codes."""
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32)
    height, width = rgb.shape[0] // 2 * 2, rgb.shape[1] // 2 * 2
    rgb = rgb[:height, :width].reshape(height // 2, 2, width // 2, 2, 3).mean(axis=(1, 3))
    red, green, blue = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
    u = 128 + (blue - luma) / 1.8556
    v = 128 + (red - luma) / 1.5748
    return luma, u, v


def paper_score(luma: np.ndarray, u: np.ndarray, v: np.ndarray, white: np.ndarray | None = None) -> np.ndarray:
    """The score of the detector: the luma, less the distance of the chroma from the scene white."""
    if white is None:
        white = luma >= np.percentile(luma, WHITE_PERCENTILE)
    white_u, white_v = u[white].mean(), v[white].mean()
    return np.clip(luma - CHROMA_WEIGHT * (np.abs(u - white_u) + np.abs(v - white_v)), 0, 255)


def otsu(values: np.ndarray) -> float:
    histogram = np.bincount(values.astype(np.uint8).ravel(), minlength=256).astype(np.float64)
    total = histogram.sum()
    codes = np.arange(256)
    weight_low = np.cumsum(histogram)
    sum_low = np.cumsum(histogram * codes)
    weight_high = total - weight_low
    with np.errstate(divide="ignore", invalid="ignore"):
        mean_low = sum_low / weight_low
        mean_high = (sum_low[-1] - sum_low) / weight_high
        between = weight_low * weight_high * (mean_low - mean_high) ** 2
    return float(np.nanargmax(between))


def opened(mask: np.ndarray) -> np.ndarray:
    return ndimage.binary_dilation(ndimage.binary_erosion(mask, np.ones((3, 3))), np.ones((3, 3)))


def min_rectangle(points: np.ndarray) -> tuple[float, float]:
    """The area and the aspect of the smallest rectangle around the points of a convex hull.

    The aspect is the side that is more level, divided by the other side.
    """
    best = np.inf
    aspect = 1.0
    for index in range(len(points)):
        edge = points[(index + 1) % len(points)] - points[index]
        length = np.hypot(*edge)
        if length == 0:
            continue
        axis = edge / length
        normal = np.array([-axis[1], axis[0]])
        along = points @ axis
        across = points @ normal
        side_a = along.max() - along.min()
        side_b = across.max() - across.min()
        if side_a * side_b < best:
            best = side_a * side_b
            # The side along the axis is the width when the axis is more level than upright.
            level = abs(axis[0]) >= abs(axis[1])
            width, height = (side_a, side_b) if level else (side_b, side_a)
            aspect = width / max(height, 1e-6)
    return float(best), float(aspect)


def outline_support(mask: np.ndarray, score: np.ndarray) -> float:
    """The part of the outline, off the frame border, where the score steps down to the outside."""
    inner = ndimage.binary_erosion(mask, np.ones((3, 3)), border_value=0)
    outline = mask & ~inner
    outline[0, :] = outline[-1, :] = False
    outline[:, 0] = outline[:, -1] = False
    if not outline.any():
        return 0.0
    # The mean score of the region and of the outside near each point.
    size = 2 * EDGE_REACH + 1
    inside_sum = ndimage.uniform_filter(np.where(mask, score, 0.0), size)
    inside_count = ndimage.uniform_filter(mask.astype(np.float64), size)
    outside_sum = ndimage.uniform_filter(np.where(mask, 0.0, score), size)
    outside_count = ndimage.uniform_filter((~mask).astype(np.float64), size)
    with np.errstate(divide="ignore", invalid="ignore"):
        step = inside_sum / inside_count - outside_sum / outside_count
    step = np.nan_to_num(step[outline], nan=0.0)
    return float((step >= EDGE_STEP).mean())


def describe(mask: np.ndarray, score: np.ndarray, level: float) -> Candidate | None:
    height, width = mask.shape
    area = int(mask.sum())
    if area < MIN_AREA_FRACTION * mask.size:
        return None
    ys, xs = np.nonzero(mask)
    # The part of the outline of the region that is the border of the frame.
    on_border = mask[0].sum() + mask[-1].sum() + mask[:, 0].sum() + mask[:, -1].sum()
    outline = mask & ~ndimage.binary_erosion(mask, np.ones((3, 3)), border_value=0)
    sides = int(mask[0].any()) + int(mask[-1].any()) + int(mask[:, 0].any()) + int(mask[:, -1].any())
    try:
        hull = ConvexHull(np.column_stack([xs, ys]).astype(np.float64))
    except QhullError:
        return None
    hull_points = hull.points[hull.vertices]
    hull_area = hull.volume
    rectangle, aspect = min_rectangle(hull_points)
    ring = ndimage.binary_dilation(mask, np.ones((3, 3)), iterations=4) & ~mask
    contrast = float(score[mask].mean() - score[ring].mean()) if ring.any() else 0.0
    return Candidate(
        level=level,
        mask=mask,
        area_fraction=area / mask.size,
        border_fraction=float(on_border) / max(int(outline.sum()), 1),
        sides_touched=sides,
        solidity=area / max(hull_area, 1.0),
        rectangle_fill=hull_area / max(rectangle, 1.0),
        contrast=contrast,
        aspect=aspect,
        edge_support=outline_support(mask, score),
    )


def current_region(score: np.ndarray) -> Candidate | None:
    """The detector of today: Otsu, an opening, and the largest region."""
    level = otsu(score)
    labels, count = ndimage.label(opened(score > level))
    if count == 0:
        return None
    sizes = ndimage.sum_labels(np.ones_like(labels), labels, index=np.arange(1, count + 1))
    return describe(labels == 1 + int(np.argmax(sizes)), score, level)


def search(score: np.ndarray) -> list[Candidate]:
    """The regions above each threshold, the best first."""
    found: list[Candidate] = []
    for percentile in LEVEL_PERCENTILES:
        level = float(np.percentile(score, percentile))
        labels, count = ndimage.label(opened(score > level))
        for label in range(1, count + 1):
            candidate = describe(labels == label, score, level)
            if candidate is not None:
                found.append(candidate)
    return sorted(found, key=lambda candidate: candidate.quality, reverse=True)


def choose(candidates: list[Candidate], today: Candidate | None) -> Candidate | None:
    """The largest region among the regions that are nearly as good as the best one."""
    pool = candidates + ([today] if today is not None else [])
    if not pool:
        return None
    best = max(candidate.quality for candidate in pool)
    if best <= 0:
        return today
    near = [candidate for candidate in pool if candidate.quality >= NEAR_BEST * best]
    return max(near, key=lambda candidate: candidate.area_fraction)


def overlay(path: pathlib.Path, old: Candidate | None, new: Candidate | None, out: pathlib.Path) -> None:
    picture = np.asarray(Image.open(path).convert("RGB").resize((480, 270)), dtype=np.float32)
    for candidate, tint in ((old, (255, 40, 40)), (new, (40, 220, 40))):
        if candidate is None:
            continue
        mask = candidate.mask[: picture.shape[0], : picture.shape[1]]
        edge = mask & ~ndimage.binary_erosion(mask, np.ones((3, 3)), iterations=2, border_value=0)
        picture[edge] = tint
    Image.fromarray(picture.astype(np.uint8)).save(out)


def line(name: str, candidate: Candidate | None) -> str:
    if candidate is None:
        return f"{name}: none"
    return (
        f"{name}: level {candidate.level:5.1f} area {candidate.area_fraction:.2f} border {candidate.border_fraction:.2f} "
        f"solid {candidate.solidity:.2f} rect {candidate.rectangle_fill:.2f} aspect {candidate.aspect:.2f} "
        f"edges {candidate.edge_support:.2f} quality {candidate.quality:.2f}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("frames", nargs="+", type=pathlib.Path)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--luma", action="store_true", help="search on the luma, not on the paper score")
    parser.add_argument("--verbose", action="store_true", help="print the six best regions of each frame")
    arguments = parser.parse_args()
    arguments.out.mkdir(parents=True, exist_ok=True)
    for path in arguments.frames:
        luma, u, v = load_yuv(path)
        score = paper_score(luma, u, v)
        old = current_region(score)
        candidates = search(luma if arguments.luma else score)
        new = choose(candidates, old)
        same = new is old or (new is not None and old is not None and abs(new.area_fraction - old.area_fraction) < 0.02)
        print(path.name)
        print("  " + line("today", old))
        print("  " + (("same") if same else line("new  ", new)))
        if arguments.verbose:
            for other in candidates[:6]:
                print("  " + line("     ", other))
        overlay(path, old, new, arguments.out / path.name)


if __name__ == "__main__":
    main()
