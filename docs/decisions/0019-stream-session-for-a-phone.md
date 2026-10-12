# 0019: A stream session for a phone: each frame one time, pages while the video runs

Date: 2026-10-12. Status: accepted for the library, the C interface, and the JNI
layer. The Android app is written and is not built yet: see "What is not verified".

This record adds a second flow to the library. The two passes of decision 0002
stay the flow of the command-line program.

## Context

The owner of the repository wants an Android app that records a video and starts
to capture the images for the PDF in real time, and that also takes a recorded
video.

The flow of decision 0002 does not fit a phone:

- It reads the video two times, and the second time it jumps to frames. A camera
  gives each frame one time.
- A decoder of a phone is fast when it runs through the file in order. A jump
  costs the decode of all frames from the keyframe before. On a desktop, the run
  with no frame cache takes 142 s, and 29 s when the frames are in a cache: the
  decoders use most of the time.
- The second pass plans with the observations of all frames. So no page exists
  before the end of the video.
- The run holds 4.7 GB with 8 workers, and 590 MB for each worker (decision 0017).

Decision 0002 said: "A live camera mode needs a different flow (one pass with a
frame buffer). It is not part of this decision."

## Decision

### One flow for the two sources: the stream session

`src/lib/stream.zig` has the stream session. The frames go in one time, in the
order of the video, at their full size. The pages come out while the video runs.

The camera and a recorded video use the same flow. For a recorded video, the
decoder of the phone runs one time through the file and gives each frame to the
session. So the app has one path to the library, and the decoder never jumps.

The session never goes back to a frame. It keeps a copy of the few full-size
frames that a spread can need, and drops each other frame.

### What runs at which time

| Step | When | Thread |
|---|---|---|
| The small frame for the analysis (a box filter), and its observation | Each frame | The thread of the source |
| The timeline: is a spread in view, did it end | Each frame | The thread of the source |
| The choice of the frames of a spread: reference frames and donor frames | After each 8 new frames of a spread, and at its end | The thread of the source |
| The page size of the document | When two spreads are known | The thread of the source |
| The duplicate search: a small picture of the spread | When the spread is final | The thread of the source |
| The render of the pages of a spread: warp, registration, fusion, JPEG | When the spread is final and no copy | A render thread of the caller |
| The PDF | At a time of the caller's choice, from the pages that are complete | The thread of the caller |

"Real time" has this meaning here:

- The app knows after each frame where the pages are, if the view is steady, and
  if the view is long enough for a spread. The app draws the page outline on the
  preview and tells the user when to turn the page.
- A spread is final when the next spread ends, not earlier: a run of stable frames
  after a short break can show the same spread again, and then it joins the spread
  before it (the rule of `timeline.build`). So the pages of a spread are complete
  about one spread after the user left it.
- The last spreads become final at the end of the video.

### The same rules as the two passes, one frame at a time

- `timeline.Tracker` is the timeline for frames that come one by one.
  `timeline.build` is now a loop over the tracker, so the two flows find the same
  spreads from the same observations.
- `dedup.Resolver` is the duplicate search for spreads that come one by one.
  `dedup.resolve` is now a loop over the resolver.
- The session makes the choice of `timeline.chooseReference` and
  `timeline.selectDonors` again and again while a spread is in view. The option
  `allowed` limits the result to the frames that the session still holds. The
  dark level of each cell still comes from the observations of all frames of the
  spread: an observation is small, so the session keeps all of them for the
  spreads that are open.
- After each choice, the session drops the frames that the choice does not take.
- `intake.zig` brings a frame of a phone into the form of the library: a copy out
  of the row strides, the two layouts of the chroma samples (planar, and U and V
  in turn), the small frame for the analysis, and the turn to the upright view.
  The analysis works on the upright small frame. A full-size frame stays as the
  source gave it, and the render job turns only the frames that it uses.

### The frames in memory

A frame of 3840 x 2160 pixels is 12 MB. The session holds these frames:

- For each of the two open spreads (the spread in view, and the spread before it
  that can still change): the first choice of the timeline, one reference frame
  for each page, the donor frames, and the frames that came after the last choice
  (8 at most, and the last frame).
- The first spread, until the page size is known.
- The frames of each job, until the caller gives the job back.

The donor frames are the knob: `Options.donor` is for one spread, and two pages
with different reference frames share it. The default is 4 frames and 2 views
from near. `Options.max_held_frames` is a limit for all the frames in memory. At
the limit, the session makes its choice after each 2 new frames, not after 8, and
a spread gets fewer donor frames, down to none. A job that waits for a render
thread counts for the limit: on a slow phone, the next spreads get fewer donor
frames while the render is behind.

### The render is a job

A spread that is final becomes a `stream.Job`. The job owns its frames. The
caller runs `Job.run` on a thread of its choice and gives the job back. The
library has no threads and no lock: the caller owns them, as decision 0001 says.

### The C interface

`include/fastscan.h` exports the stream session: options, `push` with a frame and
its time, `finish`, `take_job`, `job_run`, `complete_job`, the pages as JPEG
bytes, and the PDF through a write function. A worker (`fastscan_worker`) is the
working memory of one thread: a `memory.BlockCache`.

The header has no function for the two passes. An app that wants them needs
random access to the frames, and no user of the C interface has that today.

`tests/c_api.c` is a C program that uses the header only. `zig build test` builds
and runs it, so the header and `c_api.zig` cannot go apart.

### The JNI layer and the app

- `android/app/src/main/cpp/fastscan_jni.c` is the JNI layer: one native function
  for each C function. It checks the size of each buffer against the frame size
  before the library reads it.
- `zig build android -Dandroid-ndk=<NDK>` makes `libfastscan_jni.so` for
  `arm64-v8a` and `x86_64`: the C interface and the JNI layer in one library. Zig
  has no C library for Android, so the link step needs the NDK. With no NDK, the
  step makes only the static libraries: the check that the code compiles for the
  two targets.
- The Java class `Native` declares the native functions. It is Java, not Kotlin,
  so that `scripts/test-jni.sh` can compile it with a JDK and run the JNI layer
  on the Java machine of a desktop, with no Android tool.
- The app is in `android/`, in Kotlin. The camera source uses CameraX with two
  streams: the preview, and YUV frames at the record size. It writes no video
  file. The video source uses `MediaExtractor` and `MediaCodec` with buffers as
  the output, so the native code reads each frame with no copy.

`docs/android.md` has the commands and the layout of the app.

## Measurements

The benchmark video on the desktop, in one pass with no frame cache
(`fastest-scan --stream`), on 2026-10-12. The machine did no other work.

| | Two passes | Stream, 4 + 2 donors | Stream, 2 + 1 donors | Stream, no donors |
|---|---|---|---|---|
| Pages (expected 63) | 63 | 63 | 63 | 63 |
| Spreads of the timeline, and copies | 42, 10 copies | 43, 11 copies | 43, 11 copies | 43, 11 copies |
| Page size in pixels | 1292 x 1868 | 1442 x 2025 | 1442 x 2025 | 1442 x 2025 |
| OCR on all pages: good words | 2281 | 2317 | 2320 | 2195 |
| OCR on all pages: mean confidence | 76.1 | 76.4 | 76.6 | 75.2 |
| Full-size frames in memory, at most | the frames of the jobs in work | 38 | 29 | 20 |

The OCR numbers have the rule of `scripts/bench.sh`, on all 63 pages.

The memory of the process, without the `ffmpeg` process (the line `VmHWM` of
`/proc/self/status`). One full-size frame is 11.9 MB.

| Run | Full-size frames, at most | Memory of the process | OCR good words |
|---|---|---|---|
| Two passes, 2 workers, warm frame cache | the frames of 2 jobs | 1392 MB | 2281 |
| Stream, 4 + 2 donors, 2 render threads | 38 (451 MB) | 1370 MB to 1415 MB | 2317 |
| Stream, 4 + 2 donors, limit of 24 frames, 2 render threads | 26 (308 MB) | 1206 MB to 1235 MB | 2323 |
| Stream, 2 + 1 donors, limit of 16 frames, 1 render thread | 19 (225 MB) | 694 MB | 2217 |
| Stream, no donors, 2 render threads | 20 (237 MB) | 627 MB | 2195 |

A stream run takes 145 s to 178 s on the desktop, with the load of the machine.
The two passes take 92 s with no frame cache, after decision 0020.

The rows with 2 + 1 donors, with no donors, and with the limit of 16 frames are
from the code before decision 0021 (the sizes of the finger rule). The change of
that decision moves the good words of a stream run by 3.

- The stream session finds the 63 pages. The OCR numbers are the same as for the
  two passes, within the noise of the measure (decision 0016 has the size of that
  noise). The pages look the same.
- The donor frames are necessary: with none, about 120 good words are lost.
- Two donor frames and one view from near give the OCR numbers of four and two on
  this video.
- A limit of 24 frames keeps the OCR numbers and takes about 200 MB off. A limit of 16
  frames leaves about one donor frame for a page: the OCR numbers go most of the
  way to the numbers with no donors.
- About two thirds of the memory is not frames: it is the working memory of the
  render threads. A `memory.BlockCache` keeps each large block for the next job
  (decision 0017). A caller with little memory gives the blocks back after a job
  (`fastscan_worker_release_memory`), and pays with page faults.
- The timeline finds one spread more than the two passes, and the duplicate search
  removes it. The cause is the small frame: the box filter of the library and the
  area filter of `ffmpeg` do not round in the same way.
- The page size comes from the first two spreads. It is 8 % higher than the page
  size of the two passes, which comes from all spreads.
- The session needs 14 ms to 17 ms for a frame on one thread of the desktop: the
  small frame, the observation, the copy of the frame, and the choice. That is
  70 s to 85 s of the 145 s to 178 s of a run. `ffmpeg` uses the other time: the
  stream mode has one decoder, which gives each frame at its full size.

## What the stream session does not do

- A donor frame never comes from the time before the stable time of its spread.
  The two passes take such frames (1.2 s before and after). The session holds no
  frame before it knows that a spread started. The time after the stable time is
  in use.
- A copy of a spread that comes later gives no frames to the first copy. When the
  later copy is better, it takes the place of the first one, and the pages of the
  first one leave the document. So the list of pages can change: a caller reads
  it again after each call.
- The page size is not the median of all spreads.
- The curl correction (`render.Options.curl`) works, but the session has no test
  with it.
- A video with 10 bits per sample (HDR) is not supported: the frames must have 8
  bits per sample.

## What is not verified

- The app was not built: this host has no Android SDK and no NDK. The Kotlin code,
  the Gradle files, and the Android shell of `flake.nix` were not run.
- `zig build android -Dandroid-ndk=...` was not run with an NDK. With no NDK, it
  builds the static libraries for the two Android targets.
- No run on a phone or an emulator. So these numbers are not known: the time of
  the analysis for one frame on a phone, the time of a render job, the memory of
  the app, and the frame rate and the frame size that CameraX gives.
- The colour of camera frames: the app says full range and the BT.601 matrix for
  them, which is the common case and can be wrong for one phone.

The checks that did run: the unit tests of the session with synthetic videos (a
source on its side gives the same JPEG bytes as the upright source), the C program
on the header, the JNI layer on the Java machine of the desktop with
`-Xcheck:jni`, and the benchmark video through `fastest-scan --stream`.

## Consequences

- The library has two flows that must stay in step. The timeline and the
  duplicate search have one implementation for the two. The choice of the frames
  has one implementation, with the option `allowed`. The plan of the two passes
  (which frames go to which page) is still in `src/cli/pipeline.zig`, and the
  stream session has its own form of it.
- `fastest-scan --stream` runs the stream session on a desktop. A change of the
  session can be measured on the benchmark video with no phone.
- A phone decodes each frame one time. A recorded video needs no second pass and
  no jump of the decoder.
- The pages of a spread are complete one spread late. A rule that makes a spread
  final earlier is possible and is not written.
- The memory of a scan depends on the frame size, the donor frames, the page size,
  and the number of render threads. The defaults of the app are not tuned on a
  phone.
- The analysis of a frame can run on more than one thread: `Stream.analyze` does
  not change the session, and `Stream.pushObserved` takes the observations in
  order. The C interface does not export these two functions yet.
