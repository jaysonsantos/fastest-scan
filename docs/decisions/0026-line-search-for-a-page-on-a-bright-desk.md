# 0026: The detector finds a page on a bright desk by its four straight edges

Date: 2026-10-12. Status: accepted. This record adds a third rule to the paper
mask of decision 0004, after the outline search of decision 0024. The two older
rules stay the first and the second choice.

## Context

A test of the Android app with the camera, on 2026-10-12: a paperback lies open
on a white desk with a wood grain. Tools, a bottle, and a bag lie around the
book, and one of them touches it. The app drew the page outline around the desk.
With no page turn, the count of spreads went up to 8.

A recording of that scene with the camera of the phone (8 seconds, 1920 x 1440
pixels, 201 frames) repeats the fault on the desktop. The detector finds "pages"
in 198 frames, the timeline finds no spread, and the program ends with
`NoPagesFound`. The bright region of decision 0004 is the desk with the page on
it.

The outline search of decision 0024 fails there for three reasons:

- **The grain of the desk is walls.** Half of the pixels of a frame have a step
  of more than 3 codes, and the search takes each step above 3.5 codes for a
  wall. The flood from the frame border does not get to the book.
- **A thing touches the book.** The thing, and the part of the desk that the
  thing and the book enclose, stay with the book. The region is then not like a
  sheet of paper.
- **One part of the page outline is weak** in some frames. With stronger walls,
  the flood gets into the page there.

Numbers from the recording, at the size of the analysis: the grain of the desk
has steps of up to 5.6 codes (99 % of its pixels), and the edge of the page has
steps of 21 codes or more.

Three Python experiments on seven frames of the recording came before the Zig
code (`prototypes/detect/`):

1. **A second flood that goes through dark things.** It finds the book in four
   frames. In three frames it gets into the page through a spot of the outline
   that is not bright, and the dark line in the fold cuts the book in two.
2. **A second flood with stronger walls, and a cleaning step.** With a wall at 8
   codes, it finds the book in four frames, and the flood gets into the page in
   three. With a wall at 6 codes, it finds a region in all seven frames, but the
   region has a part of the desk above the book.
3. **Four straight lines** (`line_quads.py`). It finds the page in all seven
   frames. The Zig code is this experiment.

## Decision

### The lines of a frame

`lines.find` in the new file `src/lib/lines.zig` finds the straight lines of a
frame:

1. Each pixel has the strength of its step (the same number as in decision 0024)
   and the direction of its step. The direction comes from the three planes
   together: the direction in which they change most (Di Zenzo 1986).
2. Each pixel with a step of more than 3 codes votes for the lines through it
   that go across the direction of its step, within 2 degrees. This is the Hough
   transform (Duda and Hart 1972) with the direction of the gradient (O'Gorman
   and Clowes 1976). The direction of the step has the full vote, and the
   directions next to it have less.
3. The table of the votes has one row for each whole degree of the direction of
   the normal, and one column for each pixel of the distance from the middle of
   the frame.
4. The 24 lines with the most votes are the result. Two lines nearer than 5
   degrees and 6 pixels are one line.
5. Each line knows where along its length the frame has a step of 6 codes or
   more that fits its direction. So a gap in an edge does not hide the edge, but
   the gap can be measured: the support of a segment of the line is the part of
   its length with such steps.

### The page

`detect.lineRegion` takes two lines that go about one way and two lines that go
about across them, as Zhang and He (2007) do for a whiteboard. The quad between
the four lines is a page when:

- its four corners are inside the frame, and its area is 8 % of the frame or
  more;
- three of its sides have steps along 90 % of their length or more, and the last
  side along 70 % or more;
- 80 % of its inside is bright (the paper mask of decision 0004);
- the surface outside two of its sides or more has another colour than its
  inside (the mean chroma of the bright pixels differs by 3 codes or more), and
  the surface outside one side at most has the colour of its inside.

The result is the page with the largest product of its area and the support of
its four sides. The area alone is not enough: a quad with the edge of the desk
as one side is larger than the page, but two of its sides then go on past the
corners of the page, where they have no steps.

The two pages of an open book do not lie in one plane, so their upper edges are
two lines. A quad around the two pages has little support at its upper side
then, and one page alone is the best quad. So a second page joins the result
when it lies on the other side of one upright side of the first page, has an
area within a factor of 1.7, and has 70 % of that side in common.

The region of the result is the inside of the quad, or of the two quads. A hand
on the page does not change it.

### The order of the three rules

`analyzeScene`:

1. The bright region of decision 0004 is the first choice. When it does not touch
   the frame border, or its likeness to a sheet of paper is 0.5 or more, it
   stays.
2. Else the outline search of decision 0024 runs.
3. When the outline search gives no region that is more like a sheet of paper,
   the line search runs. The same limits of the likeness apply to its region.

### The rules for a page that did not work

On a dark desk, a page has lines inside it: the edges of a block of text, of a
picture, and of a black bar. In the benchmark video the hand of the user is on
the booklet in many frames, and the page then runs out of the frame. The first
form of the line search took such lines for the sides of a page: it changed the
result of 567 of 4984 frames. These rules against that were tried, and they are
not in the code:

- **The surface outside three sides is bright.** A block of text has bright
  paper around it too.
- **The surface outside a side is brighter or darker than the inside.** In a
  frame that is not sharp, a block of text is grey paper.
- **The colour rule alone.** Under the warm lamp of the benchmark, the two pages
  of one spread differ by 18 codes of chroma, which is more than paper and desk
  differ.
- **The part of the bright surface around the page that has steps.** 22 % for
  the desk, and 16 % to 57 % for the paper of the benchmark: no limit separates
  them.

The rule that works is the support of the sides. The sides of the page on the
desk have steps along 96 % to 99 % of their length, in all frames. Of the quads
in the benchmark that are no sheet, the best one had 82 % at its weakest side.

## Results

All runs on 2026-10-12, on the desktop.

| Video | Before | With the line search |
|---|---|---|
| The desk recording, two passes | No page: the program ends with `NoPagesFound` | 1 page of 511 x 768: the page of the book. The detector finds it in 201 of 201 frames. |
| The desk recording, stream mode | Not run | 1 page of 511 x 771, the same page |
| Benchmark, 3840 x 2160, dark desk | 63 pages | 63 pages, the same bytes of the PDF |
| Benchmark at 1920 x 1080 | 64 pages | 64 pages, the same bytes of the PDF |
| The phone video of the bright room (decision 0024), two passes and stream mode | 7 pages | 7 pages, the same bytes of the PDF in each mode |
| 8 videos of the PUCIT set, 480 x 270 | 18 to 75 pages | The same bytes of the PDF for each video |

- On the benchmark, 101 of 4984 frames get another page from the detector:
  frames with a hand on the booklet during a page turn. The spreads of the
  timeline and the PDF do not change.
- With no colour rule, one of the 8 PUCIT videos gets one page more, and 109
  frames of the benchmark change. So the colour rule stays.
- In stream mode, the desk recording takes 28.5 ms for each frame on the
  desktop: each frame runs the three rules.
- The app on the phone (a REDMI Note 15 Pro+ 5G, on its side, frames of 2880 x
  2160 pixels from the camera) shows the same scene: the outline is on the page
  of the book, and it turns green after the view is steady. After "Stop", the
  scan has 1 page, the page of the book. Before, the outline was around the
  desk, and the count of spreads went up with no page turn. The time for a
  frame on the phone was not measured.

The page counts of the PUCIT videos show a fault of decision 0024, not of this
decision: see "Limits".

## Limits

- **The whole page must be inside the frame.** A corner of the quad outside the
  frame ends the search.
- **The paper must have another colour than the surface.** Cream paper on a
  grey-white desk differs by more than 3 codes of chroma. White paper on a desk
  of the same white does not, and the search finds no page there.
- **A coloured or dark page is no page.** In the test scene, the left half of
  the open book is the flap of the cover, orange and pink. The result is the
  right page only.
- **A hand on two sides.** One side can be hidden along 30 % of its length. With
  more, or with two sides hidden in part, the frame has no page.
- **A page that curls.** The sides are straight lines, with a room of 2 pixels of
  the working image. A side with more bend loses its support.
- **An edge of another thing in line with an edge of the page.** Two lines nearer
  than 5 degrees and 6 pixels are one line, and the page edge can be lost.
- **A steady view on a dark desk with a line across the page.** In four frames
  of the benchmark (4753 to 4756), fingers lie on the lower edge of a spread
  that runs out of the frame at the top, and a black bar goes across the page.
  The line search takes the bar for the upper edge there. The PDF does not
  change, because another frame is the reference of that spread.
- **The PUCIT videos get too many pages since decision 0024.** For the first
  eight videos at their size of 480 x 270: 75, 45, 42, 55, 49, 18, 32, and 57
  pages, where `main` gives 7, 4, 15, 4, 28, 9, 26, and 52. A video has about 20
  page views. In those videos the book is larger than the frame, and the outline
  search takes parts of a page for the page. Decision 0024 has the counts for
  four videos that were made four times larger; the counts at the true size are
  worse. The rule that the outline search uses to accept a region is too loose
  for that case.
- The numbers of the rule come from one desk recording and from the benchmark.

## Consequences

- The app can scan a book with pages of the colour of cream on a white desk with
  a texture and with things around the book.
- `detect.Options` has `line_search` to turn the search off.
- `src/lib/lines.zig` is a new file of the library. It has no dependency but
  `geometry.zig`.
- The outline search and the line search use one field of steps
  (`detect.StepField`), which `analyzeScene` makes one time for a frame.
- The plan item "Hough or line-segment detector" of `docs/status.md` is done in a
  first form. What is left of it: the quad of the frame before as a prior, and a
  page that runs out of the frame. `docs/research/page-detection.md` has a score
  for a quad from the literature (Tropin et al.) that takes away the edges on
  the two ends of a side past the corners: it was not tried.
- The next step for the detector is a stricter rule for the outline search of
  decision 0024, with the PUCIT videos as the test.
