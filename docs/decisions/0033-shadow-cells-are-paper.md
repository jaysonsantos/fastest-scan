# 0033: A shadow on the paper keeps its own paper colour

Date: 2026-10-16. Status: accepted. This record adds a rule to the paper colour of
`enhance.zig` (the flatten step).

## Context

A camera scan on the phone of 2026-10-16 shows a letter that was folded in three.
It lies on a wooden table under a warm lamp. The PDF of the app has orange streaks
on the lower two thirds of the page. The top third is white.

The folds and the waves of the sheet tilt parts of the paper away from the lamp.
Those parts get less light from the lamp and more light from the wood, so their
shadows are darker and orange.

The flatten step divides the page by the colour of its paper (Zhang and He 2007,
section 4):

1. The paper colour of a cell (1/64 of the page height) is the mean of its
   brightest quarter of pixels.
2. A cubic surface goes through these colours. A cell that is more than 0.06 below
   the surface is not paper (`paper_tolerance`): print, a picture, or a finger.
3. A cell that is not paper takes the colour of the surface.

The division takes away the colour of the light where the cell has its own colour.
In the letter, the cubic surface cannot follow the steps at the two folds and the
streaks of the waves. 581 of 3102 cells were not paper. Most of them were shadows,
0.06 to 0.15 below the surface, so they took the colour of the surface. Their
shadow and its orange stayed in the page.

A test with no limit (`paper_tolerance` 1.0) gave a white page. But that limit
keeps the finger rule, pictures, and grey areas of print alive: the finger search
of `finger.zig` needs the skin colour after the flatten.

## Decision

After the fit of the surface, a group of cells that are not paper becomes paper
when it is a shadow (`enhance.acceptShadows`). Such a cell keeps its own colour,
and the division takes the shadow and its colour away.

A cell can be in a shadow when all of these are true:

- Its green is at most 20 % below the surface (`shadow_depth`). Skin in the light is
  20 % to 35 % below it.
- Its red is less than 0.08 above its green, on the scale where the surface is 1.0
  (`shadow_max_red`). The skin test of `finger.zig` starts at this value. The
  shadows of the letter have 0.03 to 0.08, and the wood of the table up to 0.24.
- Its median luma is at least 95 % of the luma of its paper colour
  (`shadow_min_median`): most of the cell shows the paper. Text in a shadow covers a
  small part of a cell. In a dark bar with white letters, the brightest quarter of
  a cell is in the letters, and most of the cell is dark.

Such cells side by side make a group. The group is a shadow when it fades into the
paper at one place at least: a cell of the group is at most 0.03 below the paper
cell two cells away, and the cell between them is paper too
(`shadow_edge_step`). The unit is the one of `paper_tolerance`.

The small pictures of the duplicate search (`render.renderSignature`) do not use
the rule (`accept_shadows` is false). The limits of decisions 0010, 0031, and 0032
come from pictures without it. With the rule, a bad view of a bent sheet of an
invoice got more blank paper in its small picture, and the stream mode kept it as
a page of its own: 4 pages, before 3.

### Why the fade, and why two cells

The first form had no group test. On the benchmark, it took light grey rows of a
printed phone screen, and cells of red header bars that touch the edge of the
page, for shadows.

The second form wanted a group that touches the border of the page through cells
that are not paper. A grey box inside the page has paper all around it, so it
stays. But the streaks of the letter hang between strips of bright paper, below a
fold with bright paper, so they look like holes in the paper too. That form missed
them.

A shadow fades out: at its edge it goes on into the paper, with small steps from
cell to cell. Print has a sharp edge: the step from the print to the paper is its
full depth. The cell at the edge of print can hold some print and some paper, and
its colour is then between the two. So the test skips that cell and compares with
the paper cell after it.

A test of the fade inside the group (the darkest cell against the edge) did not
work. The grey rows of the printed phone fade by 0.027 inside, because the light
falls across them, and a group of the letter by 0.028.

## Measurements

All runs on 2026-10-16, on the desktop. The cell values come from a build that
printed each cell; the scripts are not in the repository.

| Page | Cells in a shadow group |
|---|---|
| The letter, two passes: 581 of 3102 cells are not paper | 490 |
| The letter, stream mode | 428 |
| The benchmark, 63 pages | 157 |

On the benchmark, the shadow cells are at the edges of the pages (the desk, and
the shadow at the edge of the booklet), and in two grey rows of a printed phone
screen on one page. Those rows are 5.8 % to 6.5 % below the paper. The old rule
made the cells under 6 % white already, so the rows are now white in all their
cells.

## Results

The tint is the part of the page with a difference of more than 16 codes between
the largest and the smallest colour channel of a pixel. The print of the letter
has a green and blue logo and blue lines, so a part of the tint stays.

| Video | Before | With this decision |
|---|---|---|
| The letter, stream mode | 14.2 % of the page has a tint | 5.3 % |
| The letter, two passes | 17.7 % | 5.2 % |
| The benchmark, two passes | 63 pages, 13103005 bytes, 2294 good words of OCR on all pages | 63 pages, 13103000 bytes, 2294 good words |

On the benchmark, 46 of 63 pages have no pixel that changes by more than 16 codes.
The largest change is 0.52 % of a page, at the edge of the booklet and in the halo
of a finger.

The other local videos: the scans of 2026-10-14 and their 8 variants, the camera
scan of the book, the other phone videos of 2026-10-12, and the first 30 s of the
benchmark. Each one keeps its page count in two passes and in stream mode, and
no tint grows. The largest changes:

- A view of an invoice with a hand on the sheet: 6.6 % of the page changes. The
  paper around the hand is whiter, and the hand stays.
- The cover of a paperback: 3.6 % of the page changes. A printed grey gradient
  at the top of the cover is a little lighter (see "Limits").

## Limits

- **A thin band under a fold.** The paper colour of each cell is the mean of 3 x 3
  cells. At a sharp fold, the bright cells above the fold make the colour of the
  first cells below it too bright. The band of about one cell keeps a light tint.
- **A shadow deeper than 20 %, or a warm shadow with more red.** It stays: the
  rule cannot tell it from skin.
- **Light grey print that fades.** A grey area with a soft edge, at most 20 % below
  the paper, becomes white. A printed gradient can become lighter in part: the
  grey gradient at the top of a paperback cover is an example.
- **Shadows on a page that is not white paper.** That page has no flatten step
  (decision 0028), so the rule does not apply.
