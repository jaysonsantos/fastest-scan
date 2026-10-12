# 0020: A decoder has one thread and gives only the frames that a job needs

Date: 2026-10-12. Status: accepted. Decision 0003 stays: `ffmpeg` is a process of
the CLI. This record changes how the CLI starts it. The number 0019 belongs to a
record on the branch `android-app`.

## Context

The run time of the benchmark log is for a run with all frames in a cache. That
is the time for the work on the program. A user has no cache: that run took
136 s, against 28 s with the cache.

The decoders took the difference. The CPU time of the run was 1332 s of user time
and 198 s of system time. The work of the program itself is 157 s. One `ffmpeg`
process decodes the whole video in 348 s of CPU time, and it needs 29 s more to
make the frames small. So the decoders of the run used three times the CPU time
of one pass over the video.

Three causes:

1. **Threads.** Each `ffmpeg` took one thread per CPU thread (16), and 8 of them
   ran at the same time. A decoder with frame threads decodes frames after the
   last frame that it gives. One decoder run as the render pass starts it (26
   frames from a keyframe, one frame out):

   | Threads | CPU time | Run time | Memory |
   |---|---|---|---|
   | 1 | 1.90 s | 1.95 s | 127 MB |
   | 2 | 1.98 s | 1.64 s | 145 MB |
   | 4 | 2.15 s | 1.72 s | 224 MB |
   | 16 | 3.12 s | 1.81 s | 698 MB |

   More threads make one run only a little faster. They cost CPU time and memory.
2. **The pipe.** A decoder must decode each frame from a keyframe to the frame
   that a job needs. The reader took all of these frames from the pipe, 12.4 MB
   each: 3225 frames for the 458 frames that the render pass needed. That was
   the system time.
3. **Two loads per spread.** The two pages of a spread have their own reference
   frame and donor frames (decision 0013). Each page loaded its frames, from the
   same seconds of the video.

Three things that help little or not at all on this video and this machine:

- **The hardware decoder.** One VAAPI decoder gives 113 frames per second with
  the scale on the GPU, and 97 with the scale on the CPU. That is as much as all
  the CPU threads give together, and 8 hardware decoders at the same time give
  no more.
- **`-skip_loop_filter all`.** 6 % less CPU time.
- **A skip of frames.** Each frame of the stream is a reference frame for the
  next one (`TRAIL_R`, one temporal layer), so the decoder cannot skip a frame.

## Decision

1. **One thread per decoder.** `ffmpeg.ReaderOptions.threads` is 1 by default.
2. **Two decoders per worker** (`pipeline.decoders_per_worker`). The default
   number of workers stays half of the CPU threads, so the decoders together use
   each CPU thread.
   - The analysis pass and the signature step have one decoder per job and
     little other work. They run two jobs per worker.
   - A load of the render pass starts the decoder of its next run while it reads
     the frames of the current run. A run is the frames that share a keyframe.
3. **Only the frames that a job needs go through the pipe.** The reader gives
   `ffmpeg` the `select` filter with the numbers of those frames.
4. **One load per spread.** The render job collects the frames of all pages of
   the spread and loads them with one call, so the pages share the decoder runs.

`--jobs N` sets the number of workers, as before. With `--verbose`, the program
prints how many full-size frames the render pass needed, and how many frames the
decoders decoded for them.

## Measurements on the benchmark video

Two runs of each binary in turn, with no frame cache, on 2026-10-12. The PDF has
the same bytes.

| | Before | Now |
|---|---|---|
| Run time | 136 s | 92 s |
| Analysis pass | 49.5 s | 41.4 s |
| Render pass | 86.6 s | 50.5 s |
| User time | 1332 s | 908 s |
| System time | 198 s | 56 s |
| Frames that the render pass needed | 458 | 425 |
| Frames that the decoders decoded for them | 3225 | 2622 |
| Peak memory of the program and its decoders | 8.9 GB | 6.1 GB |

With all frames in the cache (three runs each): 27.6 s, before 28.2 s. The
analysis pass takes 4.7 s there, before 6.4 s, because it has twice the jobs.

With the hardware decoder (`--ffmpeg /usr/bin/ffmpeg --hwaccel vaapi`) and no
cache: 83 s, before 117 s. The PDF has the same bytes as with the CPU decoder.

## Consequences

- With a warm cache, the program holds 5.2 GB at its peak, before 4.7 GB: a
  worker holds the frames of the two pages of a spread at the same time.
- The decode is still the largest part of a run with no cache.
  - The analysis pass must decode each frame: 377 s of CPU time on 8 cores.
  - The render pass decodes 2622 frames for the 425 that it needs: the frames
    between a keyframe and a donor frame.
- Ideas that are left:
  - Give `timeline.selectDonors` a cost per frame, so that of two donor frames
    with the same value, it takes the one near its keyframe.
  - Hardware decoders and CPU decoders at the same time: together they can give
    two times the frames per second.
  - Read the video one time: the stream session of the branch `android-app`.
