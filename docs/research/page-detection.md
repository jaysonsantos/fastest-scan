# Research: page detection, page turns, and frame selection

Source: a research agent, 2026-10-09. The agent read the papers and source files
below. `[V]` marks a claim that the agent read in the source. `[I]` marks an
inference of the agent; treat the values as start points.

See `docs/decisions/0004-page-detection-by-paper-mask.md` for what the code does
first, and why it differs from this recommendation.

## Recommended pipeline

1. **Decode two times.** Pass A: all frames at 240 px short side. Pass B: only the
   selected frames at full resolution. [I]
2. **Measure motion.** Get the global shift by phase correlation of successive grey
   frames. Shift the previous frame. Take the absolute difference, threshold at 25,
   erode 3x3. `d` = changed fraction, averaged across 6 frames.
   [V method: Xerox US9247136; I values]
3. **Segment with hysteresis.** A turn starts at `d` > 0.12. A stable segment needs
   `d` < 0.02 and shift < 0.5 % of the diagonal per frame for 0.5 s. Scale both
   thresholds by median + MAD of `d`. Compare successive frames only; then slow drift
   does not accumulate. [I]
4. **Detect the quad on each stable frame at 240 px.** [V Tropin]
   - Convert to Lab. Close L with a 7x7 element to remove text. Sum the gradients of
     L, a, b. [V Puybareau]
   - Oriented Hough: each edge pixel votes for one cell from its gradient angle.
     Cell: 2-5 px by 2 degrees. [V Zhang-He]
   - Keep at most 15 peaks per class (near-horizontal, near-vertical), at least 20 %
     of the maximum, at least 10 px apart. [V Tropin]
   - Enumerate 2+2 lines. Reject: corner angle more than 30 degrees from 90 degrees;
     opposite sides less than 1/5 image size apart; perimeter < (W+H)/4. [V Zhang-He]
   - Score `C = Σw/(1+Σ(1−c)) − Σw'`. `w` = edge strength on a side. `c` = supported
     fraction. `w'` = edge strength on the 10 px extensions past the corners; it
     rejects table edges. For the top 4, add the chi-square distance of 512-bin RGB
     histograms inside and outside. [V Tropin; tune the weight]
   - Refine each side at full resolution: edge pixels within 10 px, robust fit, then
     least squares. [V Zhang-He]
   - Missing side: use 3 lines plus the known aspect ratio and focal length
     [V Tropin]. Take the aspect from earlier pages [I]. Else use the frame border.
5. **Smooth per segment.** Move all quads to one reference frame with the global
   shift. Take the per-corner median. Drop frames more than 2 % of the diagonal
   away. [I]
6. **Select the best frame.** Skip 0.3 s after a turn. Sharpness =
   `min(mean Gx², mean Gy²)` on edge pixels inside the quad at half resolution or
   more, divided by local contrast. The minimum penalises motion blur. [I] ΔDoM is
   the published document metric [V US9087262]. Score = sharpness × (1 − glare) ×
   (1 − skin) × quad area. Glare = quad pixels ≥ 250 with low gradient. Skin = YCbCr
   skin fraction. [I]
7. **Merge duplicates.** Rectify each page to a 64x64 gradient thumbnail. Merge
   adjacent segments at NCC > 0.8. Drop non-adjacent repeats at NCC > 0.9; keep the
   sharper one. [I]
8. **Recover aspect and size.** [V Zhang-He] Corners are homogeneous, origin at the
   image centre. `m1`, `m4` are diagonal; `m2` is along the width.
   `k2=((m1×m4)·m3)/((m2×m4)·m3)`, `k3=((m1×m4)·m2)/((m3×m4)·m2)`,
   `n2=k2·m2−m1`, `n3=k3·m3−m1`, `f²=−(n2x·n3x+n2y·n3y)/(n2z·n3z)`,
   `(w/h)²=(n2x²+n2y²+f²·n2z²)/(n3x²+n3y²+f²·n3z²)`.
   If `k2` or `k3` is near 1, or `f²` ≤ 0, use mean side lengths. Compute `f` one
   time as the video median. Use one median aspect for all pages. Snap to 1.414 or
   1.294 only within 2 %. [I] Size: `W=max(top,bottom)`, `H=W/r`; or
   `H=max(left,right)`, `W=r·H`. [V]
9. **Detect a spread.** Candidate if w/h > 1.1; ScanTailor uses width > height [V].
   Confirm with step 10. Apply the majority vote of all segments. [I]
10. **Find the gutter on the rectified spread.** [V ScanTailor] Scale to about
    1000 px height. Response = `maxfilter(11x1) − maxfilter(1x11)`, clipped at 0.
    Delete bright vertical runs < 19 px. Hough at ±7 degrees, step 0.25 degrees.
    Reject lines more than 0.6 × half-width from the centre. Take the line nearest
    the centre. Fallback: column projection of binarised content; take the gap with
    content balance ≥ 0.25. Extra cue: the kink in the top and bottom page edges. [I]
11. **Warp each half with its own homography** (outer corners + gutter ends). [I]

## Dewarp

Not in the first version. The method of mzucker needs text-span detection and a
Powell optimisation of 89 to 600 parameters; 4 to 25 s per page; 915 Python lines
[V]. The cheaper next step is a ruled-surface remap between fitted top and bottom
edge curves. [I]

## Neural networks

Not necessary for the first version. Hough got 0.9866 IoU on SmartDoc; a U-Net got
0.991 to 0.993 [V]. On clutter the gap is larger: Genius Scan went from 51 % to
75-85 % correct with MobileNetV2 at 96x96 [V]. Keep the detector behind an interface.

## Rejected alternatives

- Canny + largest contour (jscanify): text edges dominate [V Dropbox]; a finger
  breaks the contour [I].
- Histogram, hash, or raw frame difference for turns: text pages look the same;
  hand shake gives false turns. [I]
- Learned page-turn model: classical motion + skin + dedupe got F1 0.91, the model
  got 0.94 to 0.97. [V Wigington]
- Variance of Laplacian only: no contrast normalisation. [I]
- Tree of shapes (SmartDoc-2015 winner): more than 1 minute per frame. [V]
- Bounding-box aspect ratio: up to 30.8 % error; Zhang-He: 1.4 to 5.7 %. [V]
- Forced A4 snap: most books are not A-series. [I]
- Centre split (unpaper `--output-pages 2`): no gutter detection. [V]

## Sources

1. Zhang and He, "Whiteboard scanning and image enhancement" (sections 3-5):
   <https://www.microsoft.com/en-us/research/uploads/prod/2016/12/Whiteboard-It.pdf>
2. Tropin et al.: <https://arxiv.org/abs/2106.09987>, <https://arxiv.org/abs/2008.02615>
3. Puybareau and Géraud: <https://www.lrde.epita.fr/~theo/papers/geraud.2018.icip.puybareau.pdf>
4. Dropbox: <https://dropbox.tech/machine-learning/fast-and-accurate-document-detection-for-scanning>
5. Genius Scan: <https://blog.thegrizzlylabs.com/2024/10/document-detection.html>
6. ScanTailor: <https://github.com/scantailor/scantailor/blob/master/filters/page_split/VertLineFinder.cpp>,
   `PageLayoutEstimator.cpp`
7. mzucker: <https://mzucker.github.io/2016/08/15/page-dewarping.html>
8. Xerox: <https://patents.google.com/patent/US9247136>
9. Wigington: <https://arxiv.org/abs/2411.00576>
10. ΔDoM: <https://patents.google.com/patent/US9087262>

The agent read sources 1, 2, 3, and 6 as full text. It read the patents (8, 10), the
blog posts (4, 5, 7), and source 9 through a page summariser. It did not read the
SmartDoc-2015 report; those numbers come from sources 2 and 3. `paper-notes.md` has
notes on the report itself.
