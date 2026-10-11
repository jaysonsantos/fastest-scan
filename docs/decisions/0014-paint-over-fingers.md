# 0014: A new finger rule; a finger that stays gets the colour of the paper

Date: 2026-10-11. Status: accepted. This record replaces the finger rule of
decisions 0011 and 0013. It adds one exception to the rule of decision 0005 that
the result never has invented content. It also changes two numbers of the patch
check of decision 0013.

## Context

After decision 0013, the most visible fault was the thumbs that hold the booklet.
A thumb is at the same place in all frames of a spread, so no frame can repair it.
With `--fingers keep`, the benchmark result has a finger, or the wood of the desk
at a round page corner, on 60 of 63 pages.

The layer pictures (`--debug-layers`) also showed faults of the old finger rule.
That rule was: a cell is a finger when it is dark, connects to the page border
through dark cells, and has red 0.15 above blue.

1. A frame that cuts a page shows the finger at the cut side, not at the page
   border. The rule did not find it. A finger is darker than paper, so the glare
   rule took the finger of two such donor frames for ink and copied it onto text.
2. The bright part of a thumb, with a luma above 0.7, was not a finger.
3. A black header bar with gold glare, and a strip of the desk, were fingers.
4. The paper next to a finger has a shadow, and the skin shines on it. Donor
   frames brought these pale patches into the result.
5. A finger in a shadow looks lilac after the flatten step: it has as much blue
   as red.

## Decision

### Find a finger (`finger.find`)

All numbers are on the scale of a flattened page: blank paper is 1.0. A cell is
8 x 8 pixels.

- **Skin.** A cell has the colour of skin when red is 0.08 or more above green,
  blue is at most 0.05 above red, green minus blue is at most red minus green
  plus 0.05, the mean luma is between 0.25 and 0.92, and the luma changes by at
  most 0.35 in the cell. Gold print and paper in warm light are more yellow. A
  black bar is darker. Text has texture.
- **A wide blob.** A finger has a place where all cells within 2 cells are skin.
  A thin strip of the desk at the edge of the page has no such place.
- **From a border.** The blob connects to the border of the page, or to a cell
  that the frame does not show. A printed picture with the colour of skin does
  not.
- **Margin and halo.** The mask of a finger is the blob, 3 cells around it, and
  then up to 10 cells more over cells that have no texture and show a shadow
  (mean luma 0.6 to 0.93) or a tint (red 0.04 above blue). A group of 48 cells
  or fewer that the mask closes in belongs to the mask.

A frame gives no data about the page in the mask. This is as before: a finger
never moves from a donor frame into the result, and a finger of the reference
goes away where another frame shows the page.

### Paint a finger that stays (`finger.paint`)

After the repair, the cells of the mask that still show the reference frame are a
finger that is in all frames. The paint gives them the colour of the blank paper
around them.

- Ink next to the finger stays. A cell of the mask keeps its dark pixels when it
  has text (ink, and a mean luma 0.15 above the ink value) or dark print (mean
  luma below 0.45), and is more than 1 cell from the finger. Only the pixels as
  bright as paper get the paint there.
- The colour is the mean of the brighter half of the blank cells within 3 cells
  around the mask.
- A mask larger than 15 % of the page is not painted. It can be a picture.

`--fingers` selects the rule:

| Value | Rule |
|---|---|
| `all` (default) | Paint each finger. |
| `blank` | Paint a finger only when at most 2 cells in the mask and around it have ink. A finger with ink next to it can hide ink, so it stays. |
| `keep` | Paint nothing. |

The paint cannot know what is below a finger. This is the one place where the
result shows something that no frame shows. The reason for the default: with
`blank`, a finger stays on 51 of 63 pages of the benchmark, because the thumbs
lie on or next to the last line of text. A thumb in the result hides the same
text, and it is the larger fault.

### Glare with a tint on dark print (`fuse.zig`)

The old finger rule took a header bar with weak gold glare for a finger in most
frames. The one frame without the glare then repaired the bar. That was an
accident, and the new finger rule does not do it. A rule of its own replaces it:

- The reference cell has a mean luma below 0.7, and red 0.12 or more above blue.
- One donor frame shows the cell as a dark area (mean luma below 0.6), 0.10 or
  more darker than the reference, and with 0.08 or more less tint.

Then the cell has glare, and that frame is its donor. One frame is enough: the
rule of the second darkest frame (decision 0011) does not see glare that all
frames have but one.

### The patch check

- The search range of the shift is 12 pixels (8 before). A page that lifts from
  the desk moves by more than 8 pixels between two frames. The CPU time did not
  change.
- A repair does not grow into a cell where its donor frame shows a finger.

### Debug output

- `layers/` (with `--debug-layers`): the page of each frame as it goes into the
  fusion. This is the input for a prototype.
- `cover/`: each page with a tint where the reference frame shows a finger (pink)
  and where no donor frame shows the page (blue). A fault in such a cell cannot
  get a repair.
- `faults/` has two new colours: yellow-green for a painted finger, violet for a
  finger that stays.

## Measurements on the benchmark video

| State | Pages with a finger that stays | Mean page area painted | Faults with no repair | OCR good words, all 63 pages | OCR mean confidence, all pages |
|---|---|---|---|---|---|
| Before (decision 0013) | not measured, most pages | 0 % | 0.18 % | 2382 | 74.8 |
| New finger rule, `--fingers keep` | 60 | 0 % | 0.10 % | not measured | not measured |
| `--fingers blank` | 51 | 0.76 % | 0.10 % | not measured | not measured |
| `--fingers all`, the default | 0 | 3.33 % | 0.10 % | 2394 | 74.9 |

The run time is the same as before: about 63 s to 70 s with a warm frame cache.

What the pictures show:

- No page shows a thumb. The wood of the desk at the round page corners is
  gone, but for thin lines.
- The finger of a donor frame that lay on the lines "PRESS & HOLD TO REJECT AN
  INCOMING CALL" is gone.
- The header "ARTIKELLISTE" was "ELLISTE" with glare before. All letters are
  readable now, from a donor 11 pixels off.

## Consequences

- **Text below a finger is lost, and the result does not show that.** A line that
  went below a thumb ends at the place of the thumb. Examples: the circle of the
  item "6 TYPE-C CHARGING PORT" is cut, and one Dutch line ends after "DRUK TWEE
  KEER". Film the pages with the fingers on the margin, or use `--fingers blank`.
- Print with the colour of skin, without texture, that touches the page border is
  a finger for this rule. The limit of 15 % of the page is the only guard.
- A pale area of print without texture next to a finger counts as its halo: the
  reference loses it, and a donor gives no data there.
- A thin strip of the desk at a page edge stays. Thin brown lines show at the top
  of some pages.
- The skin numbers come from one video with one hand and one lamp. Another skin
  tone or another light needs a check with `--debug-dir`.
- The header "BUTTON FUNCTIONS" is a little less sharp than before. The patch
  check measures the sharpness of a donor around a region, not in it.

## How the rule was found

`prototypes/fingers/` has two Python scripts that work on the layer pictures. The
first one compares the old mask with a new one. The second one tests which
fingers have blank paper around them. They hold the state of the first
experiment: the halo, the closed-in cells, and the paint that keeps ink came
later, in Zig, and are not in the scripts.

## Ideas from other work

- A fixed rule on red, green, and blue for skin: Kovač, Peer, and Solina 2003, see
  `docs/references.md`. The margins here are other values, for a page with white
  paper at 1.0.
