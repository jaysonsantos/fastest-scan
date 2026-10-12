# 0022: A thin blob of skin in the light is a finger

Date: 2026-10-12. Status: accepted. This record changes the rule of the wide blob
of decision 0014. It is the next step that decision 0021 names.

## Context

The tip of a thumb showed at the bottom edge of 4 of the 63 pages of the
benchmark. Such a tip is 2 to 4 cells high. A wide blob needs skin in all cells
within 2 cells: at the border of the page, that is 3 rows of cells.

A first try made the blob smaller for all skin (`core_cells` of 1). It removed
the tips, and it made two new faults:

- The dark end of a header bar at the border of the page has a red-brown tint.
  It became a finger, and the paint made it white (`p_030_0`).
- The end of the header bar "BUTTON FUNCTIONS" has weak glare in the reference
  frame: dark brown, with the colour of skin. It became a finger of the reference
  frame. The repair then took a frame with strong glare, and the bar end was gold
  again (`p_005_1`).

The two bar ends are darker than a thumb tip: a cell has a mean luma of 0.25 to
0.4 there. The thumb tips have 0.65 to 0.8.

## Decision

- `core_cells` stays 2. Skin of each luma can be a wide blob: a hand with a dark
  skin tone needs that (decision 0018).
- `lit_core_cells` is 1. Skin in the light can be a thinner blob: skin in all
  cells within 1 cell. At the border of the page, that is 2 rows of cells.
- `lit_luma` is 0.45. Skin is in the light when the mean luma of the cell is that
  or more.

The two sizes follow the page width (decision 0021).

## Measurements on the benchmark video

| | Before | Now |
|---|---|---|
| Pages | 63 | 63 |
| Pages with the tip of a thumb at the bottom edge | 4 | 0, and 2 with a thin line of a tip |
| Pages with a skin blob at the bottom edge | 8 | 4 |
| Mean page area painted | 3.37 % | 3.51 % |
| OCR sample: words, good words, mean confidence | 1401, 1035, 80.2 | 1404, 1036, 80.1 |

The 4 pages that keep a skin blob at the bottom edge show a strip of the desk
(`p_015_1`) and shadows, not a thumb.

87 places on 42 pages changed. A person looked at each place, before and after:

- The thumb tips are gone (4 pages). On 2 of them a thin line stays: the upper
  edge of a tip on `p_018_0`, and a small dark mark on `p_031_0`. The upper part
  of such a tip is pale and yellow in the light of the lamp. The skin test does
  not accept it, and the margin of the mask does not reach its edge.
- A brown mark of a thumb on a line of text and on a drawing is gone (`p_006_0`,
  `p_009_0`).
- Most places are a strip or a corner of the wood of the desk at a page edge.
  It is smaller or gone.
- A few places are a shadow at a page edge that changed a little.
- No text and no header bar changed.

The copy of the benchmark at 1920 x 1080 has the same bytes: its two sizes were 1
already. The four enlarged PUCIT videos keep skin on 6 of 105 pages, as before.

## Consequences

- A strip of the wood of the desk in the light at a page edge is a finger now,
  and it gets the colour of the paper. A strip in a shadow stays.
- Print with the colour of skin, in the light, that is 2 cells thick at the
  border of the page counts as a finger. Before, it needed 5 cells.
- To repeat the check of the places, compare the pictures in `pages/` of two
  runs with `--debug-dir`.
