# 0004: The first page detector uses a paper mask

Date: 2026-10-09. Status: accepted for the first version.

## Context

The research (`docs/research/page-detection.md`) recommends an oriented Hough
transform on edges, with a contrast score for each candidate quad. That method
works on a white page on a white desk. It needs many parts: Lab conversion,
morphological closing, the Hough accumulator, quad enumeration, and the score.

The benchmark shows white paper on a dark wood desk. A hand covers a part of the
page edge in most frames. The two pages of a spread are not in one plane, so the
outline of a spread has six corners, not four.

## Decision

The first detector works on a mask of paper pixels:

1. Paper score = luma minus the distance of the chroma from the scene white.
   Otsu's method gives the threshold for each frame.
2. The largest connected region of paper pixels is the document.
3. The outer contour gives edge points. A robust line fit per side ignores the
   notches that fingers make.
4. For a spread, the gutter is the line near the middle with the strongest
   brightness valley or step. Each page then gets its own top and bottom line.
5. A cell of a page is "covered" when it is not paper and connects to the outside
   of the page. A printed picture does not connect to the outside; a finger does.

The detector is one module with one result type (`PageLayout`). A second detector
can replace it.

## Consequences

- The detector fails when the desk is as bright as the paper. The CLI reports the
  frames without a detection. The Hough detector is the planned fix.
- A page with a dark print to its edge on all four sides is not a paper region.
  This is also a limit of the first version.
- The method is fast: a few passes over a 480 x 270 image per frame.
