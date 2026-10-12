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
takes 92 s. With all frames in a cache (`--cache-dir`), it takes 28 s: that is the
time for the work on the program. The two times are for a machine that does no
other work. `docs/benchmark-log.md` has the numbers of each step.

The program has a second flow, `--stream`: it reads the video one time, in order,
with no frame cache, and keeps only a few full-size frames of each spread. This
is the flow of the Android app (decision 0019). On the benchmark video it gives
the 63 pages, with the OCR numbers of the two passes, in 145 s to 178 s. At most
38 full-size frames are in memory at one time.

```sh
zig-out/bin/fastest-scan ~/VID_20261009_180010.mp4 -o out/stream.pdf -v --stream
```

The Android app in `android/` scans a recorded video on a phone (a REDMI Note 15
Pro+ 5G) and on the Android emulator. On the phone, the benchmark video of 180 s
gives the 63 pages in 151 s, with 29 ms for each frame, and the app holds at most
1.1 GB of native memory. **No real book was scanned with the camera.** Read
`docs/android.md`.

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
(decision 0014). No page of the benchmark result shows a thumb or the tip of a
thumb. One page keeps a dark mark of 3 pixels at its bottom edge, and one a
faint line (decisions 0022 and 0025). Text below a
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
| `detect.zig`: the outline search for a book on a surface as bright as its pages (decision 0024) | Works on one phone video of a bright room: the pages of the PDF are pages of the book. The benchmark keeps the same bytes. Not for a page that runs out of the frame. |
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
| `finger.zig`: the finger mask of a frame (skin, a wide blob from a border, margin, halo), and the paint over a finger that stays | Works on the benchmark. Tested with synthetic pages. The skin numbers come from the benchmark and from the hands of six public videos (decision 0018). The sizes follow the page width (decision 0021). Skin in the light can be a thin blob (decision 0022). |
| `timeline.chooseReference`: the reference frame of each page by the ink that it shows | Done, tested |
| `timeline.selectDonors`: donor frames by what they repair, also frames that cut a page | Done, tested |
| `render.alignDonor`: registration of a donor in rounds | Done. No test for the rounds alone. |
| `prototypes/fusion/`: the Python experiment behind the fusion | A record. See `docs/research/fusion-prototype.md`. |
| `prototypes/fingers/`: the Python experiment behind the finger mask | A record. See decision 0014. |
| `curl.zig`: a page map for a curled page, after He et al. 2013 | Done, tested on synthetic pages. Off by default (`--curl`): it lowers the quality on the benchmark. See decision 0012. |
| `timeline.Tracker`, `dedup.Resolver`: the timeline and the duplicate search for frames and spreads that come one by one | Done, tested. `timeline.build` and `dedup.resolve` are loops over them: the PDF of the two passes has the same bytes as before. |
| `intake.zig`: a frame of a phone (row strides, U and V in turn, on its side) as a frame of the library; the small frame for the analysis | Done, tested |
| `stream.zig`: the stream session: frames in order, a few frames in memory, a job for each spread | Works on the benchmark: 63 pages. Tested with synthetic videos. No frames from the time before a spread: decision 0019. |
| CLI `--stream`: the stream session on a desktop, one pass with no frame cache | Done |
| C interface (`include/fastscan.h`): the stream session | Done. `tests/c_api.c` uses the header only; `zig build test` runs it. |
| JNI layer (`android/app/src/main/cpp/fastscan_jni.c`) and the Java class `Native` | Done. `scripts/test-jni.sh` runs them on the Java machine of the desktop. |
| `zig build android`: the library for `arm64-v8a` and `x86_64` | Done. The JNI libraries need `-Dandroid-ndk`; the Android shell of the flake has the NDK. The `x86_64` library runs on the emulator, and the `arm64-v8a` library on a phone. |
| Android app (`android/`): camera source, video source, one screen, PDF export | Builds. The video source gives the 63 pages of the benchmark on a phone and on the emulator. On the emulator, the PDF export works, and the camera source gives its frames to the library. **No scan of a real book with the camera.** |
| `scripts/test-android.sh`: the tests on a phone or an emulator | Done, run on a phone and on the emulator. Not in CI: the Android SDK has a licence. |

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
   - Fingers: done (decisions 0014, 0018, 0021, 0022, and 0025). What is left:
     a video of the user in other light, a strip of the desk in a shadow at a
     page edge, and the edge of a finger of a donor frame at the page border
     (one dark mark on the benchmark).
5. **Speed.** Done in a third form. Decision 0015: a donor frame takes the page
   corners of the first pass, and the warp, the registration, and the flatten
   step have vector code. Decision 0017: each worker keeps its large blocks of
   memory. Decision 0020: a decoder has one thread and gives only the frames
   that a job needs, which brings a run with no frame cache from 136 s to 92 s
   (83 s with `--ffmpeg /usr/bin/ffmpeg --hwaccel vaapi`).
   Of the 92 s, the analysis pass takes 41 s and the render pass 51 s. With all
   frames in a cache, the two take 5 s and 23 s. What is left:
   - The decode is the largest part. The analysis pass must decode each frame
     (377 s of CPU time): the frames of this video are all reference frames, and
     the hardware decoder is not faster than the CPU threads. The render pass
     decodes 2622 frames for the 425 that it needs. A decoder cost in the donor
     choice saves 1 % of the run: decision 0023 has the numbers. Ideas: hardware
     and CPU decoders at the same time, or one pass over the video (the stream
     session of the branch `android-app`).
   - The page warp is about 40 % of the CPU time of the program itself. The
     donors need the cubic only in the regions that they repair: a cheap warp can
     give the cell values.
   - The render pass uses half of the CPU threads for its own work. With
     `--jobs 16` and a warm cache, the run takes 24 s and 9 GB of memory.
6. **M4.**
   - Page curl: the map exists (`curl.zig`), but the page shape from the outline is
     not good enough (decision 0012). Next: the page shape from the parallax between
     frames, or from text lines. Then a benchmark video of a thick book.
   - A second benchmark for the page count: the PUCIT videos (37 videos with page
     turns, see `docs/research/paper-notes.md`, paper 4). The program runs on
     them, and the page count is wrong on most: for example 7 pages where the
     true number of page views is 17. The desk is bright, the videos have 480 x
     270 pixels, and many books lie in a second direction. Decision 0018 has the
     commands to get the videos.
   - Hough or line-segment detector for low-contrast desks, with the quad of the
     frame before as a prior (the best SmartDoc 2015 methods do this).
7. `scripts/bench.sh` prints the page count, the time, the size, and OCR numbers.
   Missing: a sharpness number and a glare area number.
8. **The code against the conventions of the Zig standard library.** A check on
   2026-10-12 found three gaps, which are closed: memory that stayed when an
   allocation failed in `fuse.zig` and `render.zig`, errors that the CLI
   dropped or gave one name, and 15 uses of deprecated std names. What is left,
   all small:
   - The standard library puts the allocator before `io` in a parameter list.
     11 functions of the CLI have the other order (ziglint rule Z023).
   - One `FrameObservation` has about 14 kB, which is 72 MB for the benchmark
     video. The two ink maps are most of it, and only the donor choice and the
     reference choice read them. Measure the timeline step before a change.
   - Frame, segment, and candidate indexes are all `u32`: the compiler cannot
     find a mix-up. An `enum(u32)` for each kind can.
   - No list reserves its capacity, and `pdf.Writer` keeps its allocator.
   - The tests that make each allocation fail (`alloc_check.eachFailure`)
     cover the entry points that the CLI calls. They found no more memory that
     stays. `detect.zig` has such a test for the outline search only: the tests
     of `observe.zig` and `render.zig` run the other parts of it.
9. **The Android app** (decision 0019, `docs/android.md`). The app scans a
   recorded video on a phone. What is left, in this order:
   - Scan a real book with the camera of the phone. Check the frame size and the
     frame rate that CameraX gives, the colours, and the page outline on the
     preview.
   - Bring the memory down: 1.1 GB of native memory on the phone is much. Run
     `scripts/test-android.sh` with smaller settings (`ScanOptions`: fewer donor
     frames, one render thread, a smaller page), and compare the pages.
   - Add the stream mode to `scripts/bench.sh` and to CI.
   - Export `Stream.analyze` and `Stream.pushObserved` in the C interface, so
     that a recorded video is analysed on more than one thread.
   - Make a spread final before the next spread ends, so that its pages come
     earlier.
   - Keep some frames from the time before a spread starts, as donor frames.

## Known problems

- **A bright surface around the book, and a page that runs out of the frame.**
  The outline search of decision 0024 finds a book on a bright surface only when
  the whole book is inside the frame. When a page runs out of the frame there,
  the detector takes the bright surface for the paper, as before that decision.
- **Fast page turns with the hands on the book lose spreads.** In the phone
  video of 2026-10-12 (a paperback on a light grey floor, 49 seconds, 1920 x
  1080), the result has 7 pages: the cover and three spreads. The video shows
  more spreads. The timeline wants a stable view of 0.3 seconds with at most a
  quarter of a page covered, and the user gave it only for some spreads.
- **A small book in a 1920 x 1080 frame gives small pages.** In that video a page
  is about 350 pixels wide. The benchmark has 3840 x 2160 pixels and a page of
  1292 pixels.
- **Glare that stays.** Glare stays where no frame of the spread shows the ink.
  Black header bars keep a gold tint on about 5 pages. Example: the left half of
  the header "SAFETY PRECAUTIONS/WARNINGS" (page 13 of the result).
- **Soft patches.** A repaired region can be a little less sharp than the text
  around it, when the best donor is less sharp than the reference.
- **Text below a finger.** The paint removes a finger that is in all frames, and
  the text below it is lost. A line of text then ends at the place of the finger,
  and the page does not show that a finger was there. On the benchmark this
  cuts the end of a line or a part of a drawing on some pages.
- **The skin rule comes from few hands.** Its numbers are from the benchmark and
  from six public videos with darker hands (decision 0018). No video has a very
  pale or a very dark skin tone. Print with the colour of skin and no texture
  that touches the page border counts as a finger.
- **A whole hand on a page stays.** A finger mask larger than 15 % of the page is
  not painted.
- **The count of the fingers that stay has only the fingers that the mask
  finds.** A check of a new video needs a look at the pages.
- **A copy of the benchmark at 1920 x 1080 gives 64 pages**, one duplicate spread
  more than at the full size.
- **A page that moves.** The page "Vielen Dank" (page 14) lifts from the desk in
  all of its frames: it is skewed and blurred.
- **Curved pages.** A page that lifts from the desk gets curved text lines. The
  curl correction (`--curl`) does not help on this video: decision 0012.
- **Bottom edge under fingers.** When fingers cover most of the bottom edge of a
  page, the bottom line of that page is too high.
- A thin line of the desk in a shadow shows at some page edges: a thin blob is a
  finger only when it is in the light.
- The unsharp mask makes the compression noise of the video visible.
- **Stream mode: the pages of a spread come one spread late.** A spread is final
  only when the next spread ends.
- **Stream mode: the page size comes from the first two spreads.** On the
  benchmark it is 1442 x 2025 pixels; the two passes give 1292 x 1868.
- **Stream mode: a later copy of a spread gives no frames to the first copy.**
  The better copy stays with its own frames.
- **Stream mode: the memory is high for a phone.** On the desktop, with frames of
  3840 x 2160 pixels, the process holds 1.4 GB with two render threads, 1.2 GB
  with a limit of 24 frames, and 0.7 GB with one render thread, a limit of 16
  frames, and worse pages. The app holds 1.1 GB on the phone and 0.8 GB on the
  emulator. Decision 0019 has the tables.
- **The app has one screen and no settings.** The user cannot change the page
  layout, the finger rule, or the quality. The screen is fixed to the upright
  position, and a scan stops when the app goes to the background.


## Open questions

For the owner of the repository:

- **The name of the app package.** The code has `br.com.jayson.fastestscan`. A
  change is cheap before the first release and not after it.
- **The lowest Android version.** The code has Android 8.0 (API 26).
