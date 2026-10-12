# 0021: The sizes of the finger rule follow the page width

Date: 2026-10-12. Status: accepted. This record changes the sizes of decision
0014. It also corrects two statements of decisions 0014 and 0018.

## Context

The finger rule has sizes in cells of 8 pixels: the width that a blob needs, the
margin, the halo, the ring of the paint. Their values came from the benchmark
video, where a page has 1292 pixels in width.

On a smaller page, the same sizes are a larger part of the page:

- A finger is thinner in cells than the 5 cells that a wide blob needs, so it is
  not a finger for the rule. On the PUCIT videos (pages of 350 pixels), a finger
  has 3 to 4 cells.
- The margin and the halo cover more of the page around a finger.

## Decision

`finger.Options.reference_page_width` is 1292, the page width of the benchmark
video. `finger.find` and `finger.paint` change each size in cells for the page
that they get (`Options.forGrid`):

- A distance changes with the page width: `core_cells`, `margin_cells`,
  `halo_cells`, `edge_cells`, `ring_cells`, `page_border_cells`.
- A number of cells changes with the square of the page width:
  `max_hole_cells`, `min_blank_cells`, `max_ink_cells`.
- A size stays 1 or more. A size of 0 stays 0. A value of 0 for
  `reference_page_width` keeps the sizes as they are.

| Page width | Video | Core | Margin | Halo | Hole |
|---|---|---|---|---|---|
| 1292 pixels | The benchmark, 3840 x 2160 | 2 | 3 | 10 | 48 |
| 642 pixels | The benchmark at 1920 x 1080 | 1 | 2 | 5 | 12 |
| 350 pixels | A PUCIT video, 480 x 270 | 1 | 1 | 3 | 4 |

The limits that are a fraction do not change: a finger mask larger than 15 % of
the page stays.

## Measurements

The benchmark video at its full size: the PDF has the same bytes.

The result pages that keep an area with the colour of skin at the page border
(a blob of 12 cells or more, with red minus green of 0.15 of red or more):

| | Pages | Fixed sizes | Sizes that follow the page |
|---|---|---|---|
| Ten PUCIT videos as they are (pages of about 350 pixels) | 434 | 166 | 30 |
| Four PUCIT videos, enlarged four times (pages of about 1070 pixels) | 105 | 6 | 6 |

On 8 pages of the ten videos, a whole hand lies on the page and stays (decision
0014).

The copy of the benchmark at 1920 x 1080 (64 pages of 642 x 926 pixels):

| | Fixed sizes | Sizes that follow the page |
|---|---|---|
| Pages with a skin blob at the bottom edge | 4 | 0 |
| Mean page area painted | 3.18 % | 3.04 % |

52 of its 64 pages changed, each in 1.1 % of its pixels or less. The largest
changes are thumb tips at the bottom edge that are gone, and strips of the desk
at a page edge that are thinner or gone.

## Corrections

- **Decision 0018** said that the copy of the benchmark at 1920 x 1080 keeps no
  finger. That was the count of the program: a finger that the mask finds and
  the paint does not cover. The mask did not find the thumb tips on 4 pages, so
  the count did not have them.
- **Decision 0014** said that no page of the benchmark shows a thumb. No page
  shows a whole thumb. The tip of a thumb stays at the bottom edge of 4 of the 63
  pages (`p_008_0`, `p_016_0`, `p_018_0`, `p_031_0` in the debug pictures), and a
  strip of the desk on one more. Such a tip is thinner than the 5 cells of a wide
  blob. The count of the program does not show it, for the same reason.

## Consequences

- The verbose line "a finger stays on N pages" counts only the fingers that the
  mask finds. A check of a new video needs a look at the pages, or
  `prototypes/fingers/skin_samples.py` on the result pages.
- **Next: a smaller core at the full size.** An experiment with `core_cells` of
  1 on the benchmark leaves a skin blob at the bottom edge of 1 page, in place of
  8, and paints 3.62 % of the page area, in place of 3.37 %. It changes 53 of the
  63 pages, each by 1 % or less. A person must look at each of these pages before
  the value can be the default: a thin strip of print with the colour of skin at
  a page border becomes a finger too.
- The other parts of the fusion still have sizes in pixels and in cells that do
  not follow the page width: the search range of the patch check, for example.
