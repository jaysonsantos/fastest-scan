# 0024: The detector finds a book on a bright surface by its outline

Date: 2026-10-12. Status: accepted. This record adds a second rule to the paper
mask of decision 0004. The rule of decision 0004 stays the first choice.

## Context

The page detector of decision 0004 takes one threshold on a paper score (bright,
with the colour of the scene white) and then the largest bright region. That
works on a dark desk.

A video of 2026-10-12 from a phone shows a paperback on a light grey floor, next
to a white wall, at 1920 x 1080 pixels. There the largest bright region is the
wall and the floor. The result had 18 pages, and none was a page of the book: the
wall was the "page" of the cover, and the wall and the floor were the two "pages"
of each spread. The stream session and the Android app gave the same result.

Numbers from that video, as 8-bit codes at the size of the analysis:

| Surface | Luma | U | V |
|---|---|---|---|
| The wall | 173 | 123 | 133 |
| The floor near the book | 162 | 124 | 131 |
| The page in the light | 175 | 118 | 135 |
| The page in a shadow | 143 | 114 | 140 |

- The page in the light is 13 codes brighter than the floor. The page in a
  shadow is 19 codes darker than the floor. So no threshold of the brightness
  separates the page from the floor.
- The colour is different: the paper is cream and the floor is grey. The
  difference is small: 6 to 10 codes of U and 4 to 9 codes of V.
- The book has an outline that a person sees with no effort: a step of
  brightness or colour, and a thin shadow line.

Two Python experiments came before the Zig code (`prototypes/detect/`):

1. **Regions above several thresholds** (`region_search.py`). For each of 16
   thresholds, each bright region gets a number that says how much it is like a
   sheet of paper. This finds the cover. For a spread it finds only the part of
   the page in the light, or a brighter blob of the wall. It does not work.
2. **A flood from the frame border** (`edge_flood.py`). This finds the whole book
   in all ten test frames of the video. The Zig code is this experiment.

## Decision

### The outline search

`detect.outlineRegion` finds the paper of a book that lies inside the frame:

1. The strength of the step at each pixel: the length of the Sobel gradient of
   the luma after a 3x3 blur, plus three times that of each chroma plane. A pixel
   with more than 3.5 codes for one pixel is a wall. A dilation by one pixel makes
   the walls thicker, which closes small gaps of an outline.
2. A flood runs from the frame border over all pixels that are no wall
   (`raster.floodFromBorder`). It moves across the four sides of a pixel, not
   across its corners.
3. What the flood does not reach is the walls and all that they enclose: the
   book with its text, and thin lines such as the edge of the wall, a joint of
   the floor, and the outline of a hand.
4. An opening with a half width of 4 pixels removes the thin lines. The largest
   region that stays holds the paper.
5. An erosion by 2 pixels puts the outline of the region into the middle of its
   walls. Then only the pixels of the bright mask of decision 0004 stay: a hand
   on the book is inside the outline of the book, and it is not bright.

The search works on planes of at most 512 pixels in width. For a larger frame it
makes the planes smaller first, and the outline of its region then has steps:
`Scene.outline_step` says how large, and the edge lines get that much more room
for their points.

### Which region is the paper

`detect.paperLikeness` gives a region a number from 0 to 1, the product of three
parts:

- the region fills its convex hull (a hand on the paper takes a bite out of it);
- the hull fills the smallest rectangle around it;
- the outline of the region does not lie on the frame border: with one third of
  the outline on the border, the number is 0.

The rule of `analyzeScene`:

1. The bright region of decision 0004 is the first choice.
2. When it does not touch the frame border, or its likeness is 0.5 or more, it
   stays. No other step runs: a frame of a dark desk costs no more time than
   before.
3. Else the outline search runs. Its region takes the place when its likeness is
   0.35 or more and at least 0.15 above the likeness of the bright region.

The idea to take, among several shapes of a frame, the shape most like a sheet of
paper is from the method of E. Carlinet and T. Géraud in the SmartDoc 2015
competition (Burie et al. 2015). They take their shapes from the tree of shapes
and need more than a minute for a frame (`docs/research/page-detection.md`). The
shapes here are only two: the bright region, and the region inside the outline.

## Results

All runs on 2026-10-12, on the desktop.

| Video | Before | With the outline search |
|---|---|---|
| Benchmark, 3840 x 2160, dark desk | 63 pages | 63 pages, the same bytes of the PDF |
| Benchmark at 1920 x 1080 | 64 pages | 64 pages, the same bytes of the PDF |
| The phone video of 2026-10-12, two passes | 18 pages of 847 x 1078, none a page of the book | 7 pages of 369 x 577: the cover, and three spreads of the book |
| The same video, stream mode | 18 pages, none a page of the book | 7 pages of 438 x 603, the same pages |

- On the benchmark, 145 of 4984 frames get another observation: frames in which
  the paper runs out of the frame during a page turn. The spreads of the
  timeline and the PDF do not change.
- The analysis of the phone video takes 4.3 s, before 3.1 s: there the search
  runs on each frame.
- The phone video has more spreads than the result: see "Limits".

Four public videos with a bright desk (Tariq Dar and Khan 2017, enlarged four
times) give other page counts than before: 37, 25, 24, and 50 pages, before 16,
20, 17, and 52. Their ground truth has 20, 22, 15, and 21 page views. In those
videos the book is larger than the frame, which is not the case that this
decision is for. The counts were wrong before and they are wrong now.

## Limits

- **A page that runs out of the frame on a bright surface.** The flood enters
  the page from the border. The bright region then stays, and it is wrong, as
  before. The user must keep the whole book in the frame.
- **An outline with a gap.** When a part of the outline of the book has no step
  of brightness and no step of colour, wider than two pixels of the working
  image, the flood enters the book.
- **A hand on the page.** The region has a bite where the hand is. The edge
  lines still find the page when most of each edge is free. A hand that covers
  most of an edge moves that edge.
- **The phone video has more spreads than the 7 pages show.** The user turns the
  pages fast and keeps the hands on the book. The timeline finds 6 views in 49
  seconds, and 2 of them are the cover. This is a limit of the timeline rules
  (the shortest view, the largest covered part), not of the detector.
- **Small pages.** In that video a page is about 370 pixels wide. The detector
  finds it; the text is small.
- The numbers of the rule (3.5 codes, the gain of 3 for chroma, the half width
  of 4 pixels, the limits of the likeness) come from one video of a bright room
  and from the benchmark.

## Consequences

- The app can scan a book on a bright table or floor, when the whole book is in
  the frame. The rule of decision 0004 is no more the only case.
- `detect.Options` has `outline_search` to turn the search off, and the numbers
  of the rule.
- A frame in which the bright region lies on the frame border costs more time:
  about 40 % more for the analysis of such a frame.
- The next step for the worst cases stays the detector with line segments and
  the quad of the frame before (`docs/status.md`, plan item 6). It can also
  find a page that runs out of the frame.
