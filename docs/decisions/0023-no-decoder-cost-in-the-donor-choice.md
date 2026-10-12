# 0023: The donor choice has no decoder cost

Date: 2026-10-12. Status: accepted. The idea of a decoder cost is rejected. This
record keeps the measurement, so that the idea does not come back without a new
reason. Decision 0020 named the idea.

## Context

With no frame cache, the render pass needs 425 full-size frames of the benchmark
video, and the decoders decode 2622 frames for them: each frame from a keyframe
to the last frame that a spread needs. One decoded frame costs about 73 ms of CPU
time.

The idea: when two donor frames have almost the same value, take the one that
needs fewer new frames from the decoder.

## What was tried

`timeline.selectDonors` got the keyframe of each frame. The cost of a candidate
was the number of frames that a decoder must decode more for it. The frames that
are chosen, the reference frames of the spread, and the frames of the other page
of the spread made the frames before them free.

Of the candidates with a value of at least a fraction of the best value, the one
with the lowest cost won. The value is the number of cells that the frame
repairs, or its distance to the frames that are chosen.

## Measurements on the benchmark video

| Fraction of the best value | Frames to decode | Donor pages that register | Page area with glare | Not repaired |
|---|---|---|---|---|
| 1.0 (candidates of the same value only) | 2622 | 454 | 1.24 % | 0.07 % |
| 0.95 | 2573 | 454 | 1.21 % | 0.06 % |
| 0.9 | 2456 | 453 | 1.16 % | 0.08 % |
| 0.8 | 2330 | 451 | 1.21 % | 0.08 % |
| 0.6 | 2106 | 455 | 1.33 % | 0.06 % |

With a fraction of 1.0, the PDF has the same bytes as with no cost.

A run with no frame cache uses 964 s of CPU time (decision 0020). At a fraction
of 0.9, the choice saves 166 frames: 12 s of CPU time, about 1 % of the run. At
0.6 it saves 516 frames, about 4 % of the run, and a frame with 60 % of the best
value can then win.

The gain is small for two reasons:

- Frames of the same value are frames next to each other. The choice takes the
  first one of them, and that is the cheapest one already.
- A frame at another keyframe with almost the same value is rare: the glare and
  the hand are at another place there.

## Decision

The donor choice does not look at the decoder. The code of the experiment is not
in the repository.

One part stays: with `--verbose`, the program prints the number of full-size
frames that the render pass needs and the number of frames that the decoders
decode for them, also when all frames come from the frame cache.

## Consequences

- The render pass decodes about six frames for each frame that it needs.
- To lower the decoder work more, read the video one time: the stream session of
  the branch `android-app`.
