# Literature

Source: a research agent, 2026-10-09. The agent checked each entry against Crossref,
Semantic Scholar, OpenAlex, the HAL API, Zenodo, or Google Patents, and the code
licences against the GitHub API.

Marks:

- `read`: the full text was read: the abstract and the passages that the summary
  uses, not each page. For a patent: the description on Google Patents.
- `not read`: the summary comes from the abstract, the title, or a second paper.
- `[K]`: the source was already in the project docs.
- "ideas only": the code has a licence that does not fit MIT, or no licence. Do not
  copy code from it.

Patent status is the estimate of Google Patents, not legal advice.

## Read first

1. **3.3 + 3.4 Brown and Tsoi 2006, Tsoi and Brown 2007**. The plan for page
   curl (a ruled surface between two edge curves) is this method. The 2007 paper
   composites many views in a boundary frame.
2. **4.4 Buades, Haro, Meinhardt-Llopis, IPOL 2015** (with C code). A complete
   multi-photo highlight removal: registration, then a vector median of gradients,
   then a Poisson solve.
3. **4.2 Google US 10,257,485 B2**. The PhotoScan patent.
4. **2.5 Chazalon et al., SmartDoc 2017 Video Capture**. A public benchmark
   for "video to one clean document image", with reflective documents and an MIT
   evaluation tool.
5. **2.3 Kumar, Bala, Ding, Emmett, CVPRW 2013**. The classical handheld
   page-turn and best-frame method, as a paper (93 % of page turns).
6. **5.3 He and Zhang, MSR-TR-2004-91**. Real-time occluder removal with
   16x16 cells and a "cell age"; paper colour from the top 10 % luminance.
7. **6.5 Delbracio and Sapiro 2015**. Fourier burst accumulation: a merge
   rule that keeps, per frequency, the frame with the least blur.
8. **5.1 + 5.2 Google US 7,634,112 and Fujitsu US 9,202,260**. The two
   book-scanner recipes for finger detection and finger fill.
9. **9.1 + 9.3 LDRNet and M-LSD**. Phone-speed learned detectors with MIT
   and Apache-2.0 code and published phone latency.
10. **3.13 UVDoc**. The only dewarp network with MIT code, public weights and
    8M parameters. Its Table 2 gives the sizes of the other networks.

## What this changes for the plan

1. **A PhotoScan patent exists.** US 10,257,485 B2 (4.2) describes the guided
   capture with dots and a reticle and a per-pixel minimum composite. Google Patents
   lists it as active to 2036. Decision 0005 does not use a minimum composite. Get a
   legal check before an Android app copies the guided capture.
2. **Gradient-domain fusion.** Buades et al. (4.4) take a vector median of gradients
   and solve a Poisson equation; Li and Brown (4.5) label gradients that change
   across views as reflection. Inside the patch masks, a Poisson paste (5.4) removes
   the gain match. Test it against the pyramid blend. The median still fails when
   glare covers one place in most frames.
3. **Loss of local contrast is a second glare cue.** The HP and Purdue patent and
   exposure fusion (4.7) give glare a low weight because its contrast is low; Rodin
   and Orlov (4.8) use stroke histograms. The benchmark shows that glare makes ink
   as bright as paper and leaves paper almost unchanged. Add a contrast ratio
   between reference and donors to the brightness rule; exposure drift does not
   change it.
4. **The page-curl plan is published work, and it has a known error.** Brown and
   Tsoi (3.3), Fuji Xerox (3.6) and Adobe (3.9) describe the ruled-surface remap.
   Tsoi and Brown (3.4) show that one-view boundary interpolation leaves depth
   distortion; text stays compressed near the fold. Use a cylinder model with the
   focal length (3.7), or composite many views in the boundary frame (3.4).
5. **Public benchmarks exist.** PUCIT (2.2) gives page-turn truth for 37 videos and
   a classical F1 of 0.91 as a target. SmartDoc 2017 (2.5) gives ground truth,
   reflective documents and an MIT tool for a full-reference MSSIM. SHDocs and RD
   (4.11) can test a single-frame glare mask. BookNet (3.15) announces a real spread
   benchmark.
6. **Finger rules are more exact in the literature.** Wigington (2.1) scores "hand
   covers content" apart from "hand covers page only". Google (5.1) and Fujitsu
   (5.2) fill a finger only on blank margin, with a paper colour model, and flag a
   finger on text. A margin-only fill invents no content. MediaPipe Hands (5.5)
   gives finger positions in 6.6 to 36.9 ms on a Pixel 3.
7. **One homography per frame is a weak test for phone video.** Rolling shutter
   gives an error that changes with the row (8.8), and the two pages are not in one
   plane. Fit a homography mixture or a MeshFlow-type vertex field (8.6), or do the
   test after tile alignment. For the merge, Fourier burst accumulation (6.5) keeps
   detail from frames with blur in different directions.
8. **Phone-speed machine learning is available.** LDRNet (9.1) and M-LSD-tiny (9.3)
   have permissive code and published phone latency; M-LSD segments can feed a quad
   score. For dewarp, only UVDoc (3.13) is small with MIT code and weights, and it
   has no phone number: measure it before a decision. DocTr and DocGeoNet are
   non-commercial; DewarpNet, PaperEdge and DocRes are too large.

## Papers to read next, ranked by value

`paper-notes.md` has the notes on five papers that were read in full after the
search: He et al. 2013 (3.5), Mondal et al. 2023 (3.9), Kim et al. 2013 (3.6),
Tariq Dar and Khan 2017 (2.2), and the SmartDoc 2015 report (1.1).

1. **Kim, Koo, Cho 2015** (3.8). DOI 10.1016/j.patcog.2015.04.026. Text-line
   dewarp.
2. **Chakraborty et al. 2013 and 2018** (2.4). DOI 10.1109/ACPR.2013.24;
   DOI 10.1007/s11042-016-4292-3. Page turns in a video of a book.
3. **Javed, Shafait 2017** (9.2). DOI 10.1109/ICDAR.2017.26. Corner detection with
   a small network.
4. **Meng et al. 2012** and **Cao et al. 2003** (3.7). DOI 10.1109/TPAMI.2011.151;
   DOI 10.1109/ICCV.2003.1238346. The cylinder model with a camera.
5. **Xu et al. 2026, DocHighlight** (4.11). DOI 10.1007/978-981-95-5676-2_8.
6. **Capel, Zisserman 2000; Donaldson, Myers 2005** (6.4).
   DOI 10.1109/ICPR.2000.905409; DOI 10.1109/CVPR.2005.87.
7. Background: Haro et al. 2012; Liu et al. 2013; Szeliski, Coughlan 1997; Hartley
   1997; Chum et al. 2003; Agarwala et al. 2004; Pertuz et al. 2013; Shen, Cai 2009.

## Bibliography

### 1. Page boundary detection and datasets

**1.1** Burie, Chazalon, Coustaty, Eskenazi, Luqman, Mehri, Nayef, Ogier, Prum,
Rusiñol. "ICDAR2015 Competition on Smartphone Document Capture and OCR (SmartDoc)."
ICDAR 2015, pp. 1161-1165. DOI 10.1109/ICDAR.2015.7333943. `read`, see `paper-notes.md`.
Two challenges: page quad in preview video frames (8 submissions) and OCR (5).
Data: Challenge 1 `10.5281/zenodo.1230217`, Challenge 2 `10.5281/zenodo.2572929`
(CC BY 4.0).

**1.2** Nayef, Luqman, Prum, Eskenazi, Chazalon, Ogier. "SmartDoc-QA: A dataset for
quality assessment of smartphone captured document images - single and multiple
distortions." ICDAR 2015, pp. 1231-1235. DOI 10.1109/ICDAR.2015.7333960. Paper
`not read`; dataset at <https://zenodo.org/record/5293201> (CC BY 4.0).
Document photos with blur, light and perspective distortions plus OCR truth. Use:
test of the sharpness score.

**1.3** MIDV series (Smart Engines). Arlazarov, Bulatov, Chernov, Arlazarov.
"MIDV-500." Computer Optics 43(5):818-824, 2019. <https://arxiv.org/pdf/1807.05786>
`read`. Bulatov, Matalov, Arlazarov. "MIDV-2019." ICMV 2019.
<https://arxiv.org/pdf/1910.04009> `not read`. Bulatov et al. "MIDV-2020."
Computer Optics 46(2), 2022. <https://arxiv.org/pdf/2107.00396> `read`.
Phone video clips of identity documents with quad truth per frame.

**1.4 [K]** Zhang, He. "Whiteboard scanning and image enhancement." Digital Signal
Processing 17:414-432, 2007. DOI 10.1016/j.dsp.2006.05.006.
<https://www.microsoft.com/en-us/research/wp-content/uploads/2016/11/Digital-Signal-Processing.pdf>
Quad from Hough lines, aspect ratio and focal length from the quad, white balance
by cells. In use: `geometry.zig`, `enhance.zig`.

**1.5 [K]** Tropin, Ilyuhin, Nikolaev, Arlazarov. "Approach for Document Detection
by Contours and Contrasts." ICPR 2020, pp. 9689-9695. DOI
10.1109/ICPR48806.2021.9413271; <https://arxiv.org/pdf/2008.02615>. Tropin, Ershov,
Nikolaev, Arlazarov. "Advanced Hough-based method for on-device document
localization." Computer Optics 45(5), 2021. DOI 10.18287/2412-6179-CO-895. Both
`not read`. Hough quads with a contour and contrast score. Code
`SmartEngines/hough_document_localization` has no licence: ideas only.

**1.6 [K]** Puybareau, Géraud. "Real-Time Document Detection in Smartphone Videos."
ICIP 2018, pp. 1498-1502. DOI 10.1109/ICIP.2018.8451533.
<https://www.lrde.epita.fr/~theo/papers/geraud.2018.icip.puybareau.pdf>
Lab conversion, morphological closing to remove text, then line detection.

**1.7** von Gioi, Jakubowicz, Morel, Randall. "LSD: A Fast Line Segment Detector
with a False Detection Control." TPAMI 32:722-732, 2010. DOI
10.1109/TPAMI.2008.300 (`not read`). IPOL version:
<https://www.ipol.im/pub/art/2012/gjmr-lsd/article.pdf> `not read`. Licence of
the IPOL code not checked: ideas only.

**1.8 [K]** Dropbox, "Fast and accurate document detection for scanning" (2016),
<https://dropbox.tech/machine-learning/fast-and-accurate-document-detection-for-scanning>.
The Grizzly Labs, "Document detection" (2024),
<https://blog.thegrizzlylabs.com/2024/10/document-detection.html>.

### 2. Video capture, page turns, frame selection, mosaics

**2.1 [K]** Wigington. "Handheld Video Document Scanning: A Robust On-Device Model
for Multi-Page Document Scanning." ACM DocEng 2024. DOI 10.1145/3685650.3685662.
<https://arxiv.org/pdf/2411.00576> `read`.
A small CNN-LSTM finds page changes; a MobileNetV2 at 320x320 scores capture
attributes, with "hand covers content" apart from "hand covers page, not content".
F1 0.94 to 0.97 on PUCIT. Pixel 7 Pro CPU: 557 and 38.7 frames per second. No code,
no weights.

**2.2** Tariq Dar, Khan. "Click-Free, Video-Based Document Capture - Methodology and
Evaluation." ICDAR 2017 workshops (CBDAR), vol. 6, pp. 21-26. DOI
10.1109/ICDAR.2017.344. `read`, see `paper-notes.md`.
Motion-based page-turn detection, skin-colour hand test, middle frame of each
hand-free block, SIFT de-duplication; F1 0.91 (as 2.1 reports). Public PUCIT
dataset of 37 videos.

**2.3** Kumar, Bala, Ding, Emmett. "Mobile Video Capture of Multi-page Documents."
CVPR Workshops 2013, pp. 35-40. DOI 10.1109/CVPRW.2013.10.
<https://openaccess.thecvf.com/content_cvpr_workshops_2013/W03/papers/Kumar_Mobile_Video_Capture_2013_CVPR_paper.pdf>
`read`. Related **[K]** patent: Emmett, Bala, Furst, Fu, US 9,247,136 B2, listed
active.
Frame difference after motion compensation, blobs joined across 6 frames, plus
inertial sensors; a learned quality score selects the frame. 140 of 150 page turns
found.

**2.4** Chakraborty, Roy, Alvarez, Pal. "OCR from Video Stream of Book Flipping."
ACPR 2013. DOI 10.1109/ACPR.2013.24. Chakraborty, Roy, Saini, Alvarez, Pal. "Frame
selection for OCR from video stream of book flipping." Multimedia Tools and
Applications 77:985-1008, 2018. DOI 10.1007/s11042-016-4292-3. Both `not read`.

**2.5** Chazalon, Gomez-Krämer, Burie, Coustaty, Eskenazi, Luqman, Nayef, Rusiñol,
Sidère, Ogier. "SmartDoc 2017 Video Capture: Mobile Document Acquisition in Video
Mode." ICDAR 2017 workshops, vol. 4, pp. 11-16. DOI 10.1109/ICDAR.2017.306.
<https://lre.epita.fr/dload/papers/chazalon.17.icdar-ost.pdf> `read`.
Task: a 15 s video of one document, also reflective ones, gives one restored image.
The tool aligns globally, then by local patches, then computes MSSIM against the
original. Code `smartdoc2017-competition/evaluation_tools` MIT; test sets
CC BY-SA 4.0.

**2.6** Luqman, Gomez-Krämer, Ogier. "Mobile Phone Camera-Based Video Scanning of
Paper Documents." CBDAR 2013 (Springer LNCS, 2014), pp. 164-178. DOI
10.1007/978-3-319-05167-3_13. <https://hal.science/hal-00946625/file/P5.pdf>
`not read`.

**2.7** Liang, DeMenthon, Doermann. "Camera-Based Document Image Mosaicing." ICPR
2006. DOI 10.1109/ICPR.2006.352. "Mosaicing of camera-captured document images."
CVIU 113:572-579, 2009. DOI 10.1016/j.cviu.2008.12.004. "Geometric Rectification of
Camera-Captured Document Images." TPAMI 30:591-605, 2008. DOI
10.1109/TPAMI.2007.70724. All `not read`. The PhD thesis of Liang has the same work:
<https://drum.lib.umd.edu/handle/1903/3659> `not read`.

**2.8** Manohar, Godavarthy, Sankaranarayanan (Amazon). US 9,191,554 B1, "Creating
an electronic book using video-based input." Listed expired.
<https://patents.google.com/patent/US9191554> `read`.
A classifier on motion descriptors finds page turns; exemplar frames per segment;
crop; Lucas-Kanade alignment; a composite. No dewarp, no spread split, no hand step.

**2.9** Kumar, Chen, Doermann. "Sharpness Estimation for Document and Scene Images."
ICPR 2012. `not read`. Related patent **[K]**: Chen, Kumar (Fuji Xerox),
US 9,087,262 B2, listed active. The ΔDoM edge sharpness score.

**2.10** Rusiñol, Chazalon, Ogier. "Combining Focus Measure Operators to Predict OCR
Accuracy in Mobile-Captured Document Images." DAS 2014. DOI 10.1109/DAS.2014.11
`not read`. Pertuz, Puig, García. "Analysis of focus measure operators for
shape-from-focus." Pattern Recognition 46:1415-1432, 2013. `not read`.

### 3. Spread split and dewarp

**3.1** Stamatopoulos, Gatos, Georgiou. "Page frame detection for double page
document images." DAS 2010, pp. 401-408. DOI 10.1145/1815330.1815382. `not read`.

**3.2 [K]** ScanTailor `VertLineFinder.cpp`, `PageLayoutEstimator.cpp`,
`EstimateBackground.cpp`: GPL-3, ideas only. Zucker, "Page dewarping" (2016),
<https://mzucker.github.io/2016/08/15/page-dewarping.html>, code
`mzucker/page_dewarp` MIT.

**3.3** Brown, Tsoi. "Geometric and shading correction for images of printed
materials using boundary." IEEE TIP 15:1544-1554, 2006. DOI 10.1109/TIP.2006.871082.
<https://www.eecs.yorku.ca/~mbrown/pdf/tip_tsoi_2006.pdf> `read`.
The page is a ruled surface between two opposite boundary curves. A Coons patch maps
it to a rectangle. The same interpolation estimates the shading.

**3.4** Tsoi, Brown. "Multi-View Document Rectification using Boundary." CVPR 2007.
DOI 10.1109/CVPR.2007.383251.
<https://www.eecs.yorku.ca/~mbrown/pdf/cvpr07_multiview.pdf> `read`.
Each uncalibrated view of a bound document goes to one frame through its boundary.
A composite of the views removes depth distortion and illumination change.

**3.5** He, Pan, Xie, Sun, Naoi (Fujitsu). "A Book Dewarping System by
Boundary-Based 3D Surface Reconstruction." ICDAR 2013, pp. 403-407. DOI
10.1109/ICDAR.2013.88. `read`, see `paper-notes.md`. In use: `src/lib/curl.zig`.

**3.6** Kim, Chiu, Chandra. "Dewarping Book Page Spreads Captured with a Mobile
Phone Camera." CBDAR 2013, pp. 101-112. DOI 10.1007/978-3-319-05167-3_8.
`read`, see `paper-notes.md`. Related patent: Chiu, Cutter, Kim, Chandra (Fuji Xerox),
US 9,992,471 B2, listed active, <https://patents.google.com/patent/US9992471>.
A phone sweep across a spread. A cylinder-type ruled surface has one cubic profile
on each side of the spine.

**3.7** Meng, Pan, Xiang, Duan, Zheng. "Metric Rectification of Curved Document
Images." TPAMI 34:707-722, 2012. DOI 10.1109/TPAMI.2011.151. Cao, Ding, Liu. "A
cylindrical surface model to rectify the bound document image." ICCV 2003. DOI
10.1109/ICCV.2003.1238346. Both `not read`.

**3.8** Tian, Narasimhan. "Rectification and 3D reconstruction of curved document
images." CVPR 2011. DOI 10.1109/CVPR.2011.5995540.
<http://www.cs.cmu.edu/~ILIM/projects/IM/document_rectification/cvpr2011_YuandongTian.pdf>
`read`. Kim, Koo, Cho. "Document dewarping via text-line based optimization."
Pattern Recognition 48:3600-3614, 2015. `not read`.

**3.9** Mondal, Pant, Soni (Adobe). "Dewarping Documents Using C2 Continuous
Boundary Estimation." ICASSP 2023. DOI 10.1109/ICASSP49357.2023.10095307.
`read`, see `paper-notes.md`. The paper states that Adobe patented the
algorithm: ideas only.

**3.10** Ma, Shu, Bai, Wang, Samaras. "DocUNet." CVPR 2018. DOI
10.1109/CVPR.2018.00494. Das, Ma, Shu, Samaras, Shilkrot. "DewarpNet." ICCV 2019.
DOI 10.1109/ICCV.2019.00022. Both `read`. DewarpNet has 86.9M parameters. Code
`cvlab-stonybrook/DewarpNet` MIT.

**3.11** Xie, Yin, Zhang, Liu. "Document Dewarping with Control Points." ICDAR 2021.
<https://arxiv.org/pdf/2203.10543> `read`. 13.3M parameters. Code MIT.

**3.12** Feng, Wang, Zhou, Deng, Li. "DocTr." ACM MM 2021. Feng, Zhou, Deng, Wang,
Li. "DocGeoNet." ECCV 2022. Both `not read`. 26.9M and 24.8M parameters.
Non-commercial licence: ideas only.

**3.13** Verhoeven, Magne, Sorkine-Hornung. "UVDoc: Neural Grid-based Document
Unwarping." SIGGRAPH Asia 2023. DOI 10.1145/3610548.3618174.
<https://arxiv.org/pdf/2302.02887> `read`. 8M parameters. Code and weights MIT
(`tanguymagne/UVDoc`). No phone latency published.

**3.14** Zhang, Peng, Liu, Zhang, Jin. "DocRes." CVPR 2024.
<https://arxiv.org/pdf/2405.04408> `read`. 15.2M parameters, 183 GFLOPs. Too heavy.

**3.15** Liu, Feng, Luan, Hou, Deng, Zhou. "BookNet: Book Image Rectification via
Cross-Page Attention Network." arXiv 2601.21938, 2026. `not read`.

### 4. Glare and specular highlights

**4.1 [K]** Liu, Rubinstein, Krainin, Freeman. "PhotoScan: Taking Glare-Free
Pictures of Pictures." Google Research blog, 2017.
<https://research.google/blog/photoscan-taking-glare-free-pictures-of-pictures/>.
Freeman, NTIRE 2018 talk.

**4.2** Winn, Lieb, Henry (Google). US 10,257,485 B2, "Generating a composite image
from a physical item." Priority 2016-06-08, granted 2019-04-09, listed active to
2036. <https://patents.google.com/patent/US10257485> `read` (description; the agent
did not read the claims).
Dots and a reticle guide captures from several positions. Registration by
homography or optical flow. Each composite pixel is "a minimum value of the
corresponding pixel values".

**4.3 [K]** Xue, Rubinstein, Liu, Freeman. "A computational approach for
obstruction-free photography." ACM TOG 34(4), 2015. DOI 10.1145/2766940.

**4.4** Haro, Buades, Morel. "Photographing Paintings by Image Fusion." SIAM J.
Imaging Sciences 5:1055-1087, 2012. `not read`. Buades, Haro, Meinhardt-Llopis.
"Obtaining High Quality Photographs of Paintings by Image Fusion." IPOL 5:159-176,
2015. DOI 10.5201/ipol.2015.49. <https://www.ipol.im/pub/art/2015/49/article.pdf>
`read`. Licence of the IPOL code not checked: ideas only.

**4.5** Li, Brown. "Exploiting Reflection Change for Automatic Reflection Removal."
ICCV 2013. DOI 10.1109/ICCV.2013.302. `read`.
After alignment, gradients that change across the views are reflection; constant
gradients are the scene.

**4.6** Shah, Marshall, Murray. "Removal of specular reflections from image
sequences using feature correspondences." Machine Vision and Applications
28:409-420, 2017. DOI 10.1007/s00138-017-0826-6. `read`.
Feature matches and a RANSAC homography between video frames; overlap pixels take
the minimum of two frames.

**4.7** Majewicz, Ha, Allebach (HP, Purdue). US 9,332,156 B2, "Glare and shadow
mitigation by fusing multiple frames." Listed expired. Base method: Mertens, Kautz,
Van Reeth. "Exposure Fusion." Pacific Graphics 2007. DOI 10.1109/PG.2007.17.
Laplacian-pyramid fusion with weights from contrast, saturation and exposure. Glare
gets a low weight because its contrast is low.

**4.8 [K]** Rodin, Orlov. "Fast Glare Detection in Document Images." ICDAR Workshops
2019. DOI 10.1109/ICDARW.2019.60123. <https://arxiv.org/pdf/1911.05189> `read`.
Block luminance and stroke-length histograms feed a CNN with 405,473 weights.

**4.9 [K]** Bocharov, Kostyukov (ABBYY), US 9,418,407 B2, "Detecting glare in a
frame of image data", listed expired. Mayer, Queenan, Martin (MorphoTrust USA),
US 10,586,316 B2, "Reduction of glare in imaging documents", listed active.

**4.10 [K]** Shen, Cai. "Simple and efficient method for specularity removal in an
image." Applied Optics 48:2711, 2009. `not read`. Code collection `vitorsr/SIHR`,
BSD-2-Clause.

**4.11** Document highlight data: Hou et al., "Text-Aware Single Image Specular
Highlight Removal", 2021, <https://arxiv.org/pdf/2108.06881> (RD set, code with no
licence: ideas only). Leong, Koa, Cham, Heng, "SHDocs", NeurIPS 2024 Datasets and
Benchmarks (`JovinLeong/SHDocs` MIT). Pan et al., DocHR14K, arXiv 2504.14238, 2025.
Xu et al., DocHighlight, 2026, `not read`. Use: test data for a single-frame glare
mask. The networks invent content and are heavy.

**4.12** Liu, Lai, Yang, Chuang, Huang. "Learning to See Through Obstructions." CVPR
2020. <https://arxiv.org/pdf/2004.01180> `read`. Too heavy for a phone.

### 5. Fingers and occluders

**5.1** Lefevere, Poncin, Khaliq (Google). US 7,634,112 B1, "Automatic finger
detection in document images." Granted 2009, listed active to 2026-12-11.
<https://patents.google.com/patent/US7634112> `read`.
Narrow HSV skin seeds grow while hue and saturation change slowly; edges stop the
growth. Hand on text: alert and scan again. Hand on white space: extend the white
area across the hand.

**5.2** He, Sun, Naoi (Fujitsu, now PFU). US 9,202,260 B2, "Method and apparatus for
processing scanned image." Listed active.
<https://patents.google.com/patent/US9202260> `read`.
The fill works along lines parallel to the page edge, with a linear colour model
per channel from the margin pixels on both sides.

**5.3** He, Zhang. "Real-Time Whiteboard Capture and Processing Using a Video Camera
for Remote Collaboration." IEEE Trans. Multimedia 9:198-206, 2007.
Report MSR-TR-2004-91:
<https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/tr-2004-91.pdf>
`read`.
16x16 cells; a cell has an age (frames without change). Cells stable for more than
4 frames feed the board model; a person is a short-life cell.

**5.4** Burt, Adelson. "A multiresolution spline with application to image mosaics."
ACM TOG 2:217-236, 1983. DOI 10.1145/245.247. Pérez, Gangnet, Blake. "Poisson image
editing." ACM TOG 22:313-318, 2003. DOI 10.1145/882262.882269. Agarwala et al.
"Interactive digital photomontage." ACM TOG 23:294-302, 2004.

**5.5** Zhang, Bazarevsky, Vakunov, Tkachenka, Sung, Chang, Grundmann. "MediaPipe
Hands: On-device Real-time Hand Tracking." arXiv 2006.10214, 2020. `read`. 1.0M to
4.02M parameters; 6.6 to 36.9 ms on a Pixel 3. Apache-2.0.

**5.6** Google, "ML Kit document scanner",
<https://developers.google.com/ml-kit/vision/doc-scanner>. Closed product; it lists
"image cleaning capabilities (erase stains, fingers, etc.)".

### 6. Multi-frame merge and super-resolution for text

**6.1** Hasinoff, Sharlet, Geiss, Adams, Barron, Kainz, Chen, Levoy. "Burst
photography for high dynamic range and low-light imaging on mobile cameras." ACM
TOG 35(6), 2016. DOI 10.1145/2980179.2980254. <https://hdrplusdata.org/hdrplus.pdf>
`read`. **[K]** Monod, Delon, Veit. "An Analysis and Implementation of the HDR+
Burst Denoising Method." IPOL 11:142-169, 2021. DOI 10.5201/ipol.2021.336. In use:
`register.zig`.

**6.2 [K]** Wronski et al. "Handheld multi-frame super-resolution." ACM TOG 38(4),
2019. Lafenetre, Facciolo, Eboli. "Implementing Handheld Burst Super-Resolution."
IPOL 13:227-257, 2023. It needs raw frames.

**6.3** Farsiu, Robinson, Elad, Milanfar. "Fast and Robust Multiframe Super
Resolution." IEEE TIP 13(10), 2004. DOI 10.1109/TIP.2004.834669.

**6.4** Capel, Zisserman. "Super-resolution enhancement of text image sequences."
ICPR 2000. Donaldson, Myers. "Bayesian Super-Resolution of Text in Video with a
Text-Specific Bimodal Prior." CVPR 2005. Both `not read`.

**6.5** Delbracio, Sapiro. "Burst Deblurring: Removing Camera Shake Through Fourier
Burst Accumulation." CVPR 2015. DOI 10.1109/CVPR.2015.7298852 `read`. "Hand-Held
Video Deblurring Via Efficient Fourier Aggregation." IEEE Trans. Computational
Imaging 1:270-283, 2015. <https://arxiv.org/pdf/1509.05251> `read`.

### 7. Illumination, shadow, shading

**7.1 [K]** Bako, Darabi, Shechtman, Wang, Sunkavalli, Sen. "Removing Shadows from
Images of Documents." ACCV 2016. DOI 10.1007/978-3-319-54187-7_12.

**7.2 [K]** Dropbox, "Fast document rectification and enhancement". ScanTailor
Advanced `EstimateBackground.cpp`, GPL-3: ideas only.

**7.3** Kligler, Katz, Tal. "Document Enhancement Using Visibility Detection." CVPR
2018. `read`. Jung, Hasan, Kim. "Water-Filling: An Efficient Algorithm for Digitized
Document Shadow Removal." ACCV 2018. <https://arxiv.org/pdf/1904.09763> `read`. The
Water-Filling code has no licence: ideas only.

**7.4** Lin, Chen, Chuang. "BEDSR-Net." CVPR 2020. Li, Chen, Pun, Cun.
"High-Resolution Document Shadow Removal via A Large-Scale Real-World Dataset and A
Frequency-Aware Shadow Erasing Net." ICCV 2023. Test data only.

### 8. Registration

**8.1** Fischler, Bolles. "Random sample consensus." CACM 24:381-395, 1981. Hartley.
"In Defense of the Eight-Point Algorithm." TPAMI 19:580-593, 1997. Chum, Matas,
Kittler. "Locally Optimized RANSAC." DAGM 2003. Barath, Noskova, Ivashechkin, Matas.
"MAGSAC++." CVPR 2020. <https://arxiv.org/pdf/1912.05909>.

**8.2** Rublee, Rabaud, Konolige, Bradski. "ORB: An efficient alternative to SIFT or
SURF." ICCV 2011. DOI 10.1109/ICCV.2011.6126544.

**8.3** Evangelidis, Psarakis. "Parametric Image Alignment Using Enhanced Correlation
Coefficient Maximization." TPAMI 30:1858-1865, 2008. DOI 10.1109/TPAMI.2008.113.

**8.4** Baker, Matthews. "Lucas-Kanade 20 Years On: A Unifying Framework." IJCV
56:221-255, 2004. `read`. Sánchez. "The Inverse Compositional Algorithm for
Parametric Registration." IPOL 6:212-232, 2016. `read`. Szeliski, Coughlan.
"Spline-Based Image Registration." IJCV 22:199-218, 1997. `not read`.

**8.5** Zaragoza, Chin, Tran, Brown, Suter. "As-Projective-As-Possible Image
Stitching with Moving DLT." CVPR 2013; TPAMI 36:1285-1298, 2014. `read`.

**8.6** Liu, Yuan, Tan, Sun. "Bundled camera paths for video stabilization." ACM TOG
32(4), 2013. `not read`. Liu, Tan, Yuan, Sun, Zeng. "MeshFlow: Minimum Latency
Online Video Stabilization." ECCV 2016.
<http://www.liushuaicheng.org/eccv2016/meshflow.pdf> `read`.

**8.7** Kroeger, Timofte, Dai, Van Gool. "Fast Optical Flow using Dense Inverse
Search." ECCV 2016. <https://arxiv.org/pdf/1603.03590> `read`. The code
`tikroeger/OF_DIS` is GPL-3: ideas only.

**8.8** Grundmann, Kwatra, Castro, Essa. "Calibration-free rolling shutter removal."
ICCP 2012. DOI 10.1109/ICCPhot.2012.6215213.

### 9. Machine learning at phone speed

**9.1** Wu, Qian, Wu, van Moorsel. "LDRNet: Enabling Real-time Document Localization
on Mobile Devices." ECML PKDD 2022 Workshops. <https://arxiv.org/pdf/2206.02136>
`read`.
MobileNetV2 regresses 4 corners and 100 border points. Jaccard index 0.9849 on
SmartDoc 2015 Challenge 1. It runs on an iPhone 11 inside the 30 frames per second
budget; the largest model is 10 MB. Code MIT (`niuwagege/LDRNet`).

**9.2** Javed, Shafait. "Real-Time Document Localization in Natural Images by
Recursive Application of a CNN." ICDAR 2017. DOI 10.1109/ICDAR.2017.26. `not read`.
Code Apache-2.0 (`kjaved0/recursive-cnns`).

**9.3** Gu, Ko, Go, Lee, Lee, Shin. "Towards Light-weight and Real-time Line Segment
Detection" (M-LSD). AAAI 2022. DOI 10.1609/aaai.v36i1.19953.
<https://arxiv.org/pdf/2106.00186> `read`.
M-LSD-tiny has 0.6M parameters: 17.6 ms on a Snapdragon 865 phone at 320 px. Code
Apache-2.0 (`navervision/mlsd`).

**9.4** Soria, Li, Rouhani, Sappa. "Tiny and Efficient Model for the Edge Detection
Generalization" (TEED). ICCV Workshops 2023. 58K parameters; code MIT. Su et al.
"Pixel Difference Networks for Efficient Edge Detection" (PiDiNet). ICCV 2021.
Research-only licence: ideas only.

**9.5** das Neves Junior et al. "HU-PageScan." IET Image Processing 14:3890-3898,
2020. "A Fast Fully Octave Convolutional Neural Network for Document Image
Segmentation." IJCNN 2020. 8.9M parameters: none for a phone.

**Phone verdict**

- Fits a phone, with published phone numbers: 2.1 Wigington (no weights), 9.1
  LDRNet (MIT), 9.3 M-LSD-tiny (Apache-2.0), 5.5 MediaPipe Hands (Apache-2.0).
- Small, but no phone number; measure first: 3.13 UVDoc (8M, MIT, weights), 3.11
  (13.3M, MIT), 9.4 TEED (58K, MIT), 4.8 glare CNN (405K weights, no code).
- Too heavy or blocked by licence: DewarpNet 86.9M; DocTr 26.9M and DocGeoNet 24.8M
  (non-commercial); PaperEdge 36.6M; DocRes 15.2M and 183 GFLOPs; HU-PageScan 8.9M;
  the DocHR14K network; 4.12; 4.3.
