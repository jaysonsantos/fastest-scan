# 0013: Each page has its own reference frame; a patch must agree with the reference

Date: 2026-10-11. Status: accepted. This record changes parts of decisions 0005
and 0011: the reference frame is per page, not per spread; the finger rule and the
donor rule have new conditions. The other parts of 0005 and 0011 stay.

## Context

After decision 0011 the result had three visible faults:

- **Glare that stays.** Black header bars had a gold tint, pictures had bright
  areas, and some lines of text were washed out.
- **Doubled text.** A patch from a donor frame could lie some pixels off.
- **Blurred patches.** A donor could replace sharp text of the reference.

A debug picture of the faults (`faults/` in the debug directory) showed the causes
on the benchmark video:

1. The timeline chooses the reference frame of a spread without a measure of
   glare. For one spread, the chosen frame had heavy glare, and frames two seconds
   later had none.
2. Those clean frames were views from near. They showed one page in full and cut
   the other page. One reference frame for the two pages cannot be right there.
3. A frame that cuts a page was never a donor.
4. A black header bar in warm light has more red than blue. With gold glare it has
   the colour of skin. The finger rule took the bar for a finger in all frames, so
   no frame could repair it.
5. Nothing compared a donor with the reference before the copy.

## Decision

### The reference frame of a page (`timeline.chooseReference`)

- Each page of a spread gets its own reference frame, from all the stable frames
  of all the views of the spread. A candidate does not cut more sides of the page
  than the first choice of the timeline.
- The score is the page score of the timeline plus a term for the ink that the
  frame shows. For each ink cell, the dark level is the 10 % quantile of the ink
  values over the candidate frames. The ink of a frame is the sum of its ink
  values as a fraction of the dark levels. Glare washes ink out and blur makes
  thin text lighter, so one number measures the two.
- A mild term keeps frames where the page has the shape of the pages of the
  document: a page that lifts from the desk has another shape.
- The first choice stays when fewer than 8 candidates exist, or when no frame is
  0.05 better.
- Pages with the same reference frame share one render call and one donor set.

### Donor frames

- A frame that cuts one side of a page can be a donor. The place of the whole page
  in it follows from the three sides in view and the page aspect
  (`detect.completeQuad`). Its ink map moves to the cells of the whole page before
  the comparison (`wholePageInk`).
- Such frames come last: up to 3, in addition to the 6 frames that show the whole
  page. Their start position is less exact.
- The registration of a donor runs in up to 3 rounds (`render.alignDonor`). Each
  round starts from the donor page moved by the transform so far.

### The fusion (`fuse.zig`)

- **Patch check.** Each connected region of faults gets one donor. The candidates
  are compared with the reference in the ink cells within 3 cells around the
  region, where the reference has no fault. The comparison is the zero-mean
  normalised correlation, with the donor moved by up to 8 pixels. A donor needs a
  correlation of 0.7 or more, and the best shift must not be at the end of the
  range. The repair copies the donor at the best shift.
- **Sharp donor.** Among the donors that pass, the region takes the one with the
  largest product of correlation and contrast ratio. The contrast ratio is the
  contrast of the donor around the region as a fraction of the contrast of the
  reference, with 1 as the top value.
- **No check possible.** A region with blank paper around it takes the donor with
  the most votes of its cells, as before.
- **Fingers.** A cell is a finger only when its red is 0.15 or more above its blue
  (0.08 before) and its mean luma is 0.3 or more. A finger cell of the reference
  is a fault only when the frames that show the page there differ from it by more
  than 0.10 in mean luma.
- **Glare on dark areas.** Glare on a header bar leaves dark specks, so the ink
  value does not show it. Where the dark frames show a mean luma below 0.6, the
  reference also has glare when its mean luma is 0.10 or more above theirs.

## Measurements on the benchmark video

| State | Pages | Donor pages that registered | OCR good words, all 63 pages | OCR mean confidence, all pages |
|---|---|---|---|---|
| Before (decision 0011) | 63 | 313 | 2330 | 73.8 |
| Patch check only | 63 | 313 | 2324 | 73.6 |
| Plus the reference frame per page, the sharp-donor rule, and the finger rule against the other frames | 63 | 300 | 2378 | 74.9 |
| Plus frames that cut a page as donors, with rounds | 63 | 466 | 2387 | 75.0 |
| Final: plus the finger limits, the dark-area rule, and the correlation limit of 0.7 | 63 | 466 | 2382 | 74.8 |

The OCR number of one text page moves by 10 to 20 words between two runs that
look the same. So the OCR numbers show no loss, and the gain is in the pictures:

- The page "BUTTON FUNCTIONS" had a gold header, glare on the picture, and pale
  text. It now has a black header, a clean picture, and sharp text from the near
  frames.
- Page 7: the first line was washed out. It is readable now.
- Page 8: the word at the end of the first line was doubled. It is correct now.

The render pass is slower: about 60 s in place of 33 s, with 9 donor frames per
page in place of 6 and separate calls for pages with different reference frames.

## Consequences

- Glare stays where no frame of the spread shows the ink. Example: the left half
  of the header "SAFETY PRECAUTIONS/WARNINGS".
- A finger that holds the page in all frames stays.
- The ink measure compares frames through their page corners. With few frames, or
  with a page that moves, it is not safe: hence the limit of 8 candidates.
- The patch check does not see a donor that is off along a line of text by more
  than the search range when the lines are at the same height: two such texts
  correlate at about 0.5. The limit of 0.7 is above that.
- A real finger that is darker than 0.3 in a cell is not found in that cell. The
  margin of 3 cells around the other finger cells covers it.

## Ideas from other work

- The reference frame as the best frame of a burst, and the merge that uses another
  frame only where it agrees with the reference: Hasinoff et al. 2016 (HDR+), see
  `docs/references.md`. The measures here are different: ink against the other
  frames for the choice, and a correlation around the fault for the merge, because
  the reference is wrong inside the fault.
