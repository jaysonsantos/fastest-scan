# 0003: The CLI decodes video with ffmpeg processes

Date: 2026-10-09. Status: accepted.

## Context

The CLI must read HEVC, H.264, and other phone formats. The choices were a link to
`libavcodec` or the `ffmpeg` program with raw frames on a pipe.

## Decision

- The CLI starts `ffprobe` one time to read the stream properties and the list of
  frames with their keyframe flags.
- The CLI starts several `ffmpeg` processes. Each process decodes one range of
  frames that starts at a keyframe, and writes raw `yuv420p` frames to its pipe.
- A range starts with `-ss <keyframe time + 5 ms> -noaccurate_seek`. The first
  frame of the output is then exactly that keyframe. `-frames:v` ends the range.
- Every command has `-fps_mode passthrough`.
- The flags `--ffmpeg` and `--ffprobe` (and the variables `FASTEST_SCAN_FFMPEG`,
  `FASTEST_SCAN_FFPROBE`) select the programs. `--hwaccel` passes a hardware
  decoder name to `ffmpeg`.

## Consequences

- No C library in the build. The build stays fast and the cross-compile stays easy.
- The frame index of a frame is its position in the `ffprobe` list. This is only
  correct for a stream without B-frames, or when the list is sorted by display
  time. The CLI sorts the list.
- One software decoder uses 2 to 3 cores. Parallel ranges use all cores. See
  `docs/research/benchmark-video.md` for the speeds.
- A machine without `ffmpeg` cannot run the CLI.
