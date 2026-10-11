# Research: a Python prototype of the fusion

Source: a research agent, 2026-10-09. The agent wrote a prototype with numpy and
OpenCV and ran it on three spreads of the benchmark video (6 pages, 216 frame
pages). The scripts are in `prototypes/fusion/`.

`[M]` = measured by the prototype. `[I]` = inference of the agent. Residuals are
full-resolution page pixels on 48 px text blocks, as median / 95th percentile. The
frames were JPEG files of quality 1, not exact copies.

## Result

- Reference frame plus masked patches from donor frames is the rule to use. Soft
  minimum and median are worse on every spread.
- Glare repair works well. Finger repair is only partial on this data.
- Two visible defects remain, see "Did not work".

## Recommended algorithm (per page)

1. **Score** each frame at 960x540: variance of Laplacian on the upper 6-62 % of
   the quad. Drop frames below 0.6 x the median [M]. Reference = best score with a
   complete page [I: the best score alone selects zoomed or hand frames].
2. **Start pose by chain**, from the reference outward, on every frame. Page at
   1/8 (150x212): block 24, step 12, search ±12, 2 passes. Then 1/4: block 32, step
   20, ±6. ZNCC ≥ 0.6, parabola sub-pixel, normalised DLT, 6 re-weight passes with
   a cut at 2.5 sigma (MAD). [M]
3. **Refine donors only.** Homography at 1/2 resolution (block 32, step 32, ±4).
   Grid at 1/2 resolution: node spacing 48 (96 px full), block 32, ±4. Reject nodes
   with ZNCC < 0.6, eigenvalue ratio < 0.1, or > 1 px from the 3x3 neighbour median.
   Fill, 3x3 median, bilinear [M]. Add a 1/4-resolution grid level (±16 px) first
   [M, diagnostic only].
4. **Trust gate:** residual median ≤ 0.4 px and p95 ≤ 1.5 px. [M on the upper 78 %
   of the page; it must cover the full page, I]
5. **Warp once**, bicubic, at H·(x + flow).
6. **Gain:** one gain per channel (median log ratio on paper). Add a 64 px tile gain
   map from paper pixels for frames with the hand in view. [M]
7. **Finger mask** at 300x425: non-paper = luma < 0.72 x white OR (R−B)/(R+B) >
   paper + 0.07. Opening radius 12. Flood fill from the border. Confirm with ≥ 2
   other frames that differ by > 0.12 luma. Close, dilate 5. Donor margin 24 px. [M]
8. **Glare confidence** at 300x425: m = min(R,G,B), Gaussian sigma 0.7. B =
   second-lowest m over trusted frames, without fingers and shadows.
   conf = clamp((m−B−0.06)/0.06), 5x5 grey dilation, Gaussian sigma 1.5. Mask =
   conf > 0.3, grown 12 px. [M]
9. **Donors:** greedy cover of the mask from ALL trusted frames of the spread. Use
   5, maximum 8. [M]
10. **Fuse:** one donor per pixel in priority order, feather sigma 6 px. [M]

## Key numbers [M]

| Item | Value |
|---|---|
| Quad only, stable frames | 3.4 to 141 px median per page, worst frame 253 px |
| + homography | 0.23-0.51 / 0.58-1.94 |
| + grid, stable frames | 0.11-0.22 / 0.35-1.14 |
| + grid, early frames | 0.14-0.26 / 0.48-1.57 |
| Grid spacing/block (stable, pooled) | none 0.20-0.32 / 0.70-1.73; 128/96: 0.14-0.26 / 0.54-1.39; 64/48: 0.13-0.22 / 0.47-1.57; 32/48: 0.10-0.16 / 0.41-1.12 |
| Page flex after homography | stable p95 0.9-3.1 px; early p95 1.8-6.8 px; lifted corner 18-24 px |
| Quad start converges (stable) | 123/143; 98/141 without the 1/8 level |
| ORB + RANSAC start (stable) | 136/143 |
| Chain, every frame, coarse levels | 152/160 within 6 px; the 8 failures are hand-covered or blurred frames |
| Luma gain drift, stable / early | 0.96-1.07 / 0.92-1.01 |
| R/G and B/G drift, stable / early | up to 4.3 % and 6.4 % / 7.3 % and 12.1 % |
| Glare lift on ink / on paper | +0.05 to +0.14 luma / +0.010 to +0.017; no clipped pixels |
| Glare area in a typical frame | 2.8-4.3 % of the page; 18.4 % on one page |
| Glare with ≥ 1 clean donor, N = 5 / 8 / 12, greedy cover | 74-98 / 79-98.5 / 81-99 % |
| Same, donors spread evenly over stable frames | 56-96 / 58-97 / 63-97 % |

Fusion with 8 donors, six pages:

| Rule | Sharpness outside mask | Ink area | Ink luma in mask (three pages) |
|---|---|---|---|
| Reference | 1.00 | 1.00 | 0.24 / 0.42 / 0.42 |
| Patch, feather or Laplacian | 1.00 | 1.00 | 0.20 / 0.19 / 0.17-0.19 |
| Soft minimum | 0.72-1.00 | +13 to +34 % | 0.19 / 0.16 / 0.16 |
| Median | 0.71-0.89 | −10 to +3 % | 0.26 / 0.34 / 0.41 (glare stays) |

- Feather and Laplacian blends are equal by eye.
- Sharpness scores: variance of Laplacian puts two visibly soft frames at rank 11
  and 15; min(Gx², Gy²) puts them at 3 and 4.
- The quad start is not sufficient when the frame clips the page (28 of 45 frames
  converge). ORB is not necessary; the per-frame chain replaces it.
- A per-frame gain per channel is necessary.
- Finger repair on one spread: left page 64 % of the finger area from stable
  frames, 75 % with early frames; right page 13 % and 56 %. A finger stays at the
  gutter bottom in all frames.

## Did not work [M]

- A 20th-percentile baseline misses static glare: 0.19 % of the page found, 3.18 %
  present.
- Median and soft minimum: see the table.
- A luma-only finger test: light skin went into a patch. An opening radius of 3:
  header bars at the page edge became "fingers".
- A shadow test against the stack median discarded the clean frames of a picture.
- **Open defect:** text shows two times at the bottom-left of one fused page. Early
  donors have 18-24 px flex there; the grid search is ±8 px. A patch check against
  the reference is necessary. [I]
- **Open defect:** parts of fingers remain in all fused spreads.

## What the Zig code took from this, and what it did not

| Finding | State in the Zig code (2026-10-09) |
|---|---|
| Reference plus patch | Done (`fuse.zig`) |
| Second-darkest value as the ink value; fingers and outside cells excluded | Done. The cell value is the mean of the 4 darkest pixels of an 8 px cell. |
| Finger = dark, skin tint, connects to the page border | Done, on 8 px cells with a margin of 3 cells. No opening step. |
| Donors by greedy cover | Done on the ink maps of the analysis pass (`timeline.selectDonors`), not on full-size masks |
| Per-frame gain | Each frame is flattened by its own paper colour surface (`enhance.flatten`) |
| Homography plus shift grid | Done (`register.zig`): 32 px tiles, 5 levels. The start is the quad of each frame. |
| Chain start pose | Not done. A frame whose quad start fails is not a donor. |
| Trust gate on the residual | A simpler gate: matched tiles ≥ 35 %, RMS ≤ 1 px |
| Patch check against the reference | Not done. This is the cause of the remaining doubled text. |
| Sharpness score min(Gx², Gy²) for the reference | Not done. The reference comes from the analysis pass. |
