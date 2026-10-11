# 0011: The dark frames show the ink; a finger gives no data

Date: 2026-10-09. Status: accepted. This record gives the details of decision 0005.

## Context

Decision 0005 says: keep the reference frame and patch it. The first rule for the
patch mask compared the reference with the median of all frames: brighter than the
median was glare, darker was a finger.

The benchmark showed two faults of that rule:

- Glare stays at one place of the page in most frames of a stable run. The median
  then is the glare, and the rule replaced clean ink of the reference with glare.
- A finger that most donor frames show would go onto a clean reference.

The same flattening step that makes paper white also makes a glare region white,
so "looks like clean paper" cannot protect a region.

## Decision

The comparison runs on 8 pixel cells of the flattened pages (`fuse.zig`).

1. **Ink value.** The value of a cell is the mean of its 4 darkest pixels, then a
   3x3 mean over the cells. Thin text is as dark in this value as a picture.
2. **Fingers.** In each frame, a cell is a finger when its mean luma is below 0.7,
   its red is 0.08 or more above its blue, and it connects to the page border
   through dark cells. Three cells more around it also count. A frame gives no
   data in its finger cells.
3. **Glare.** The ink value of a place is the second darkest value of the frames
   with data (the darkest with fewer than four frames). The reference has glare in
   a cell when its value is 0.10 or more above that.
4. **Faults of the reference:** a cell with glare, a cell with a finger, and a cell
   outside the reference frame. Each fault needs one donor with data.
5. **Donor.** The frame nearest to the ink value. One donor for each connected
   region of faults, where that donor repairs the cell.
6. **Blend.** The repair covers two cells more around a fault, with an edge of
   about two cells.

`timeline.selectDonors` chooses the donor frames before any full-size frame is
decoded, from the ink maps of the analysis pass, as a greedy set cover.

## Consequences

- Glare that is in all chosen frames stays. A finger that is in all frames stays.
- A soft shadow in two or more donor frames can make a patch of paper a little
  darker.
- A dark print with a red tint that touches the page border counts as a finger in
  all frames. It then has no donor and stays as the reference shows it.
- The donor choice works at the size of the analysis frames. It does not see
  glare on a single small word.
