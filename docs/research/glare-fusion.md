# Research: glare removal from several frames

Source: a research agent, 2026-10-09. `[V]` = read in the source. `[V*]` = read
through a summarising fetch. `[S]` = measured in a numpy simulation of the agent
(synthetic text, 6 frames, 10 trials, global sub-pixel shift per frame). `[I]` =
inference of the agent.

See `docs/decisions/0005-reference-plus-patch-fusion.md` for the rule that the code
follows.

## What Google PhotoScan does [V]

- It takes 5 frames. The first is the reference.
- Registration: "we compute ORB features on Harris corners" to "establish
  homographies mapping each frame to the reference frame".
- Refinement: "tiled, non-overlapping cells to form a coarse grid"; the flow of a
  pixel is "the bilinear combination of the flow at the four corners of the cell".
  The speed-up is "~40". The post cites Szeliski and Coughlan (1997). It does not
  give the grid size.
- Compositing: "a soft minimum algorithm to obtain the darkest observed value ...
  the expectation of the minimum brightness over the registered frames, assigning
  less weight to pixels close to the (warped) image boundaries". The reason: "per-pixel
  minimum can produce visible seams". It does not give the formula.
- Model: it "treats glare as an outlier, and only attempts to register the
  underlying, glare-free photo".
- The agent found no PhotoScan patent. A later search found it: Winn, Lieb, Henry
  (Google), US 10,257,485 B2, "Generating a composite image from a physical item".
  See `literature.md`, entry 4.2.

## Recommended pipeline (per page segment)

1. **Trigger, on 256 px thumbnails.** Skip the glare path if no frame has ≥ 0.1 %
   pixels with min(R,G,B) ≥ 0.92. Otherwise run steps 3-5 on thumbnails. Continue
   only if the glare of the reference covers ≥ 0.2 % of the page. [I]
2. **Reference.** Take the sharpest frame (mean squared Sobel gradient; HDR+ uses
   gradient magnitude [V]) among frames with glare area ≤ 1.5 x the smallest. [I]
3. **Global registration.** Harris/FAST + ORB, 2000 keypoints, 8x8 bucket quota, no
   keypoints inside the glare mask dilated 8 px. Ratio test 0.8, RANSAC (2000
   iterations, 2 px), normalised DLT, refit on inliers. Reject a frame if inliers
   < 50 % or median error > 1.5 px. [I; ORB + homography is PhotoScan [V]]
4. **Exposure.** Per channel: gain = exp(median(log(ref/frame))) on blurred
   (sigma 4) pixels in [0.3, 0.94]. [S: error < 0.15 % at ±4 % drift; without gain,
   a minimum darkens paper by 0.055 on a 0-1 scale] Then a 16x12 tile gain map, 3x3
   median, clamp 0.8-1.25, bilinear. [I]
5. **Glare confidence, quarter resolution.** L_i = Gaussian (sigma 3) of
   min(R,G,B); Shen 2009 uses the min channel [V]. B = second-lowest L_i across
   frames (20th percentile for many frames).
   conf_i = clamp((L_i − B − 0.04)/0.04, 0, 1). Set conf = 1 where a channel ≥ 0.98.
   shadow_i = clamp((median − L_i − 0.06)/0.06, 0, 1). [S: precision 0.97, recall
   0.98, a printed white patch 0 % flagged. A single-frame threshold: 0.50 / 0.34,
   patch 100 % flagged.]
6. **Donors.** 5 frames total (PhotoScan value [V]), maximum 8. Greedy cover: add
   the frame that gives the most reference-glare pixels a second clean donor.
   Require sharpness ≥ 0.7 x reference and a glare centroid ≥ 1.5 blob radii from
   the chosen centroids. Stop at 99 % coverage. [I]
7. **Local registration, only near the mask.** Node grid every 32 px. Per node:
   translation-only inverse-compositional LK, 48x48 window, 3 pyramid levels, ≤ 10
   iterations, on locally normalised luma (subtract Gaussian sigma 8 mean, divide by
   local std). Weights (1−conf_ref)(1−conf_donor), Huber loss. Reject nodes with a
   low structure-tensor eigenvalue, > 50 % masked, or ZNCC < 0.6. Fill them by
   membrane smoothing, then 3x3 median. Interpolate bilinearly, as PhotoScan [V].
   Target residual ≤ 0.2 px. [I]
   Pitfall: the reference has no texture inside its glare, so the flow there is
   interpolated. Align donor 2 to donor 1 directly inside the hole. [I]
8. **Warp once.** Compose rectification, homography and flow. Resample the original
   frame with Catmull-Rom bicubic. [I]
9. **Fuse.** Keep the reference outside mask M (conf_ref > 0.3, dilated 12 px).
   Inside M use the weighted mean of the 2 best donors, w = (1−conf)^4 (1−shadow)^4
   x sharpness. Use 1 donor if donor-to-donor ZNCC < 0.8. Match the donor gain to
   the reference on a 16 px ring. Blend with a 5-level Laplacian pyramid. [S,
   simulated with a feathered mask: at 0.3 px residual, the ink area changes −1 %;
   a full-frame minimum gives +10.6 %.]
10. **Fallback.** If the glare centroid spread is < 0.5 blob radius, or no donor has
    conf < 0.3, keep the reference. Apply Y' = Y − 0.7·max(0, blur(Y) − P90(Y)).
    Report the residual glare area. Static cue: a bright blob with lower
    signal-to-noise inside than around it is glare, not white paper (ABBYY patent
    [V*]). [I]

## Failure modes

- Static glare: camera rotation does not move glare on the page; only translation
  does. Flash: the glare follows the camera foot point 1:1. Fixed lamp: shift =
  d · h_lamp/(h_lamp + h_camera). [I, mirror geometry]
- Shadows and fingers are dark outliers. Minimum rules select them. The shadow
  term excludes them. [I]
- Rolling shutter, blur: step 3 rejects the frame. [I]
- Residual ≥ 1.5 px: every rule is worse than no fix. [S, 1 trial]

## Rejected alternatives

- Full-frame minimum or soft minimum: ink area +10 % at 0.3 px residual, +37 % at
  0.6 px; 9 frames are worse than 6 (+20 %). Second-lowest value: +3 %, +14 %. [S]
- Median: with glare overlap in > 50 % of frames, the glare error is 0.22; no fix
  gives 0.23. [S]
- Full-frame weighted mean: best inside glare, but sharpness falls to 0.93 at
  0.6 px. [S]
- Specular-free images (Tan, Shen): chromaticity methods "fail miserably for
  grayscale images" (SIHR README [V]).
- Single-frame HSV thresholds (V > 230, S < 40 in hobby repositories [V]): they
  flag white print. [S]
- Homography only: "duplicated image structures". [V]
- ECC homography: zero-mean, masked, gain-invariant [V], but no page curl.
- Dense flow, thin-plate spline: more unknowns than smooth curl needs. [I]
- Layer separation (Xue 2015): "too computationally expensive". [V]
- Neural single-image removal (DocSHRNet, DocHR14K): invents text in clipped
  areas. [I]

## Sources

1. <https://research.google/blog/photoscan-taking-glare-free-pictures-of-pictures/> [V]
2. <https://data.vision.ee.ethz.ch/cvl/ntire18/talks/WilliamTFreeman_NTIRE2018talk.pdf>
   ("Remove glare by treating it as outliers") [V]
3. <https://people.csail.mit.edu/mrub/papers/ObstructionFreePhotography_SIGGRAPH2015.pdf>
   (the minimum is "an upper bound for the background's intensity") [V]
4. <https://www.ipol.im/pub/art/2021/336/> (HDR+: 4-level pyramid, 16x16 tiles,
   ±4 px search, sharpest reference, robust merge) [V]
5. <https://github.com/opencv/opencv/blob/4.x/modules/video/src/ecc.cpp> [V]
6. <https://github.com/vitorsr/SIHR> (README; `Shen2009/Shen2009.m`: T = mean +
   0.5·std of the min channel) [V]
7. <https://patents.google.com/patent/US9418407B2/en> (ABBYY detection) [V*];
   <https://patents.google.com/patent/US10586316B2/en> (MorphoTrust USA, not ABBYY:
   mask-driven pixel replacement from a second frame) [V*]
8. <https://arxiv.org/abs/1911.05189> (block luminance + stroke histograms,
   abstract only) [V*]
