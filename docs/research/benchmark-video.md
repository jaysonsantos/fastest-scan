# Benchmark video

The benchmark is `~/VID_20261009_180010.mp4`. The file is 1.2 GB and stays outside the
repository. `scripts/bench.sh` reads its path from `FASTEST_SCAN_BENCH_VIDEO`.

All values on this page are measurements from 2026-10-09 on the development machine
(16 cores, Radeon RX 5700, Linux).

## Format

| Property | Value |
|---|---|
| Container, codec | MP4, HEVC Main, `yuv420p`, BT.709, limited range |
| Size | 3840 x 2160 |
| Duration | 179.6 s |
| Frames | 4984 (variable frame rate, 27.75 frames per second on average) |
| Bit rate | 54 Mbit/s |
| Keyframes | 167, one per second approximately |
| B-frames | None. The decode order is the display order. |
| Time base | 1/90000 |

## Content

- A stapled booklet (a headphone manual in five languages) lies on a wood desk.
- The video starts with the cover: one page, no hand.
- Then it shows 31 two-page spreads. The count is an estimate from contact sheets:
  six spreads for each of five languages, plus one warranty spread at the end.
- The expected result is 63 pages: 1 cover and 62 half spreads.
- A hand turns each page. The fingers then hold the bottom edge of the spread open.
  The fingers cover text at the bottom of the pages in most frames.
- The hand is in other positions during the first frames of a spread. Those frames
  show the bottom text.
- The paper is glossy. A lamp reflection washes out ink in a band that moves when the
  camera or the booklet moves. Black text becomes pale orange in that band.
- The two pages of a spread are not in one plane. The left page often tilts away from
  the camera. The page edges are a little curved near the fold.
- One page fills approximately 1200 x 1700 source pixels.

## Colours

Mean values of 24 x 24 pixel patches from the frame at 19.78 s, in 8-bit full-range
YCbCr:

| Surface | Y | Cb | Cr |
|---|---|---|---|
| Paper | 156 to 164 | 112 to 121 | 133 to 137 |
| Wood desk | 62 to 77 | 106 to 112 | 145 to 148 |
| Skin | 40 to 88 | 112 to 121 | 144 to 153 |
| Maroon print | 63 to 79 | 116 to 124 | 150 to 154 |
| Black print | 35 | 125 | 129 |
| Text in the glare band | 157 | 110 | 140 |

Consequences:

- Luma alone separates the paper from the desk in this video.
- Colour cannot separate skin from the maroon pictures. A finger detector must use
  shape: a finger crosses the page edge, a picture does not.
- Glare makes dark ink as bright as paper. It does not make the paper much brighter.

## Decode speed

| Method | Speed |
|---|---|
| One `ffmpeg` process, software | 1.3 x real time (about 36 frames per second) |
| Eight `ffmpeg` processes on eight time ranges, software | 4.2 x real time in total |
| One `/usr/bin/ffmpeg` process with VAAPI and `scale_vaapi` | 4.2 x real time |
| Keyframes only (`-skip_frame nokey`), one process | 167 frames in 11 s |

- The software decoder uses about 3 CPU seconds for each second of video.
- The `ffmpeg` of the nix profile cannot open the VAAPI device. The system `ffmpeg` can.
- A full decode of this video costs 40 s or more. Cache the decoded analysis frames
  during development.

## Frame-exact seeks

`ffmpeg -ss <t> -noaccurate_seek -i <video> -frames:v <n>` starts at the keyframe at
or before `t`. With `t` = keyframe time + 5 ms, the first output frame is that
keyframe. A test compared the frames of three seeks with a sequential decode: all
three started at the expected frame index.

- Always pass `-fps_mode passthrough`. Without it, `ffmpeg` duplicates or drops
  frames of a variable-rate video, and the frame indexes move.
- `ffprobe -show_entries packet=pts,flags` lists all frames and keyframes in 1.5 s.
