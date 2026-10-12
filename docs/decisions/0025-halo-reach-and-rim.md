# 0025: The halo of a finger reaches farther, and its rim belongs to the mask

Date: 2026-10-12. Status: accepted. This record changes two sizes and one limit
of decisions 0014 and 0022. The number 0024 belongs to a record on the branch
`android-app`.

## Context

After decision 0022, a thin line of a thumb tip stayed on 2 of the 63 pages of
the benchmark.

- **`p_018_0`.** The tip at the corner of the page is pale and yellow in the
  light of the lamp. A cell has the colour (0.89, 0.70, 0.42): green minus blue
  is larger than red minus green, as for gold print, so the skin test does not
  accept it. Such a cell has the look of a halo (a tint, no texture), and the
  halo of the mask covers it. But the halo reached only 10 cells from the margin
  of the few skin cells, and the tip is longer. The rim of the tip also stayed:
  it has a line of shadow, so its cells have more texture than a halo cell.
- **`p_031_0`.** A dark mark of 3 pixels at the bottom edge. It comes from a
  donor frame, which shows the edge of its own thumb there.

## Decision

- **`halo_cells` is 16**, before 10.
- **`rim_cells` is 1.** After the halo, the mask grows one cell more over the
  cells of a rim. A cell of a rim has the tint and the luma of a halo cell, and
  the texture that skin can have (a luma range of 0.35 at most). A cell with
  text has more texture and no tint.
- **The size limit of the paint counts the finger alone.** A finger larger than
  15 % of the page is not painted. Before, the limit counted the margin and the
  halo too. They are paper, and with a longer halo the limit kept hands that it
  painted before.

The two sizes follow the page width (decision 0021).

## What was tried and is not in the code

- **One more cell around the halo, over each kind of cell.** It removed the rim,
  and it cut text next to a thumb on 3 pages: the lower half of a word, a letter
  at the end of a line.
- **Paint the cells at the page border under a finger of the reference frame,
  also where a donor frame repaired them.** It removed the mark on `p_031_0`,
  and it cut what the booklet prints up to the page edge: 12 pixels of the end
  of a header bar, and the bottom of a line of text.
- **A skin test that accepts the pale yellow cells.** Gold print has the same
  colour. No test was made.

## Measurements

The benchmark video:

| | Before | Now |
|---|---|---|
| Pages | 63 | 63 |
| Mean page area painted | 3.51 % | 3.61 % |
| OCR sample: words, good words, mean confidence | 1404, 1036, 80.1 | 1403, 1036, 80.2 |

60 places on 34 pages changed. A person looked at each place, before and after:

- The corner of `p_018_0` is clean, but for a faint line.
- A dark mark at the edge of a page is gone (`p_001_0`).
- Most places are paper with a tint at a page edge or next to the fold, which
  has the colour of the paper around it now.
- No text, no drawing, and no header bar changed.

The result pages of the PUCIT videos that keep an area with the colour of skin
at the page border (the measure of decision 0018):

| | Pages | Before | Now |
|---|---|---|---|
| Ten videos as they are | 434 | 30 | 23 |
| Four videos, enlarged four times | 105 | 6 | 5 |

The copy of the benchmark at 1920 x 1080 keeps no skin blob at the bottom edge,
as before.

## Consequences

- The mark on `p_031_0` stays: a donor frame can show the thin edge of its own
  finger at the page border, and a strip that thin is no finger for its mask.
- A hand that covers less than 15 % of the page as skin gets the colour of the
  paper also when its shadow is large. On the enlarged PUCIT videos, dark parts
  between the fingers of such a hand stay as black marks: a cell with a luma
  below 0.15 is no skin.
- Paper with a tint and no texture, up to 16 cells from the margin of a finger,
  counts as its halo. Pale print with no texture there is lost.
