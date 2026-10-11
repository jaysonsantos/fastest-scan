# 0001: A library does the work; the CLI is a thin program on top

Date: 2026-10-09. Status: accepted.

## Context

The first user is a command-line program on Linux. A later user is an Android app.
The Android app cannot start `ffmpeg`. It gets frames from `MediaCodec` or from the
camera.

## Decision

- `src/lib/` is the library `fastscan`. It has all the image processing: page
  detection, page-turn segmentation, registration, fusion, enhancement, the JPEG
  encoder, and the PDF writer.
- The library never opens a video and never starts a process. The caller pushes
  frames as planar YUV 4:2:0 buffers.
- The library sends the PDF bytes to a callback. It never opens a file.
- `src/cli/` is the program `fastest-scan`. It parses the arguments, starts
  `ffmpeg`, pushes the frames, and writes the file.
- `src/lib/c_api.zig` exports the same flow as C functions. `include/fastscan.h`
  declares them. A JNI layer can call them.
- `zig build` makes the CLI, a static library, and a shared library.

## Consequences

- The library has no dependency other than the Zig standard library. It builds for
  Android with `-Dtarget=aarch64-linux-android`.
- Every feature needs a place in the frame-push interface. A function that reads a
  file path does not belong in the library.
- The C interface must stay in step with the Zig interface. A test calls the C
  functions.
