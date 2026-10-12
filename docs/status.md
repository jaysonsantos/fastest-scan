# Status

Last change: 2026-10-12.

This page is the entry point to resume the work. Change it in each commit that
changes the state.

## Goal

`fastest-scan <video> -o out.pdf` makes a PDF from a phone video of a book, a
booklet, or a document:

- one PDF page per physical page; a two-page spread becomes two pages;
- each page cropped to its edges and without perspective;
- glare (a bright reflection) repaired from other frames of the same page, as
  Google PhotoScan does;
- image quality good enough for a later OCR step.

The benchmark is one video. See `docs/research/benchmark-video.md`. The expected
result is 63 pages.

## What exists

The program makes a complete PDF from the benchmark video. Run it with:

```sh
scripts/build.sh
zig-out/bin/fastest-scan ~/VID_20261009_180010.mp4 -o out/bench.pdf -v \
  --cache-dir .cache --debug-dir .cache/debug
```

Result on 2026-10-12: 63 pages of 1292 x 1868 pixels, 13.1 MB. 63 pages is the
expected count: the cover and 31 spreads, in the order of the booklet. The run
takes about 29 s with a warm frame cache, on a machine that does no other work.
`docs/benchmark-log.md` has the numbers of each step.

Each page comes from its own reference frame: the frame of the spread that shows
the most ink of that page (decision 0013). Up to 9 other frames repair it, 3 of
them frames that cut the page (views from near):

- glare: washed-out text and pictures come back where another frame shows them;
- fingers: the paper under a finger comes back where another frame shows it;
- a page that the reference frame cuts gets its missing part from another frame.

A donor frame repairs a region only when it agrees with the reference around that
region. Among such frames, the region takes the one that is sharp in the region
(decision 0016).

A finger that holds the page in all frames gets the colour of the paper around it
(decision 0014). No page of the benchmark result shows a thumb. Text below a
finger is lost: `--fingers blank` and `--fingers keep` change the rule.

| Part | State |
|---|---|
| Dev shell, build, linters, CI file, release script | Done |
| `geometry.zig`: points, lines, quads, homography, Zhang-He aspect ratio | Done, tested |
| `image.zig`: planes, I420 frames, RGB images | Done, tested |
| `color.zig`: YUV to RGB | Done, tested |
| `jpeg.zig`: baseline encoder with optimised Huffman tables | Done. poppler reads the files. |
| `pdf.zig`: PDF writer with a byte callback | Done, tested. `pdfinfo` reads the file. |
| `raster.zig`: halving, histogram, Otsu, 3x3 morphology, largest region | Done, tested |
| `detect.zig`: paper mask, edge lines, fold of a spread, page quads, clipped edges | Works on stable frames of the benchmark. Tests use synthetic frames. |
| `observe.zig`: page thumbnail, covered cells, frame similarity | Done, tested |
| `timeline.zig`: stable runs of frames, one reference frame per spread | Works, but splits some spreads in two |
| `document.zig`: one page size for all pages | Done, tested |
| `resample.zig`: bicubic sampling, page warp | Done, tested |
| `enhance.zig`: paper colour surface, division, unsharp mask, levels | Done, tested |
| `render.zig`: detect at full size, warp, enhance, JPEG | Done, tested |
| CLI: arguments, `ffprobe`, parallel `ffmpeg` readers, analysis pass, render pass, PDF, frame cache, debug pictures | Done |
| `register.zig`: tile alignment on a pyramid, robust plane transform | Done, tested |
| `dedup.zig`: spreads that register with each other are one spread | Done, tested. Removes the 10 duplicate views of the benchmark. |
| `fuse.zig`: repair of the reference page with donor frames, with a patch check against the reference | Works on the benchmark, with the problems below. Tested with synthetic pages. |
| `finger.zig`: the finger mask of a frame (skin, a wide blob from a border, margin, halo), and the paint over a finger that stays | Works on the benchmark. Tested with synthetic pages. The skin numbers come from one video. |
| `timeline.chooseReference`: the reference frame of each page by the ink that it shows | Done, tested |
| `timeline.selectDonors`: donor frames by what they repair, also frames that cut a page | Done, tested |
| `render.alignDonor`: registration of a donor in rounds | Done. No test for the rounds alone. |
| `prototypes/fusion/`: the Python experiment behind the fusion | A record. See `docs/research/fusion-prototype.md`. |
| `prototypes/fingers/`: the Python experiment behind the finger mask | A record. See decision 0014. |
| `curl.zig`: a page map for a curled page, after He et al. 2013 | Done, tested on synthetic pages. Off by default (`--curl`): it lowers the quality on the benchmark. See decision 0012. |
| C interface | Only `fastscan_version` |

Debug output (`--debug-dir`): `analysis.csv` (one line per frame), `segments.csv`
(one line per spread), `frames/` (every 15th analysis frame with the page quads),
`segments/` (the reference frame of each spread), `pages/` (each page as JPEG),
`faults/` (each page with a tint on the cells where the fusion found a fault:
green for repaired glare, blue for a repaired finger, cyan for a repaired part
outside the frame, red, magenta, and grey for the same faults with no repair,
orange where no donor agreed with the reference, yellow-green for a painted
finger, violet for a finger that stays), `cover/` (each page with a tint where
the reference frame shows a finger, in pink, and where no donor frame shows the
page, in blue), `fusion.csv` (one line per page: the reference frame, its ink,
the donors, and the fault areas), `duplicates.csv`. With `--debug-layers` also
`layers/`: the page of each frame as it goes into the fusion.

## Plan

1. **M1, one frame per page.** Done.
2. **Registration and duplicates.** Done. `duplicates.csv` in the debug directory
   shows each comparison. On the benchmark, two views of one spread match on 42 %
   to 95 % of the textured tiles of a page; two different spreads match on at most
   23 %. The limits are 50 % for the better page and 35 % for the other page.
3. **M2, glare, and M3, fingers and cut pages.** Done in a first form: see "What
   exists" and "Known problems".
4. **Quality of the fusion.** Done in a second form (decision 0013): a reference
   frame per page, frames that cut a page as donors, registration in rounds, and a
   patch check. What is left:
   - A sharpness number of the reference at full size (min of mean Gx² and mean
     Gy²). The ink measure works on the small analysis frames.
   - One shift for a whole region is not enough for a large region on a page that
     bends. Use a shift per part of the region.
   - A finer glare mask: `docs/research/fusion-prototype.md` repairs single words
     that the 8 px cells here do not find.
   - Fingers: done (decision 0014). What is left: skin numbers from more videos,
     and a thin strip of the desk at a page edge.
5. **Speed.** Done in a second form. Decision 0015: a donor frame takes the page
   corners of the first pass, and the warp, the registration, and the flatten
   step have vector code. Decision 0017: each worker keeps its large blocks of
   memory, which brings the system time from 20 s to 8 s. The render pass takes
   about 22 s of the 29 s. What is left:
   - The page warp is about 40 % of the CPU time. The donors need the cubic only
     in the regions that they repair: a cheap warp can give the cell values.
   - **A run with no frame cache takes 142 s**, and 117 s with hardware decode
     (`--ffmpeg /usr/bin/ffmpeg --hwaccel vaapi`). That is the time that a user
     gets; the 29 s are for the work on the program. The decoders use most of it:
     the analysis pass takes 53 s in place of 6 s, the render pass 89 s in place
     of 22 s. The render pass has 210 s of system time: the reader takes each
     full-size frame from the pipe, also the frames between the keyframe and the
     frame that it needs. Next: let `ffmpeg` give only the frames that a job
     needs (the `select` filter).
   - The render pass uses half of the CPU threads: the number of workers is the
     number of decoders. With `--jobs 16` and a warm cache, the run takes 24 s and
     9 GB of memory.
   - Decode each range of frames one time for all of its donors, also with an
     empty cache.
   - A first pass on keyframes only.
6. **M4.**
   - Page curl: the map exists (`curl.zig`), but the page shape from the outline is
     not good enough (decision 0012). Next: the page shape from the parallax between
     frames, or from text lines. Then a benchmark video of a thick book.
   - A second benchmark for the page count: the PUCIT videos (37 videos with page
     turns, see `docs/research/paper-notes.md`, paper 4).
   - Hough or line-segment detector for low-contrast desks, with the quad of the
     frame before as a prior (the best SmartDoc 2015 methods do this).
   - Complete C interface (`c_api.zig` has only the version).
7. `scripts/bench.sh` prints the page count, the time, the size, and OCR numbers.
   Missing: a sharpness number and a glare area number.

## Known problems

- **Glare that stays.** Glare stays where no frame of the spread shows the ink.
  Black header bars keep a gold tint on about 5 pages. Example: the left half of
  the header "SAFETY PRECAUTIONS/WARNINGS" (page 13 of the result).
- **Soft patches.** A repaired region can be a little less sharp than the text
  around it, when the best donor is less sharp than the reference.
- **Text below a finger.** The paint removes a finger that is in all frames, and
  the text below it is lost. A line of text then ends at the place of the finger,
  and the page does not show that a finger was there. On the benchmark this
  cuts the end of a line or a part of a drawing on some pages.
- **The skin rule comes from one video.** Another skin tone or another light can
  need other numbers. Print with the colour of skin and no texture that touches
  the page border counts as a finger.
- **A page that moves.** The page "Vielen Dank" (page 14) lifts from the desk in
  all of its frames: it is skewed and blurred.
- **Curved pages.** A page that lifts from the desk gets curved text lines. The
  curl correction (`--curl`) does not help on this video: decision 0012.
- **Bottom edge under fingers.** When fingers cover most of the bottom edge of a
  page, the bottom line of that page is too high.
- A thin line of the desk shows at some page edges: the finger rule takes only
  wide blobs.
- The unsharp mask makes the compression noise of the video visible.


## Open questions

None.
