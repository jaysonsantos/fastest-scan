# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Find a page by its four straight edges.

The two searches of `edge_flood.py` need a closed outline around the book and a
free desk around that outline. On a white desk with a wood grain and many things
on it, they fail: the grain is walls, a thing that touches the book stays with
the book, and one weak part of the page outline lets the flood in.

This prototype looks for straight lines in the steps of the frame, and then for
four lines that make a quad with a page inside:

1. The step at each pixel has a strength and a direction. The direction comes
   from the three planes together: the gradient of a multi-image of S. Di Zenzo,
   "A note on the gradient of a multi-image", Computer Vision, Graphics, and
   Image Processing 33, 1986.
2. Each pixel with a step votes for the lines through it that go across the
   direction of its step: the Hough transform in the form of R. O. Duda and
   P. E. Hart, "Use of the Hough transformation to detect lines and curves in
   pictures", Communications of the ACM 15, 1972, with the use of the gradient
   direction of F. O'Gorman and M. B. Clowes, "Finding picture edges through
   collinearity of feature points", IEEE Transactions on Computers C-25, 1976.
3. The lines with the most votes are the candidates. A quad has two lines that
   go about one way and two lines that go about across them.
4. A quad is a page when each of its sides has steps along most of its length,
   and when most of its inside is bright (the paper mask of the detector of
   today). A gap in one side or a thing at one corner does not break it.
5. The result is the page with the largest product of its area and the support
   of its four sides. The area alone is not enough: a quad with the edge of the
   desk as one side is larger than the book, but two of its sides then go on
   past the corners of the book, where they have no steps.
6. The two pages of an open book do not lie in one plane, so their upper edges
   are two lines. The quad of the two pages together then has little support at
   its upper side, and one page wins. So a second page that has one side in
   common with the result, and about its size, joins the result.

To take four lines with support as the page is the common approach of the
SmartDoc 2015 competition (J.-C. Burie et al., ICDAR 2015).

The Zig code (`src/lib/lines.zig`, and `lineRegion` in `src/lib/detect.zig`)
came from this script and then got stricter rules, which this script does not
have: `docs/decisions/0026-line-search-for-a-page-on-a-bright-desk.md`. Its
lines are also more exact. So the numbers of the two differ.

Run, with frames of 960 pixels in width:

    uv run prototypes/detect/line_quads.py out/detect/frames/*.png --out out/detect/quads

Each output picture shows the candidate lines in blue and the quad in green. The
table on the standard output has one line for each frame.
"""

import argparse
import dataclasses
import itertools
import pathlib

import numpy as np
from edge_flood import CHROMA_GAIN, SMOOTH_SIGMA, bright_mask, load_yuv
from PIL import Image, ImageDraw
from scipy import ndimage

ANGLE_BINS = 180
# A pixel votes for the lines within this many degrees of the direction of its step.
VOTE_SPREAD = 2
# A weak step votes too, with its strength. No step has more votes than this.
MIN_VOTE_STRENGTH = 3.0
MAX_VOTE_STRENGTH = 20.0
# Two lines nearer than this are one line.
PEAK_ANGLE = 5
PEAK_DISTANCE = 6
# A side has support where a step of this strength lies within this distance of
# the line, with a direction within this angle of the normal of the line.
SUPPORT_STRENGTH = 6.0
SUPPORT_DISTANCE = 2
SUPPORT_ANGLE = 20
# The sides of a quad: two pairs of lines. The lines of a pair differ by at most
# the first angle (the view from above the book is not exact), and the two pairs
# by at least the second angle.
MAX_PAIR_ANGLE = 30
MIN_CROSS_ANGLE = 60
MIN_SIDE_FRACTION = 0.15
# A page: each side has steps along this part of its length, the four sides
# together along this part, and this part of the inside is bright.
MIN_SIDE_SUPPORT = 0.5
MIN_MEAN_SUPPORT = 0.7
MIN_BRIGHT = 0.8
# A side with steps along this part of its length has full support: the corners of
# a book are round, and the two ends of a side have no steps.
FULL_SUPPORT = 0.9
# A smaller quad is more often a text block or a picture than a page.
MIN_AREA_FRACTION = 0.08
# The second page of an open book has an area within this factor of the first page.
MAX_PAGE_AREA_RATIO = 1.7


def steps(luma: np.ndarray, u: np.ndarray, v: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """The strength of the step at each pixel, and the angle of its direction in degrees, 0 to 180."""
    strength = np.zeros_like(luma)
    xx, xy, yy = np.zeros_like(luma), np.zeros_like(luma), np.zeros_like(luma)
    for plane, gain in ((luma, 1.0), (u, CHROMA_GAIN), (v, CHROMA_GAIN)):
        smooth = ndimage.gaussian_filter(plane, SMOOTH_SIGMA)
        down, across = gain * ndimage.sobel(smooth, axis=0) / 8, gain * ndimage.sobel(smooth, axis=1) / 8
        strength += np.hypot(down, across)
        xx += across * across
        xy += across * down
        yy += down * down
    angle = np.degrees(0.5 * np.arctan2(2 * xy, xx - yy)) % 180
    return strength, angle


def hough(strength: np.ndarray, angle: np.ndarray) -> tuple[np.ndarray, int]:
    """The votes for each line: the row is the angle of the normal, the column the distance plus `offset`."""
    height, width = strength.shape
    offset = int(np.ceil(np.hypot(height, width))) + 1
    votes = np.zeros((ANGLE_BINS, 2 * offset + 1))
    ys, xs = np.nonzero(strength > MIN_VOTE_STRENGTH)
    weight = np.minimum(strength[ys, xs], MAX_VOTE_STRENGTH)
    base = np.round(angle[ys, xs]).astype(int)
    for spread in range(-VOTE_SPREAD, VOTE_SPREAD + 1):
        bins = (base + spread) % ANGLE_BINS
        radians = np.radians(bins)
        distance = np.round(xs * np.cos(radians) + ys * np.sin(radians)).astype(int)
        np.add.at(votes, (bins, distance + offset), weight)
    return votes, offset


def peaks(votes: np.ndarray, offset: int, count: int, min_votes: float) -> list[tuple[float, float, float]]:
    """The lines with the most votes: (angle in degrees, distance, votes)."""
    smooth = ndimage.uniform_filter(votes, size=3, mode="constant")
    # The table goes on past its two ends in the angle, with the distance mirrored.
    padded = np.concatenate([smooth[-PEAK_ANGLE:, ::-1], smooth, smooth[:PEAK_ANGLE, ::-1]], axis=0)
    highest = ndimage.maximum_filter(padded, size=(2 * PEAK_ANGLE + 1, 2 * PEAK_DISTANCE + 1), mode="constant")
    is_peak = (padded == highest) & (padded >= min_votes)
    is_peak = is_peak[PEAK_ANGLE:-PEAK_ANGLE]
    rows, columns = np.nonzero(is_peak)
    order = np.argsort(smooth[rows, columns])[::-1][:count]
    return [(float(rows[index]), float(columns[index] - offset), float(smooth[rows[index], columns[index]])) for index in order]


class Line:
    """A line with the places along it where the frame has a step that fits."""

    def __init__(self, degrees: float, distance: float, strength: np.ndarray, angle: np.ndarray) -> None:
        self.degrees = degrees
        radians = np.radians(degrees)
        self.normal = np.array([np.cos(radians), np.sin(radians)])
        self.along = np.array([-self.normal[1], self.normal[0]])
        self.distance = distance
        height, width = strength.shape
        self.reach = int(np.ceil(np.hypot(height, width)))
        positions = np.arange(-self.reach, self.reach + 1)
        supported = np.zeros(len(positions), dtype=bool)
        for shift in range(-SUPPORT_DISTANCE, SUPPORT_DISTANCE + 1):
            points = (distance + shift) * self.normal[None, :] + positions[:, None] * self.along[None, :]
            xs, ys = np.round(points[:, 0]).astype(int), np.round(points[:, 1]).astype(int)
            inside = (xs >= 0) & (xs < width) & (ys >= 0) & (ys < height)
            fits = np.zeros(len(positions), dtype=bool)
            difference = np.abs((angle[ys[inside], xs[inside]] - degrees + 90) % 180 - 90)
            fits[inside] = (strength[ys[inside], xs[inside]] > SUPPORT_STRENGTH) & (difference < SUPPORT_ANGLE)
            supported |= fits
        self.sum = np.concatenate([[0], np.cumsum(supported)])

    def position(self, point: np.ndarray) -> float:
        return float(point @ self.along)

    def support(self, first: np.ndarray, second: np.ndarray) -> float:
        """The part of the segment between two points of the line that has a step."""
        low, high = sorted((self.position(first), self.position(second)))
        low_index = int(np.clip(round(low) + self.reach, 0, len(self.sum) - 1))
        high_index = int(np.clip(round(high) + self.reach + 1, 0, len(self.sum) - 1))
        if high_index <= low_index:
            return 0.0
        return float(self.sum[high_index] - self.sum[low_index]) / (high_index - low_index)


def crossing(first: Line, second: Line) -> np.ndarray | None:
    matrix = np.array([first.normal, second.normal])
    if abs(np.linalg.det(matrix)) < 1e-6:
        return None
    return np.linalg.solve(matrix, np.array([first.distance, second.distance]))


def angle_between(first: Line, second: Line) -> float:
    return abs((first.degrees - second.degrees + 90) % 180 - 90)


def polygon_area(corners: np.ndarray) -> float:
    xs, ys = corners[:, 0], corners[:, 1]
    return 0.5 * abs(float(np.sum(xs * np.roll(ys, -1) - np.roll(xs, -1) * ys)))


def is_convex(corners: np.ndarray) -> bool:
    edges = np.roll(corners, -1, axis=0) - corners
    turns = edges[:, 0] * np.roll(edges, -1, axis=0)[:, 1] - edges[:, 1] * np.roll(edges, -1, axis=0)[:, 0]
    return bool(np.all(turns > 0) or np.all(turns < 0))


@dataclasses.dataclass
class Page:
    """A quad of four lines that is a page. The corners go around the quad."""

    corners: np.ndarray
    lines: tuple[Line, Line, Line, Line]
    area: float
    supports: list[float]
    bright: float
    score: float


def inside_mask(corners: np.ndarray, shape: tuple[int, int]) -> np.ndarray:
    mask = Image.new("1", (shape[1], shape[0]), 0)
    ImageDraw.Draw(mask).polygon([tuple(corner) for corner in corners], fill=1)
    return np.asarray(mask)


def find_pages(lines: list[Line], bright: np.ndarray) -> list[Page]:
    """The quads of four lines that are pages, the best one first."""
    height, width = bright.shape
    min_side = MIN_SIDE_FRACTION * min(height, width)
    pairs = [
        (first, second)
        for first, second in itertools.combinations(lines, 2)
        if angle_between(first, second) <= MAX_PAIR_ANGLE
    ]
    pages = []
    for (left, right), (top, bottom) in itertools.combinations(pairs, 2):
        if len({id(left), id(right), id(top), id(bottom)}) < 4:
            continue
        if min(angle_between(a, b) for a in (left, right) for b in (top, bottom)) < MIN_CROSS_ANGLE:
            continue
        cycle = [(left, top), (top, right), (right, bottom), (bottom, left)]
        corners = [crossing(a, b) for a, b in cycle]
        if any(corner is None for corner in corners):
            continue
        corners = np.array(corners)
        if np.any(corners < 0) or np.any(corners[:, 0] > width - 1) or np.any(corners[:, 1] > height - 1):
            continue
        if not is_convex(corners):
            continue
        area = polygon_area(corners)
        if area < MIN_AREA_FRACTION * height * width:
            continue
        sides = [(top, corners[0], corners[1]), (right, corners[1], corners[2]), (bottom, corners[2], corners[3]), (left, corners[3], corners[0])]
        if any(np.hypot(*(end - start)) < min_side for _, start, end in sides):
            continue
        supports = [line.support(start, end) for line, start, end in sides]
        if min(supports) < MIN_SIDE_SUPPORT or np.mean(supports) < MIN_MEAN_SUPPORT:
            continue
        inside = inside_mask(corners, bright.shape)
        bright_part = float(bright[inside].mean()) if inside.any() else 0.0
        if bright_part < MIN_BRIGHT:
            continue
        score = area * float(np.prod(np.minimum(1.0, np.array(supports) / FULL_SUPPORT)))
        pages.append(Page(corners, (top, right, bottom, left), area, supports, bright_part, score))
    pages.sort(key=lambda page: page.score, reverse=True)
    return pages


def second_page(first: Page, pages: list[Page]) -> Page | None:
    """The page on the other side of one side of `first`: the other page of an open book."""
    middle = first.corners.mean(axis=0)
    for other in pages[1:]:
        if not 1 / MAX_PAGE_AREA_RATIO <= other.area / first.area <= MAX_PAGE_AREA_RATIO:
            continue
        shared = [line for line in first.lines if any(line is candidate for candidate in other.lines)]
        if len(shared) != 3:
            continue
        # Three lines in common: the two pages lie between the same two lines, and
        # the third line is the side between them. The fourth lines are the outer sides.
        other_middle = other.corners.mean(axis=0)
        between = [line for line in shared if (middle @ line.normal - line.distance) * (other_middle @ line.normal - line.distance) < 0]
        if len(between) == 1:
            return other
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("frames", nargs="+", type=pathlib.Path)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--lines", type=int, default=24, help="the number of candidate lines")
    arguments = parser.parse_args()
    arguments.out.mkdir(parents=True, exist_ok=True)
    for path in arguments.frames:
        luma, u, v = load_yuv(path)
        height, width = luma.shape
        strength, angle = steps(luma, u, v)
        bright = bright_mask(luma, u, v)
        votes, offset = hough(strength, angle)
        # A line needs steps along a part of the short side of the frame.
        min_votes = MIN_SIDE_FRACTION * min(height, width) * SUPPORT_STRENGTH
        lines = [Line(degrees, distance, strength, angle) for degrees, distance, _ in peaks(votes, offset, arguments.lines, min_votes)]
        pages = find_pages(lines, bright)
        picture = Image.open(path).convert("RGB").resize((width, height))
        draw = ImageDraw.Draw(picture)
        for line in lines:
            start = line.distance * line.normal - line.reach * line.along
            end = line.distance * line.normal + line.reach * line.along
            draw.line([tuple(start), tuple(end)], fill=(60, 90, 255), width=1)
        if not pages:
            print(f"{path.name}: {len(lines)} lines, no page")
        else:
            first = pages[0]
            second = second_page(first, pages)
            for page in (first, second):
                if page is not None:
                    draw.polygon([tuple(corner) for corner in page.corners], outline=(40, 230, 40), width=3)
            supports = " ".join(f"{value:.2f}" for value in first.supports)
            print(
                f"{path.name}: {len(lines)} lines, {len(pages)} quads, page with {first.area / (height * width):.2f} of the frame,"
                f" side support {supports}, bright {first.bright:.2f}"
                + ("" if second is None else f", second page with {second.area / (height * width):.2f}")
            )
        picture.save(arguments.out / path.name)


if __name__ == "__main__":
    main()
