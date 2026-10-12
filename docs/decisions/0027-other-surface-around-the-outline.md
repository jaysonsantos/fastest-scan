# 0027: The outline search wants another surface around its region

Date: 2026-10-12. Status: accepted. This record adds one rule to the outline
search of decision 0024. The order of the three rules of decision 0026 stays.

## Context

The outline search of decision 0024 takes the largest region that a flood from
the frame border does not reach. It was made for a book that lies inside the
frame, on a surface as bright as its pages.

On the PUCIT videos (Tariq Dar and Khan 2017, 480 x 270 pixels) the search gave
too many pages: 75, 45, 42, 55, 49, 18, 32, and 57 pages for the first eight
videos, where a video has 9 to 30 page views. A look at the frames shows two
cases:

- **The whole book is inside the frame**, on a desk that is a little darker than
  the paper. The search finds the book, or one page of it. That is correct.
- **The flood is inside a page.** The page runs out of the frame, or the outline
  of the book has a gap. Then a block of text is all that the flood leaves: text
  that is not sharp is a mass of steps. The search takes the block for the
  paper, and the block changes from frame to frame. That is the fault.

The rule that accepts a region (decision 0024) does not see the difference: a
block of text is a solid rectangle inside the frame, so it is much like a sheet
of paper.

## Measures that do not separate the two cases

Each measure was computed for all regions that the search accepted, in the
eight PUCIT videos and in the phone video of the bright room (decision 0024),
where each region is the book.

| Measure | Bright room | PUCIT videos |
|---|---|---|
| The likeness to a sheet of paper (the median) | 0.47 | 0.57 to 0.80 |
| The part of the region with no step: free paper (the median) | 0.35 | 0.05 to 0.36 |
| The part of a band inside the outline with no step (the median) | 0.05 | 0.04 to 0.16 |

A fourth measure compared the bright pixels in a ring around the region with
the bright pixels inside it. It fails for two reasons. The text around a block
of text is not bright, so a quarter to a half of the ring has no data. And a
block of text that is not sharp is grey: it is darker than the margin around it
by up to about 20 codes, as a sheet is brighter or darker than a desk.

## Decision

`detect.otherSurfacePart` gives the part of the outline of a region that has
another surface outside. The outline search accepts a region only when that
part is 0.6 or more (`Options.min_other_surface`).

1. The function compares flat places only: pixels with no step. Inside the
   region they are free paper, such as a margin or the space between two
   paragraphs. Outside they are the pixels that the flood reached, at most 4
   pixels from the region. Text is not flat, so it is not a part of the two
   means.
2. The outline is cut into 16 directions from the middle of the region. Each
   direction has its own two means, because the light changes across a page. A
   direction with fewer than 4 flat pixels on one side is not a sign of another
   surface.
3. A direction has another surface outside when the mean chroma differs by 3
   codes or more (U and V together), or when the outside is darker than the
   inside by 12 codes of luma or more.
4. A surface outside that is brighter than the inside, with the same colour, is
   not a sign of another surface. A block of text that is not sharp, and a box
   with a tint, are darker than the paper around them. So this case is paper
   around a part of a page.

The sizes are in pixels of the working image of the search.

## Measurements

The part of the accepted regions that the new rule keeps, from the experiment
(the middle of a region was its centre of area there; the code takes the middle
of the box around it):

| Video | Regions | Kept |
|---|---|---|
| The bright room, each region is the book | 1215 | 100 % |
| PUCIT, the book is larger than the frame (3 videos) | 6154 | 0 % to 1 % |
| PUCIT, the whole book is inside the frame (5 videos) | 13222 | 6 % to 93 % |

With a limit of 0.7 the bright room keeps 97 %, and with 0.5 the three videos
with a large book keep up to 3 %.

## Results

All runs on 2026-10-12, on the desktop.

| Video | Before | With the rule |
|---|---|---|
| Benchmark, 3840 x 2160 | 63 pages | 63 pages, the same bytes of the PDF. 22 of 4984 frames get another observation. |
| Benchmark at 1920 x 1080 | 64 pages | 64 pages, the same bytes of the PDF |
| The desk recording (decision 0026), two passes and stream mode | 1 page | 1 page, the same bytes of the PDF in each mode |
| The bright room (decision 0024), stream mode | 7 pages | 7 pages, the same bytes of the PDF |
| The bright room, two passes | 7 pages | 7 pages: the cover and three spreads, as before. Other bytes: 11 of 1469 frames get another observation. |

The page counts of the first eight PUCIT videos:

| | Pages |
|---|---|
| Before | 75, 45, 42, 55, 49, 18, 32, 57 |
| With the rule | 7, 12, 26, 37, 52, 13, 32, 55 |
| With no outline search (the bright region alone) | 7, 7, 20, 5, 32, 11, 32, 56 |
| Page views in the video | 17, 22, 17, 18, 30, 11, 9, 17 |

All 37 PUCIT videos together show 763 page views:

| | Pages, 37 videos | Videos with a count within 25 % of the views | Videos with the count of the bright region alone |
|---|---|---|---|
| Before | 1744 | 1 | 1 |
| With the rule | 1669 | 9 | 22 |
| With no outline search (the bright region alone) | 1585 | 11 | 37 |

The count is more than two times the number of views in each row: the fault of
decision 0024 was only a part of what is wrong on these videos.

- In the three videos with a book larger than the frame (the first, the
  seventh, and the eighth), the count is that of the bright region alone, but
  for one page of the eighth video.
- In the other five videos the search still gives more pages than the bright
  region alone. The regions are now the book or one page of it: in the frames
  that a person looked at, no region is a block of text. The count is wrong for
  other reasons: see "Limits".
- The analysis of the bright-room video takes 5.4 s, before 5.15 s: the search
  runs on each frame there.

## Limits

- **A sheet on a brighter surface of the same colour.** White paper in a shadow
  on a white desk in the light has no other colour around it and is not
  brighter. The rule rejects it, and the bright region stays, as before
  decision 0024. The line search of decision 0026 does not find such a sheet
  too.
- **A flood that gets into the paper through a gap.** The surface that the
  flood reached is then the paper. In three frames at the end of the cover view
  of the bright-room video (91, 92, and 94), the flood is inside the cover. The
  region of the search was still good there, and the rule rejects it: the
  detector takes the wall for the paper in those frames. The pages of the
  result stay the same, because the frames before them hold the view.
- **A table with a frame near the edges of its page.** When a shadow of the
  fold, a hand, or the edge of the book lies outside three sides of the table,
  those sides have a darker surface outside. One such frame was seen in the
  PUCIT videos.
- **One page of an open book.** The fold is one side of four, so the page alone
  passes the rule. In the PUCIT videos the detector changes between the whole
  book and one page from frame to frame, which gives views that are too short
  and too many.
- **The PUCIT page counts are still wrong.** The books lie turned by a quarter
  turn (the fold goes from the left to the right), which the split of a spread
  into two pages does not handle. The videos are small, and the paper and the
  desk are nearly one colour.
- The numbers of the rule (16 directions, 4 pixels, 3 codes of chroma, 12 codes
  of luma, the part of 0.6) come from eight PUCIT videos and one phone video.

## Consequences

- A block of text, a picture, or a table on a page is no more the paper for the
  outline search.
- `detect.Options` has `min_other_surface`. A value of 0 turns the rule off.
- A frame with a region for the outline search costs a little more time: four
  more steps of the morphology on the working image.
- The line search of decision 0026 has its own rule for the colour around a
  page. It does not use this function.
- The next step for the PUCIT videos is not in the detector of one frame: the
  quad of the frame before as a prior, and a book that lies in the second
  direction.
