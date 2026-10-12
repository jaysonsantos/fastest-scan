# 0029: A line of the line search is the edge that it came from

Date: 2026-10-12. Status: accepted. This record changes how `lines.find` of
decision 0026 gives its lines. The rules for a page of decisions 0026 and 0028
stay.

## Context

A scan with the camera of the phone, on 2026-10-12: a paperback on a white
desk, with a build of decision 0028. The app kept a video of the scan (1600 x
1200 pixels, 34 seconds, 1022 frames). The result was correct, but the outline
on the screen jumped between the page and the desk, and the user did not know
when a view was steady.

In each steady view, the detector took the desk for the page in most frames:

| View | Frames | Frames with the desk | Longest run of frames with the page |
|---|---|---|---|
| The flap and the title page | 143 to 254 | 95 of 112 | 4 |
| A dark page and the second title page | 299 to 424 | 64 of 126 | 36 |
| A dark page and the note of the publisher | 487 to 638 | 90 of 152 | 19 |

The Android session measured the mean luma of the frames: it changes by 0.2
codes between a frame with the page and a frame with the desk. So the light is
not the cause: one rule is at its limit.

The rule is the support of the sides of a page (decision 0026): three sides
with steps along 90 % of their length, and the last side along 70 %. A print of
the support for each frame shows:

- The edges of the page are strong in each frame. With the correct line, each
  side has steps along 97 % to 99 % of its length, also for a limit of 2 codes
  in place of 6.
- In a frame with the desk, the line for one side is not on its edge. It leaves
  the edge by 2 to 4 degrees, and the side then has support along 45 % to 70 %
  of its length. The lower corner of the page is at (248, 218) with the correct
  line and at (247, 224) with the wrong one, in pixels of the working image.

Two facts make the line wrong:

- **The table of the votes is coarse.** It has whole degrees and whole pixels.
  The votes of a short edge make a flat hill, and the top of the hill moves by
  some degrees from one frame to the next.
- **Two edges that meet at a small angle make one hill.** Below the lower edge
  of the page lies a second edge, which leaves it at 3 degrees. Two lines
  nearer than 5 degrees and 6 pixels are one line, so only one of the two is in
  the result. The votes say how strong the steps of an edge are, not how long
  it is, and the top of the hill changes between the two.

## Decision

`lines.refined` makes each line of the result the edge that it came from, in
three steps (`Options.refine`):

1. **The run.** It takes the steps within 6 pixels of the line that give the
   line support: a strength above 6 codes, and a direction within 20 degrees of
   the normal. Of those it keeps the run along the line with the most steps. A
   run ends at 12 places in a row with no step, so a second thing in line with
   the edge, farther away, is not a part of it.
2. **The longest candidate.** The candidates are the lines within 4 degrees of
   the line, each half degree, and within 6 pixels, each pixel. They turn
   around the middle of the steps of the run. The result is the candidate with
   steps along the most places: a place counts when a step lies on the
   candidate or one pixel to a side. Of two candidates with the same count, the
   one nearer to the line of the table wins.
3. **The fit.** Two times, the candidate is fitted to the steps of the run
   within 2 pixels of it: the least squares of the distances across the line,
   with the strength of a step as its weight (at most 20).

`lines.Line` has the direction of its normal as an angle (`radians`). The
whole degree (`degrees`) stays for a comparison of two directions.

A first form had only step 3, with all steps near the line. It repaired most
frames of the first view and few frames of the two other views: the fit of a
line between two edges stays between them.

A second form counted the places along the whole line, with no run. In the
synthetic frame of a test, a candidate then took the edge of a thing farther
away along the line, and the corner of the page moved by 8 pixels.

## Results

All runs on 2026-10-12, on the desktop. The same three views:

| View | Frames with the desk, before | After | Longest run with the page, before | After |
|---|---|---|---|---|
| The flap and the title page | 95 of 112 | 11 of 112 | 4 | 101 |
| A dark page and the second title page | 64 of 126 | 17 of 126 | 36 | 109 |
| A dark page and the note of the publisher | 90 of 152 | 52 of 152 | 19 | 98 |

In the frames that stay, the hand of the user is on the book: it moves the
book into its place, or it lies on the lower edge of the page before a turn.

| Video | Before | After |
|---|---|---|
| The camera scan, stream mode | 6 pages | 6 pages, the same six |
| The camera scan, two passes | 6 pages | 7 pages: the six, and a second copy of the title page. See "Limits". |
| The desk recording (decision 0026), two passes and stream mode | 2 pages | 2 pages, other bytes: the corners of the pages move by some pixels |
| Benchmark, 3840 x 2160, and its copy at 1920 x 1080 | 63 and 64 pages | The same bytes of the PDF for each |
| The bright room (decision 0024), two passes and stream mode | 7 pages | The same bytes of the PDF in each mode |
| The first 8 PUCIT videos | 7 to 55 pages | Six videos keep their bytes. The third gives 23 pages, before 26, and the fifth 50, before 52: the results of a run with no line search. |

- The analysis of the camera scan takes 3.4 s, before 3.15 s, and that of the
  desk recording 3.8 s, before 3.4 s: the line search runs on each frame there.

## Limits

- **A hand on a side of the page.** A side can be hidden along 30 % of its
  length (decision 0026). With the hand on the lower edge before a page turn,
  the page is lost, as before.
- **The copy of the title page in two passes.** The first view of the camera
  scan shows the title page alone, while the hand moves the book. The duplicate
  search compares it with the title page of the next view and finds 46 % of the
  textured parts again, where it wants 50 %. Before this decision it found
  52 %. The page has three lines of large letters and no other texture.
- **An edge with a gap of more than 12 places.** The run ends at the gap, and
  the line comes from the larger part of the edge only.
- **A spread with no page of white paper** is not found. This is a limit of
  decision 0028, and this decision does not change it: in the same scan, a dark
  page next to an orange page gives no page.
- The numbers of the rule (4 degrees, 6 pixels, 12 places, 2 fits) come from one
  camera scan, the desk recording, and the synthetic frames of the tests.

## Consequences

- In a steady view of a book on a bright desk, the detector gives the page in
  nearly each frame. The outline of the app does not jump, and the timeline has
  long views.
- The corners of a page of the line search are more exact: a line has its own
  direction, not that of a cell of the table.
- `lines.Options` has `refine`, `near_degrees`, `near_distance`, `run_gap`,
  `fit_rounds`, and `min_fit_steps`.
- A frame with the line search costs about 10 % more time.
- A rule in the stream session that holds the last outline for a frame with no
  page was tested in the Android session, and it is not in the code: it changed
  which views the timeline takes, and gave more pages. With the long runs of
  this decision, such a rule has less to do.
