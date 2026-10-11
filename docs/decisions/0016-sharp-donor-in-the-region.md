# 0016: A region takes the donor that is sharp in the region

Date: 2026-10-11. Status: accepted. This record adds one term to the choice of
the donor of a region (decision 0013).

## Context

Decision 0013 ranks the donors of a region by two numbers, both measured around
the region: the agreement with the reference, and the contrast as a fraction of
the contrast of the reference. Around the region the reference is good, so it can
be the measure.

That says nothing about the region itself. The header "BUTTON FUNCTIONS" showed
the fault: the bar is the region, and around it there is blank paper and the edge
of the bar. Two donors agreed there equally well. The one that won was blurred on
the letters of the bar (decision 0014 names this fault).

In the region the reference is wrong, so it cannot be the measure. The donors
can: they show the same content there.

## Decision

- Each donor that passes the patch check gets a sharpness number in the region:
  the root mean square of the luma difference between two pixels next to each
  other, over the cells that the donor repairs, at the shift of the donor. The
  number is the smaller one of the two directions, across and down. Blur makes
  each edge wide and its squares small. The blur of a camera that moves does this
  in one direction only.
- The quality of a donor is its old quality times its sharpness as a fraction of
  the sharpest donor of the region (`fuse.innerSharpness`).
- When the sharpest donor is below 4 luma codes (of 200 for paper), the region
  shows blank paper. Then the term is 1 for all donors: noise is not sharpness.

## Measurements on the benchmark video

| | Before | Now |
|---|---|---|
| Pages | 63 | 63 |
| Run time, warm cache | 38 s to 41 s | 40 s |
| OCR words / good words / mean confidence, 16 pages | 1396 / 1038 / 80.7 | 1401 / 1035 / 80.2 |
| OCR good words, all 63 pages | 2417 | 2379 |

- The header "BUTTON FUNCTIONS" is sharp again. No other header got worse.
- One page changed in 1.5 % of its pixels (that header), the others in 0.7 % or
  less.
- The OCR number of all pages is lower by 38 words. That is noise: the two pages
  with the largest loss (14 and 12 words) changed in 245 and in 1855 of their
  2.4 million pixels.

## Consequences

- Glare with a fine pattern has large differences between pixels too. The rule
  looks only at the cells that the donor repairs, where it is darker than the
  reference: the cells where a donor has such glare do not count. A donor with
  weak glare on all of the region can still win.
- The number depends on the contrast: of two donors that are equally sharp, the
  one with the darker ink wins.
- A region with one donor does not change.

## Ideas from other work

- The sum of squared gradients as a measure of focus (the Tenengrad measure):
  Tenenbaum 1970 and Krotkov 1987, see `docs/references.md`. Here it compares
  frames in one region, with plain differences of neighbour pixels and the
  smaller one of the two directions.
