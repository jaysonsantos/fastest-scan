# 0018: The skin test accepts dark hands and skin in a shadow

Date: 2026-10-12. Status: accepted. This record changes the skin test of decision
0014. The other parts of the finger rule stay.

## Context

The skin test of decision 0014 got its numbers from one video, with one hand and
one lamp. Its limits were fixed values: red 0.08 or more above green, and a mean
luma of 0.25 or more. Decision 0014 named that as a risk.

No second video of the user exists. So the check used the page-turn videos of
Tariq Dar and Khan 2017 (the PUCIT set, see `docs/references.md`): 37 videos of
books, with the hands of other persons, in daylight and in the light of a room.
The videos are small, 480 x 270 pixels.

### What the hands of other videos show

`prototypes/fingers/skin_samples.py` finds blobs with a red tint on the layer
pictures (`--debug-layers`), with a rule much wider than the skin test. A person
then checks that the blobs are hands. The numbers below are from 77 000 cells of
the benchmark video and 24 000 cells of six PUCIT videos of two days.

| | Benchmark | PUCIT, 2015-09-03 | PUCIT, 2015-11-02 |
|---|---|---|---|
| Luma of a hand cell, median | 0.59 | 0.46 | 0.43 |
| Red minus green, median | 0.18 | 0.17 | 0.15 |
| Red minus green as a fraction of red, median | 0.26 | 0.31 | 0.31 |
| Cells of the hands that the test of decision 0014 accepts | 64 % | 65 % | 58 % |
| The same, for the cells with a luma below 0.35 | 22 % | 57 % | 50 % |

The fraction of red is the same in all the videos, and at each luma:

| Luma of the cell | Red minus green, median | Fraction of red, median |
|---|---|---|
| 0.15 to 0.25 | 0.06 to 0.10 | 0.26 to 0.35 |
| 0.25 to 0.35 | 0.15 to 0.17 | 0.36 |
| 0.35 to 0.50 | 0.20 | 0.33 to 0.34 |
| 0.50 to 0.70 | 0.20 to 0.23 | 0.28 to 0.29 |

A shadow and a dark skin tone lower red and green by one factor. The difference
falls with them, and the fraction stays. This agrees with Yang, Lu, and Waibel
1998: the colours of the skin of different persons lie close together when the
intensity is taken out.

So the fixed difference of 0.08 lost the dark cells of a hand, and the luma limit
of 0.25 lost them a second time. On the PUCIT pages, the result was a hand with
white patches on its bright parts and dark fragments between them.

### Why the luma limit was there

A black header bar with glare on it is as dark as dark skin, and it has as much
red: at the end of one bar of the benchmark, the fraction of red is 0.24 to 0.34.
A first try with no test of the hue took the ends of two header bars for fingers
and painted them white. A third bar lost its repair.

The hue is different. The glare has the gold tint of the lamp:

| | Green minus blue as a fraction of red minus green |
|---|---|
| Dark cells of the PUCIT hands (10 %, 50 %, 90 % of the cells) | 0.32, 0.49, 0.72 |
| The end of a header bar with glare, two frames | 0.74 to 1.35 |

## Decision

All values are on the scale of a flattened page: blank paper is 1.0.

- **Red.** A cell needs red minus green of at least 0.12 of its red. The value
  is at most 0.08 (a bright cell: the rule of decision 0014) and at least 0.04
  (below that, the tint of a dark cell is noise of the video compression).
- **Luma.** The lower limit is 0.15, before 0.25.
- **Hue of a dark cell.** A cell with a luma below 0.25 must be more red than
  yellow: green minus blue is at most 0.75 of red minus green. A brighter cell
  keeps the test of decision 0014 (green minus blue at most red minus green plus
  0.05): the lamp of the benchmark makes lit skin more yellow than that.

For a cell with red of 0.67 or more and a luma of 0.25 or more, the test is the
test of decision 0014.

## Measurements

### The benchmark video

| | Decision 0014 | This decision |
|---|---|---|
| Pages | 63 | 63 |
| Pages with a finger that stays | 0 | 0 |
| Mean page area painted | 3.34 % | 3.37 % |
| OCR sample: words, good words, mean confidence | 1401, 1035, 80.2 | 1401, 1035, 80.2 |

9 of the 63 pages changed, each in less than 1 % of its pixels, at a corner or an
edge of the page:

- On 7 pages, a part of a dark brown area at a corner is gone: the wood of the
  desk. On one of them (`p_017_0` in the debug pictures), the paint also took
  two cells from the left end of a header bar, because the wood is next to the
  bar.
- On 2 pages, a few cells changed at the shadow of the page edge.

No header bar lost a repair.

### The PUCIT videos

The cells of the hands that the skin test accepts:

| | Decision 0014 | This decision |
|---|---|---|
| PUCIT, 2015-09-03: all hand cells | 65 % | 75 % |
| PUCIT, 2015-09-03: cells with a luma below 0.35 | 57 % | 87 % |
| PUCIT, 2015-11-02: all hand cells | 58 % | 70 % |
| PUCIT, 2015-11-02: cells with a luma below 0.35 | 50 % | 85 % |

On the pictures of the script, the cells that stay out are at the edge of a hand,
where a cell has skin and paper, and in the blur of a hand that moves. The margin
of the mask covers them.

The result pages that keep an area with the colour of skin at the page border (a
blob of 12 cells or more, with red minus green of 0.15 of red or more):

| | Pages | Decision 0014 | This decision |
|---|---|---|---|
| Ten videos as they are (pages of about 350 pixels in width) | 434 | 207 | 166 |
| Four videos, enlarged four times (pages of about 1070 pixels) | 105 | 13 | 6 |

The enlarged videos give a finger the width in pixels that it has in a phone
video. Their fault maps show that the mask now covers a hand as one area. Before,
it covered the bright parts only, and the dark parts stayed as fragments.

- 4 of the 6 pages that keep skin have a whole hand or an arm on the page. Such
  a mask is larger than 15 % of the page, and the limit of decision 0014 keeps
  it. Before, the mask found a part of such a hand, the part was below the limit,
  and the hand got white patches.
- The small videos keep more fingers: see "Consequences".

## Consequences

- The numbers now come from three sets of hands. They are still few: the PUCIT
  hands are of one region of the world, and no video has a very pale or a very
  dark skin tone. Check a new video with `--debug-dir` and look at `faults/`.
- Dark red-brown wood at a page corner is a finger for the test, more often than
  before. Where it is next to print, the paint can take a cell of the print.
- **The sizes of the finger rule are in cells of 8 pixels.** They fit a page of
  about 640 pixels or more in width (a 1080p video): the copy of the benchmark at
  1920 x 1080 keeps no finger (64 pages of 642 x 926 pixels). On the PUCIT videos
  as they are (pages of 350 pixels) a finger is 3 to 4 cells wide, less than the
  5 cells that a wide blob needs, so thin fingers stay. Scale the sizes with the
  page width when small videos become a goal.
- A whole hand on a page stays in the result. That is correct: the hand hides
  much of the page, and a white area in its place does not show that.
- The PUCIT videos showed two more things, which this record does not change.
  The page count is wrong on most of them (a bright desk, a book in a second
  direction). And the copy of the benchmark at 1920 x 1080 gives 64 pages, one
  duplicate more than at the full size.

## How to repeat the check

```sh
# The data set (112 MB). The videos stay out of the repository.
mkdir -p .cache/pucit && cd .cache/pucit
curl -L -O http://faculty.pucit.edu.pk/nazarkhan/datasets/pucit_page_turns.zip
unzip pucit_page_turns.zip && cd ../..

# One video with the layer pictures, and the colours of its hands.
zig-out/bin/fastest-scan .cache/pucit/VIDEOS-SMALL/20151102_110945.mp4 \
  -o out/pucit.pdf --debug-dir out/pucit-debug --debug-layers
python3 prototypes/fingers/skin_samples.py out/pucit-debug/layers/p_*_00.jpg \
  --out out/pucit-skin
```

## Ideas from other work

- Skin colours of different persons lie close together when the intensity is
  taken out: Yang, Lu, and Waibel 1998, see `docs/references.md`. The test here
  divides the difference of two colours by one colour; it has no colour model.
- The videos: Tariq Dar and Khan 2017, see `docs/references.md`.
