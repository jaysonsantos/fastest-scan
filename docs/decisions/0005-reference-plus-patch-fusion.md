# 0005: Fusion keeps one reference frame and patches it

Date: 2026-10-09. Status: accepted.

## Context

Google PhotoScan uses a soft minimum of five registered frames. The research
(`docs/research/glare-fusion.md`) measured that a full-frame minimum makes ink
strokes 10 % thicker at 0.3 px registration error, and 37 % thicker at 0.6 px.
A median fails when glare covers the same place in more than half of the frames.

The benchmark also has fingers on the page. Fingers are darker than paper, so a
minimum rule selects the finger and not the page.

## Decision

- The sharpest frame with little glare and little hand cover is the reference.
  Outside the patch masks, the result is the reference frame, with no blend.
- A glare mask marks where the reference is much brighter than the low values of
  the other frames at the same place.
- A cover mask marks where a hand covers the reference and another frame shows the
  page.
- Inside the masks, the result comes from donor frames. The masks have soft edges.
- If no donor shows a place, the reference stays. The result never has invented
  content.

## Consequences

- Text outside the masks is as sharp as one video frame.
- The registration must be good only near the masks.
- A finger that stays at one place in all frames stays in the result.
- The log reports the area that the fusion could not repair.
