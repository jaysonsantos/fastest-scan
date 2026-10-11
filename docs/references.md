# References and credits

This page lists every paper, standard, and program whose ideas the project uses.
The code names its source next to each algorithm. This page is the complete list.
`references.bib` has the same sources as BibTeX.

Rules:

- Add the source here in the same commit that adds the algorithm.
- Name the authors, the title, the place of publication, and the year.
- Take ideas, not code, from a program whose license does not fit the MIT license of
  this repository. Say so in the entry.

## Used in the code

| Source | Where | What |
|---|---|---|
| Z. Zhang and L.-W. He, "Whiteboard scanning and image enhancement", Digital Signal Processing 17(2), 2007, pp. 414-432 | `src/lib/geometry.zig`, `rectangleAspect` | The aspect ratio of a rectangle from its perspective view, with an unknown focal length |
| Y. He, P. Pan, S. Xie, J. Sun, and S. Naoi, "A book dewarping system by boundary-based 3D surface reconstruction", ICDAR 2013, pp. 403-407 | `src/lib/curl.zig` | The model of a curled page: straight side edges, curved top and bottom edges, parallel columns that meet at the vanishing point of the side edges, and the column lengths as the source of the page shape. The metric part here uses a pinhole camera in place of the two short formulas of the paper. The feature is off by default (`--curl`). |
| R. Hartley, "In defense of the eight-point algorithm", IEEE TPAMI 19(6), 1997 | `src/lib/geometry.zig`, `Homography.fit` | Normalization of the points before a linear solve |
| R. Hartley and A. Zisserman, "Multiple View Geometry in Computer Vision", 2nd edition, Cambridge University Press, 2004 | `src/lib/geometry.zig`, `Homography.fit` | The direct linear transform for a homography |
| N. Otsu, "A threshold selection method from gray-level histograms", IEEE Transactions on Systems, Man, and Cybernetics 9(1), 1979 | `src/lib/raster.zig`, `otsu` | The threshold between paper and background |
| A. M. Andrew, "Another efficient algorithm for convex hulls in two dimensions", Information Processing Letters 9(5), 1979 | `src/lib/detect.zig`, `convexHull` | The monotone chain convex hull |
| H. Freeman and R. Shapira, "Determining the minimum-area encasing rectangle for an arbitrary closed curve", Communications of the ACM 18(7), 1975 | `src/lib/detect.zig`, `paperFrame` | The smallest rectangle around the paper has a side on a hull edge |
| M. A. Fischler and R. C. Bolles, "Random sample consensus: a paradigm for model fitting with applications to image analysis and automated cartography", Communications of the ACM 24(6), 1981 | `src/lib/detect.zig`, `fitEdge` | Hypothesise a line from two points, then count the points that agree |
| E. Catmull and R. Rom, "A class of local interpolating splines", in Computer Aided Geometric Design, Academic Press, 1974 | `src/lib/resample.zig`, `catmullRomWeights` | The cubic for the page warp |
| Z. Zhang and L.-W. He, "Whiteboard scanning and image enhancement" (see above), section 4 | `src/lib/enhance.zig` | The paper colour of a cell is the mean of its brightest pixels; the page divided by a smooth paper surface has white paper |
| S. W. Hasinoff, D. Sharlet, R. Geiss, A. Adams, J. T. Barron, F. Kainz, J. Chen, and M. Levoy, "Burst photography for high dynamic range and low-light imaging on mobile cameras", ACM Transactions on Graphics 35(6), 2016 | `src/lib/register.zig`, `src/lib/timeline.zig` (`chooseReference`), `src/lib/fuse.zig` (patch check) | Tile alignment on a pyramid: the result of a coarse level starts the next level, and the neighbour tiles give extra start candidates. Two ideas for the fusion: the reference is the best frame of the burst, and another frame is used only where it agrees with the reference. The measures in the code are its own (decision 0013). |
| A. Monod, J. Delon, and T. Veit, "An analysis and implementation of the HDR+ burst denoising method", Image Processing On Line 11, 2021 | `src/lib/register.zig` | The details of that alignment |
| C. Liu, M. Rubinstein, M. Krainin, and B. Freeman, "PhotoScan: Taking Glare-Free Pictures of Pictures", Google Research blog, 2017, <https://research.google/blog/photoscan-taking-glare-free-pictures-of-pictures/> | `src/lib/fuse.zig`, `src/lib/register.zig` | Glare is an outlier among registered frames of one subject, and the dark frames show the true content; a plane transform plus a coarse grid of shifts registers the frames. The fusion here keeps one reference frame and patches it; PhotoScan computes a soft minimum of all frames. |
| L.-W. He and Z. Zhang, "Real-time whiteboard capture and processing using a video camera for remote collaboration", IEEE Transactions on Multimedia 9(1), 2007 (report MSR-TR-2004-91) | `src/lib/fuse.zig` | The comparison of frames works on cells, and a thing in front of the page is what differs from the stable content of a cell |
| J. Kovač, P. Peer, and F. Solina, "Human skin colour clustering for face detection", EUROCON 2003 - Computer as a Tool, IEEE, vol. 2, 2003, pp. 144-148 | `src/lib/finger.zig`, `isSkin` | A pixel is skin when red is above green and above blue by fixed margins. The margins here are other values: they are for a flattened page with white paper at 1.0, and they come from the benchmark video (decision 0014). |
| J. M. Tenenbaum, "Accommodation in computer vision", PhD thesis, Stanford University, 1970, and E. Krotkov, "Focusing", International Journal of Computer Vision 1(3), 1987, pp. 223-237 | `src/lib/fuse.zig`, `innerSharpness` | The sum of squared gradients as a measure of focus (the Tenengrad measure). The code compares the donor frames of one region with it; it uses plain differences of neighbour pixels and the smaller one of the two directions (decision 0016). |
| V. Chvátal, "A greedy heuristic for the set-covering problem", Mathematics of Operations Research 4(3), 1979 | `src/lib/timeline.zig`, `selectDonors` | Each new donor frame is the one that repairs the most cells that still have too few donors |
| ITU-T Recommendation T.81, "Digital compression and coding of continuous-tone still images", 1992 | `src/lib/jpeg.zig` | The JPEG format, the example quantization tables (Annex K.1), the Huffman table procedure (Annex K.2) |
| Y. Arai, T. Agui, and M. Nakajima, "A fast DCT-SQ scheme for images", Transactions of the IEICE E71(11), 1988 | `src/lib/jpeg.zig`, `forwardDct` | The fast forward DCT |
| Independent JPEG Group, libjpeg (T. G. Lane and others), IJG license | `src/lib/jpeg.zig` | The float form of the fast DCT (`jfdctflt.c`), the quality scale (`jcparam.c`), the order of the Huffman table steps (`jchuff.c`). The code here is written new in Zig. This software is based in part on the work of the Independent JPEG Group. |
| E. Hamilton, "JPEG File Interchange Format, version 1.02", C-Cube Microsystems, 1992 | `src/lib/jpeg.zig` | The JFIF header and the YCbCr conversion |
| ISO 32000-1:2008, "Document management - Portable document format - Part 1: PDF 1.7" | `src/lib/pdf.zig` | The PDF file structure |
| ITU-R Recommendations BT.709 and BT.601 | `src/lib/color.zig` | The YUV to RGB matrices and code ranges |
| FFmpeg, <https://ffmpeg.org>, LGPL/GPL | `src/cli/ffmpeg.zig` | The CLI starts the `ffmpeg` and `ffprobe` programs. No FFmpeg code is in this repository. |

## Ideas without code

These sources shaped a design. The project uses none of their code.

| Source | Idea |
|---|---|
| ScanTailor by J. Artsimovich, GPL-3, <https://github.com/scantailor/scantailor> | A spread splits at a near-vertical line near its middle (`filters/page_split`). The fold search in `src/lib/detect.zig` has its own response and search. Also: a polynomial surface as the paper background, with dark cells rejected (`EstimateBackground`), in `src/lib/enhance.zig`. |

## Patents to know

The project uses none of these. A person must check them before a product copies
the feature that each one describes. The status is the estimate of Google Patents.

| Patent | What it describes |
|---|---|
| Winn, Lieb, Henry (Google), US 10,257,485 B2, active | Guided capture of a physical item from several positions with dots and a reticle, and a composite where each pixel is the minimum of the registered captures (PhotoScan). The fusion here keeps one reference frame and patches it; it has no guided capture. |
| Lefevere, Poncin, Khaliq (Google), US 7,634,112 B1, active to 2026-12-11 | Finger detection in book scans from skin-colour seeds, and a fill of fingers on white space |
| He, Sun, Naoi (Fujitsu), US 9,202,260 B2, active | A fill of a finger region along lines parallel to the page edge |
| Mayer, Queenan, Martin (MorphoTrust USA), US 10,586,316 B2, active | Glare-free pixels of an aligned second capture replace the glare area |
| Emmett, Bala, Furst, Fu (Xerox), US 9,247,136 B2, active | Automatic capture from video analysis |
| Chen, Kumar (Fuji Xerox), US 9,087,262 B2, active | The ΔDoM sharpness score |
| Chiu, Cutter, Kim, Chandra (Fuji Xerox), US 9,992,471 B2, active | Dewarped book images from a phone sweep |

## Planned

A later second page detector and the page-curl correction will use the sources in
`docs/research/`. Each source moves into the first table when its algorithm
enters the code. `docs/research/literature.md` holds the checked bibliography, with
the licence of each code base.
