# 0002: Two passes: small frames for analysis, then selected full frames

Date: 2026-10-09. Status: accepted.

## Context

The benchmark has 4984 frames of 3840 x 2160. One decoded frame is 12 MB, so all
frames are 62 GB. The result needs approximately 8 frames per spread at full
resolution.

## Decision

1. **Analysis pass.** The caller pushes every frame at a small size (960 x 540 for
   the benchmark). The library computes a small record per frame: the page corners,
   a thumbnail of each page, and the cells that a hand covers. The frames are
   independent, so the caller can analyse them on many threads.
2. **Plan.** The library splits the records into spreads. For each spread, it
   selects the reference frame and the other frames for the fusion. The plan lists
   the frame indexes that it needs at full resolution.
3. **Render pass.** The caller pushes the listed frames at full resolution. The
   library renders each spread into pages.

## Consequences

- Memory use stays small: one record per frame, then the frames of the spreads in
  work.
- An Android app can do the same with `MediaExtractor.seekTo`.
- The video is decoded two times in part. The second pass decodes only the groups
  of pictures that hold selected frames.
- Sharpness at full resolution is unknown in the analysis pass. The plan therefore
  asks for more frames than the fusion uses, and the render pass selects again.
- A live camera mode needs a different flow (one pass with a frame buffer). It is
  not part of this decision.

## Update, 2026-10-09

The render pass has three steps now: a small picture of each spread from its
reference frame, the duplicate search (decision 0010), and the pages with their
donor frames (decision 0011). The caller still pushes only frames that the library
asks for.
