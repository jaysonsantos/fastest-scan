# Research: notes on five papers of the literature

Read on 2026-10-11 from the full text. This page holds notes in our own words, with
the numbers that the code can use. Equations are from the papers; the remarks "for
this project" are ours.

## 1. He, Pan, Xie, Sun, Naoi 2013: book dewarp from the page boundary

Y. He, P. Pan, S. Xie, J. Sun, S. Naoi (Fujitsu R&D Center), "A book dewarping
system by boundary-based 3D surface reconstruction", ICDAR 2013, pp. 403-407.
DOI 10.1109/ICDAR.2013.88.

**What it does.** It removes perspective and page curl from one picture of an open
book. It uses only the outline of the pages: no text lines, no extra hardware.

**The page model.**

- A spread has two boundary curves (top and bottom) and 6 corners: 4 page corners
  and 2 spine corners. The side edges of a page are straight lines.
- Each page is a cylinder: all the vertical columns of the page are parallel in
  space. In the picture they meet at the vanishing point of the two side edges.
- So each point of the bottom curve has a partner on the top curve: the point
  where the line to the vanishing point cuts the top curve. The segment between
  the two is one column of the page.

**Horizontal metric.** `L(i)` is the length of column `i` in the picture. A longer
column is nearer to the camera. For a column that is one pixel wide in the picture:

- width on the paper: `dx(i) = Cx / L(i)`, with `Cx = max L(i)`;
- depth: `z(i) = k · Cx / L(i)`, with a constant `k` "to describe the 3D ratio";
- step along the paper: `ds(i) = sqrt(dx(i)² + (z(i) − z(i−1))²)`;
- the position of column `i` in the flat page is the sum of `ds` up to `i`,
  divided by the sum over all columns.

The paper states that a 2D method (curve length in the picture) is only correct
when the camera is far away, and that the depth term matters most at the steep
part near the spine.

**Vertical metric.** Along each column, the flat position `y*` maps to the picture
position `y` by a 1D projective map `y = (y* + c) / (a·y* + b)`. Three point pairs
give `a`, `b`, `c`: the two ends of the column, and the vanishing point, which is
at infinity in the flat page.

**How it finds the outline.** A coarse-to-fine process: 4 coarse corners from a
book and background segmentation on a small picture (the book lies on a mat of one
colour); "extended" boundaries tracked from shifted corners; then exact corners
from the Harris response and the curvature. The spine corner comes from the
curvature of the more curved side, then the image gradient in the middle.

**Numbers.** 366 pictures from an overhead scanner on a black mat. The outline was
correct within 2 mm on 89.3 % of them (82.9 % + 11.6 % for regular books with the
page outline or the book outline, 76.0 % + 6.0 % for magazines). Errors: weak
gradients on the boundary, and wrong corners.

**For this project.**

- The model fits the paper mask detector: the mask gives the top and bottom
  outline, the side edges and the fold are straight lines already.
- `k` is the focal length in pixels when `dx` and `z` have the same unit: the
  width of one pixel at depth `d` is `d / f`, and `d = f · h / L` for a column of
  real height `h`. The paper does not say this; it is our reading.
- The model has no answer for a page corner that lifts ("upwarping" is ignored in
  the paper too).
- Fujitsu has patents on book scanning. We did not search for a patent on this
  method. Check before a product ships it.

## 2. Mondal, Pant, Soni 2023: dewarp from C2 continuous boundary curves

P. Mondal, A. Pant, S. Soni (Adobe India), "Dewarping documents using C2
continuous boundary estimation", ICASSP 2023. DOI 10.1109/ICASSP49357.2023.10095307.

**What it does.**

1. A neural network gives a mask of the document boundary (16 convolution layers,
   an encoder and a decoder with skip connections, and a Sobel layer). Training:
   about 15,000 real pictures with hand-drawn outlines and 25,000 synthetic ones.
2. The skeleton of the mask gives a thin outline. Hough lines on each side give a
   first quad. The exact corners are where two successive short Hough lines of the
   outline meet at the sharpest angle.
3. Points at equal distances along each side: divide the straight line between two
   corners, and take the outline point on the perpendicular through each division.
4. Smooth each side with cubic Bézier pieces that join with continuous first and
   second derivatives. For successive outline points `Pk`, `Pk+1`:
   `Bk = (2Pk + Pk+1)/3`, `Ck = (Pk + 2Pk+1)/3`, and the joint `Ak+1` is the middle
   of the two control points next to it.
5. A mesh inside: each mesh point is a blend of the offsets of the four sides
   (`py = ly1 + β·ΔB + (1−β)·ΔU`, `px = ux1 + α·ΔR + (1−α)·ΔL`). Each mesh cell
   gets its own perspective correction.

**Numbers.** On the DocUNet benchmark: MS-SSIM 0.45 and local distortion 10.72
(DocUNet 0.41 / 14.08, DewarpNet 0.47 / 8.95). On their own 200 pictures: 0.46 /
9.23 against 0.40 / 12.64 for DewarpNet. About 200 ms per document.

**For this project.**

- **The paper states that Adobe patented this algorithm** (its reference 2: Mondal,
  Pant, Soni, "Fast and efficient document dewarping in mobile devices using C2
  continuous boundary estimation", U.S. patent, 2022). We do not use it.
- The mesh is a 2D blend of the four sides. It has no depth and no vanishing
  point, so it has the error that He et al. describe for 2D methods.
- The idea to keep: smooth the outline before any use. A raw outline gives waves
  inside the page.

## 3. Kim, Chiu, Chandra 2013: spread dewarp from a phone sweep

C. Kim (UC Santa Cruz), P. Chiu, S. Chandra (FX Palo Alto Laboratory), "Dewarping
book page spreads captured with a mobile phone camera", CBDAR 2013 (LNCS, 2014),
pp. 101-112. DOI 10.1007/978-3-319-05167-3_8.

**What it does.** An iPhone 4S app takes 8 MP frames at 2 frames per second while
the user sweeps the phone across an open book. Points at different depths move by
different amounts between two frames. That gives the shape of the page:

- "Good features to track" points, matched between successive frames.
- Outliers removed with the epipolar constraint (`x2ᵀ F x1 = 0`).
- Optical flow method: the displacement of each point is its disparity. The points
  of each page (the spine was marked by hand) get a surface that is a polynomial
  of order 4. The surface becomes a disparity map.
- Structure from motion method: camera poses from the essential matrix, then
  triangulation. A pair of frames is used only when its points lie near one plane.
- GrabCut finds the document region.
- A cylinder model dewarps the page from the disparity map (their earlier system).
- OCR on several frames: the left and the right page are in focus and complete in
  different frames.

**Numbers.** Optical flow and structure from motion gave the same OCR quality.
Optical flow was much faster. OCR on several frames was much better than on the
middle frame alone.

**For this project.** Our video has the same parallax: the camera moves between
the frames of a spread. The tile shifts of `register.zig` between two frames are a
disparity map. This is a way to measure the page shape where the outline is hidden
(under fingers) or wrong. It is a later step.

## 4. Tariq Dar, Khan 2017: pages from a video without a click

S. Tariq Dar, N. Khan (PUCIT, Lahore), "Click-free, video-based document capture -
methodology and evaluation", ICDAR 2017 workshops (CBDAR), pp. 21-26.
DOI 10.1109/ICDAR.2017.344.

**What it does.** Three steps:

1. **Remove page turns.** The mean of the temporal gradient magnitude of each
   frame is a 1D signal. Chunks of 15 frames (half a second), reduced to 3 frames.
   A chunk is a page turn when the standard deviation of its 3 means is above a
   limit.
2. **Candidate frames.** The middle frame of each still chunk. The chunk is dropped
   when the skin-colour pixels of that frame are above a limit.
3. **Remove duplicates.** SIFT descriptors of two successive candidates: the mean
   of the two match percentages above a limit means the same page. The paper names
   the causes of duplicates: half a page turn and back, and a page that moves by
   air or by its stiffness.

**Data.** 37 videos with 763 page turns, 1920 x 1080, a phone on a mount or in the
hand. Books in 35 videos, loose and stapled A4 sheets in 2. Cases: a hand that
holds the book all the time, turns from left to right, a turn that stops and goes
back, a hand that flattens the page. The paper gives this address for the data and
the ground truth: `http://faculty.pucit.edu.pk/nazarkhan/datasets/pucit_page_turns.zip`.

**Evaluation.** F1 of the page frames, and a soft score that gives part of the
credit to a frame just outside the range that the person marked. Result: F1 0.91,
soft score 0.94.

**For this project.**

- A second benchmark for the page count: 37 videos with the true number of pages.
  The videos have a lower resolution than ours, so they test the timeline and the
  duplicate search, not the page quality.
- Our timeline uses the page corners and the page thumbnails where they use the
  frame difference. Their step 1 needs no page detection, so it also works on a
  desk as bright as the paper. It is a fallback to keep in mind.
- Their duplicate rule compares whole frames with SIFT. Ours registers the
  rectified pages, which also tells two languages of the same layout apart.

## 5. Burie et al. 2015: the SmartDoc competition report

J.-C. Burie, J. Chazalon, M. Coustaty, S. Eskenazi, M. M. Luqman, M. Mehri,
N. Nayef, J.-M. Ogier, S. Prum, M. Rusiñol, "ICDAR2015 competition on smartphone
document capture and OCR (SmartDoc)", ICDAR 2015, pp. 1161-1165.
DOI 10.1109/ICDAR.2015.7333943.

**Challenge 1: the page quad in each video frame.** 30 documents on 5 backgrounds.
The score is the Jaccard index of the quad after perspective correction, averaged
over the frames.

| Rank | Team | Method |
|---|---|---|
| 1 | LRDE (Carlinet, Géraud) | Tree of shapes on L and b* of Lab; an energy selects the shape most like a sheet of paper (fits a quad, has content inside); the quad of the frame before breaks ties |
| 2 | ISPL-CVML (Heo, Koo, Cho) | LSD line segments on a small picture; two horizontal and two vertical segments that minimise a cost of colour and edge features; refined at full size |
| 3 | SmartEngines | LSD segments, a graph of segments, quads with size and angle filters, then a Kalman filter with matches of local descriptors between frames |
| 4 | NetEase | LSD segments grouped into quads |
| 5, 6 | A2iA | Canny in RGB, contours as Bézier curves, quads by squareness |
| 7 | RPPDI-UPE | Hue filter, morphology, Canny, Hough |
| 7 | SEECS-NUST | Canny, then the colour channel with the best contrast, then probabilistic Hough |

Findings of the report:

- Low light is not hard. A light background (near the paper colour) is harder.
- Strong occlusion (a hand on the page) is very hard for all methods.
- Pages with many lines (tables) and magazine pages are harder.

**Challenge 2: OCR of single pictures.** 12,100 pictures with blur, perspective and
light changes. The best two methods used the background colour or the largest
centred region to find the page, then binarised, then ran an OCR engine. Most
methods read pictures with perspective better than pictures without: the authors
suspect the perspective step or the training data.

**For this project.**

- The three best methods of challenge 1 all use the frame before (LRDE, SmartEngines)
  or line segments with a colour cost. None uses a paper mask alone. This is the
  design for the second detector (decision 0004).
- "Light backgrounds are harder" and "occlusion is very hard" match the limits of
  our detector.
- The data of both challenges is public (Zenodo 1230217 and 2572929).

## What changes in the plan

1. **Page curl has a method: He et al. 2013.** The code has it as a curved page map
   (`src/lib/curl.zig`). On the benchmark video it lowers the quality, so it is off
   by default: decision 0012 has the numbers and the reasons.
2. **Do not use the mesh of Mondal et al.** It is patented, and it has no depth.
3. **The PUCIT videos are a second benchmark** for the page count.
4. **Parallax as a later source of the page shape** (Kim et al.).
5. **The second detector** follows the line-segment methods of SmartDoc, with the
   quad of the frame before as a prior.
