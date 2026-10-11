# 0012: The page-curl correction exists, and it is off by default

Date: 2026-10-11. Status: accepted.

## Context

A page of an open book curls toward the spine. A plane through the four corners of
the page then gives curved text lines. He et al. 2013 (`docs/research/paper-notes.md`)
give a model that needs only the outline of the page: straight side edges, curved
top and bottom edges, and columns that are parallel in space.

## What the code does

- `src/lib/curl.zig` has the page model and the map from the flat page to the
  frame. It puts each column of the page into space with a pinhole camera. The
  focal length is the value that gives the page the width of the document's page
  size. Tests with a synthetic curled page give an error below 1 pixel, where the
  plane through the corners is more than 15 pixels off.
- `src/lib/detect.zig` fits a cubic to the top edge of each page. The bottom edge is
  a straight line plus the bend of the top edge, because a hand often holds the
  bottom edge.
- `src/lib/render.zig` uses the curved map for the reference frame, the donor
  frames, and the pictures of the duplicate search, when `Options.curl` is on.
- The CLI flag is `--curl`.

## Measurements on the benchmark video

| Variant | Pages | OCR good words | OCR mean confidence |
|---|---|---|---|
| Off (plane through the corners) | 63 | 1020 | 79.5 |
| On, top and bottom edge each with its own cubic | 63 | 862 | 74.4 |
| On, bottom edge with the bend of the top edge, bend of 0.6 % or more | 65 | 769 | 73.1 |

With the correction on, 57 of 63 pages took the curved map in the first variant.
Fewer donor frames passed the registration gate (259 and 280 against 313), and in
the last variant one duplicate spread stayed in the result.

## Decision

The correction is off by default. `--curl` turns it on.

## Why it fails on this video

- The booklet is thin. Its real curl is a few pixels, about the size of the error
  of the edge points. The fit then follows the error.
- The outline of the paper mask is the outline of the whole booklet, not of the top
  page. Where the pages below show at an edge, or a page lifts, the outline has a
  shape that the top page does not have.
- Fingers hold the bottom edge. The bottom edge then has too few free points.
- A wrong outline changes the scale of the page from column to column. That is
  worse for the text than a small curl.

## What must be true before the default changes

- A second source for the shape of the page that does not depend on the outline:
  the text lines of the page, or the parallax between the frames of a spread (Kim,
  Chiu, Chandra 2013: the tile shifts of `register.zig` are a disparity map).
- A benchmark video of a thick book, where the curl is large.
- The OCR numbers of that video and of this video do not go down.
