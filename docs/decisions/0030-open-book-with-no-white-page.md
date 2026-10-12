# 0030: An open book with no page of white paper

Date: 2026-10-12. Status: accepted. This record changes one limit of decision
0028: "Only next to a page of white paper."

## Context

The camera scan of decision 0029 ends with two spreads that have no page of
white paper: a dark grey page on the left, and an orange page with a small
white note on the right. The detector took the desk for the page in each frame
of those views (122 of 122 frames of the last view), and the result had no page
of the two spreads.

The line search starts with a page of bright paper (decision 0026), and a page
that is not white paper can only be the second page next to it (decision 0028).

The same scan starts with the closed book: an orange cover. The book lies on a
green cutting mat, and a picture frame, a cup, and a glass stand on the mat.

## Decision

When the line search finds no page of bright paper, it looks for an open book
with two pages that are not white paper (`detect.LineSearch.coloredSpread`):

1. The 8 quads with the highest score that are not bright and pass the rules of
   a coloured page (decision 0028) are the candidates for the first page.
2. For each candidate, the best one first, the search looks for a second
   coloured page across a fold, with the rules of decision 0026 for its place.
3. The areas of the two pages agree within a factor of 1.2
   (`max_colored_area_ratio`). For a page next to white paper the factor stays
   1.7.

The result is the first pair. `detect.Scene.colored_pages` has the two quads.
The render gives such a spread the colours of the camera: no page of the spread
shows the light (decision 0028).

### One quad is not a page

One quad with a colour is not enough for a page. On the desk of the scan, the
mat, the picture frame, and the book are such quads, and nothing in one frame
says which of them is a document. So a closed book with a coloured cover gives
no page, as before.

### Why the two pages must have one size

A first form took the pair with a factor of 1.7. In the first 87 frames of the
scan it found a "book" with the mat as its left page and the cover as its right
page: the two are quads with a side in common, and each has another surface
around it. The result had a page of the mat. Numbers from the scan, for the
best pair of each frame:

| Pair | Frames | Area of one quad divided by the other | Part of the fold in common |
|---|---|---|---|
| The mat and the cover | 90 | 0.62 to 0.80 | 0.77 to 0.99 |
| A dark page and an orange page | 202 | 0.93 to 1.03 | 0.92 to 1.00 |

The fold in common does not separate the two. The size does: the two pages of a
book have one size.

A rule that wants another colour outside each of the three outer sides of a
page did not work. A dark grey page on a white desk has no other colour outside
(the two are grey), so the real spreads failed, and the mat passed: the desk is
around it.

## Results

All runs on 2026-10-12, on the desktop.

| Video | Before | With this decision |
|---|---|---|
| The camera scan, stream mode | 6 pages | 10 pages: the six, and the two spreads with no white page |
| The camera scan, two passes | 7 pages | 11 pages: the same ten, and the second copy of the title page (decision 0029) |
| The last view of the camera scan | The desk in 122 of 122 frames | The two pages in 122 of 122 frames |
| The scan of the closed book (162 s) | No page | No page |
| The desk recording, the benchmark, its copy at 1920 x 1080, the bright room, the first 8 PUCIT videos | | The same bytes of the PDF for each, in each mode |

## Limits

- **A closed book with a coloured cover gives no page.** See "One quad is not a
  page".
- **A hand on such a spread is not seen** (decision 0028). In the camera scan,
  one orange page shows the fingers of the user at its lower edge.
- **The colours are those of the camera.** No white page gives the light. The
  orange pages of the scan are more red than the paper.
- **Two pages with much perspective.** When the camera looks at the book from
  a side, the two quads differ by more than a factor of 1.2, and the search
  finds no book.
- **A dark grey page next to a second dark grey page on a white desk.** The
  rule for a coloured page compares the chroma only, and it wants another
  colour outside three sides. The spreads of the scan pass because one page is
  orange.
- The numbers (8 candidates, the factor 1.2) come from one camera scan.

## Consequences

- A book with coloured pages on a bright desk is scanned to its end, when a
  spread has a fold between two pages of one size.
- The search for such a pair runs only in a frame with no page of bright paper:
  a frame with white paper costs no more time.
- What is left: the cover of a closed book. A way to tell a document from
  another quad is necessary for it: text in the quad, or a quad that the user
  points at.
