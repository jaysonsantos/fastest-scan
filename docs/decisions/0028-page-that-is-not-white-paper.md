# 0028: A page that is not white paper is a page too

Date: 2026-10-12. Status: accepted. This record changes one limit of decision
0026: "A coloured or dark page is no page."

## Context

In the desk recording of decision 0026, a paperback lies open on a white desk.
The right half is a page of cream paper. The left half is the flap of the
cover: an orange part with text, and a pink part. The result had the right page
only, and the user wants the left half as a page too.

Four parts of the program take white paper as given:

- **The line search** (`detect.LineSearch.page`) wants 80 % of the inside of a
  quad bright, and it compares the colour of the bright pixels on the two sides
  of each edge.
- **The observation** (`observe.observePage`) takes each cell with a low paper
  score for a covered cell when it connects to the border of the page. A
  coloured page has no cell with the score of paper, so all of it is covered,
  and the timeline drops each frame.
- **The flattening** (`enhance.flatten`) divides each cell by the colour of its
  brightest pixels, for each colour channel. That makes an orange page white.
- **The fusion and the finger rule** compare cells with white paper, and orange
  and pink are near the colours of skin.

## Decision

A page has a flag: it is white paper, or it is not ("coloured"). The flag goes
from the detector to the render.

### The detector

- `LineSearch.page` takes the kind of the inside: `paper` or `colored`. A quad
  with 80 % of its inside bright is paper, and the rules of decision 0026
  decide. A quad that is not bright can be a coloured page when the surface
  outside 3 of its 4 sides or more has another colour than its inside. This
  check compares all pixels, not only the bright ones.
- Only the second page of an open book can be coloured. The first page is paper
  (decision 0026). The second page has the same rules for its place and its
  size as before: across the fold, an area within a factor of 1.7, and 70 % of
  the fold in common. Paper wins when the two kinds are possible.
- `detect.Scene.colored_page` has the quad of that page, and
  `detect.Layout.colored` says for each page of a spread if its middle is in
  that quad. A layout of one page has no coloured page.

### The observation

`observe.PageObservation.colored` has the flag. The covered cells of a coloured
page are only the cells outside the frame.

### The render

- `render.SourceFrame.colored` gives the flags of the analysis pass to the
  render. When the detector at the full size finds other flags, the layout of
  the analysis pass stays, as for another number of pages.
- A coloured page is not flattened. `enhance.paperColor` gives the mean colour
  of the paper of the white page of the same spread, in the same frame: that is
  the colour of the light. `enhance.balance` divides the coloured page by it:
  one factor for the whole page, so the page keeps its colours. With no white
  page in the spread, the page keeps the colours of the camera.
- A coloured page comes from its reference frame alone: no donor frame, no
  fusion, no finger rule. The sharpening and the levels stay.
- The signature of a spread for the duplicate search has the same steps.

The stream session (`stream.zig`) and the CLI carry the flag with the page
corners of a frame. With `--verbose`, the CLI prints the number of such pages.

## Results

All runs on 2026-10-12, on the desktop.

| Video | Before | With this decision |
|---|---|---|
| The desk recording, two passes | 1 page of 506 x 768 | 2 pages of 504 x 786: the flap with its colours and its text, and the page of paper |
| The desk recording, stream mode | 1 page of 511 x 771 | 2 pages of 511 x 788, the same two pages |
| Benchmark, 3840 x 2160 | 63 pages | 63 pages, the same bytes of the PDF. Each of the 4984 frames has the same observation. |
| Benchmark at 1920 x 1080 | 64 pages | 64 pages, the same bytes of the PDF |
| The bright room (decision 0024), two passes and stream mode | 7 pages | 7 pages, the same bytes of the PDF in each mode |
| The first 8 PUCIT videos | 7 to 55 pages (decision 0027) | The same bytes of the PDF for each video |

- The detector finds the two pages in 201 of the 201 frames of the desk
  recording.
- The analysis of the desk recording takes 3.4 s, before 3.1 s: the search for
  a second page runs two times.

## Limits

- **Only next to a page of white paper, and only with the line search.** The
  line search runs when the bright region and the outline search find no sheet:
  a bright desk. On a dark desk, the bright region is the white page alone, as
  before, and the coloured page is not in the result.
- **A hand on a coloured page is not seen.** The timeline can take a frame with
  a hand on that page for the reference, and the page then shows the hand.
- **No repair.** Glare on a coloured page stays, because no other frame gives
  its cells.
- **A shadow on a coloured page stays.** The page gets one factor for all its
  pixels.
- **The colours are those next to the paper.** The paper of the white page
  becomes white, and the coloured page gets the same factors. Cream paper thus
  makes the coloured page a little more blue than the camera shows it.
- **A dark page on a dark surface**, and a coloured page on a surface of its
  own colour, are not found: three sides of the page need another colour
  outside.
- **The edge of the cover.** In the desk recording the lower edge of the left
  page is the edge of the cover below the flap: a thin strip of the cover is at
  the bottom of the page.
- The rule comes from one recording.

## Consequences

- An open book with a coloured page or a flap next to a page of paper gives two
  pages, on the desktop and in the stream session that the Android app uses.
- `detect.Layout`, `observe.PageObservation`, `render.SourceFrame`, and
  `render.PageImage` have the field `colored`. Each has a default of false, so
  a caller that does not know the flag gets the behaviour of before.
- The C interface does not change.
- What is left for such a page: covered cells from the colour of the page
  itself, and then donor frames for it.
