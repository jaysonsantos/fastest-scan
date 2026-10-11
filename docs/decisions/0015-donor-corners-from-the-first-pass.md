# 0015: A donor frame takes the page corners of the first pass; the hot loops use vector code

Date: 2026-10-11. Status: accepted. This record changes one step of decision 0013:
the render pass does not search a donor frame for pages again.

## Context

The run on the benchmark video took about 65 s, 54 s of it in the render pass
(decision 0013 made it two times slower). A CPU profile of the whole run showed
where the time went:

| Part | Share of the CPU time |
|---|---|
| Page detection on full-size frames (`detect.findGutter`, `detect.analyzeScene`) | 28 % |
| Page warp of the reference and the donors (`resample.warpPageAligned`, `warpPage`) | 22 % |
| Registration of the donors: the luma warp of each round, and the tile search | 24 % |
| Flatten step (`enhance.flatten`) | 10 % |
| Cell values and fingers of the fusion | 7 % |

LLVM does not make vector code from a loop in Zig 0.17, so each loop over pixels
ran one pixel at a time.

## Decision

### No page search in a donor frame

The render pass searched each donor frame for pages at the full size. That was
9 of 10 searches. A donor frame now takes the page corners that the analysis pass
found on the small frame. The corners of a donor are only the start value of the
registration, which runs in rounds (decision 0013) and finds the exact place.

The reference frame keeps the search at the full size: its corners are the crop of
the page. `render.Options.redetect_donors` turns the search of the donors on
again. The curl correction needs the page outlines of each frame, so it does that.

### Less work for each pixel

- **Warp** (`resample.zig`, `Walk`): the sums of a plane transform change by a
  constant step along a row. A warp with no shift grid uses one transform, the
  product of the page map and the alignment. The division is 32-bit; the sums
  stay 64-bit. The cubic takes the four samples of a row at a time when the 4 x 4
  samples lie inside the plane.
- **Registration** (`register.correlate`): the sums of a tile take 16 pixels at a
  time.
- **Flatten** (`enhance.flatten`): the weights of the paper colour are the same
  for a whole column and for a whole row, and the three channels go through the
  arithmetic together.
- **Fusion** (`fuse.measureLayer`): one pass over a layer gives the ink value, the
  mean luma, the tint, and the colours for the finger mask. There were four
  passes.
- **Fold search** (`detect.findGutter`): the response is stored column after
  column. A candidate line is almost along a column, so the search reads memory
  in order. The result is the same.

## Measurements on the benchmark video

The machine did other work during the runs, so each time is a range.

| | Before | Now |
|---|---|---|
| Pages | 63 | 63 |
| Run time, warm cache | 63 s to 70 s | 38 s to 41 s |
| Render pass | 54 s to 58 s | 27 s to 30 s |
| CPU time, user | 340 s | 158 s to 172 s |
| Donor pages that registered | 466 | 454 |
| Faults with no repair, page area | 0.10 % | 0.06 % |
| OCR good words, all 63 pages | 2394 | 2417 |
| OCR mean confidence, all pages | 74.9 | 75.2 |

No page changed in more than 1.1 % of its pixels.

How to get a profile: `nix shell --inputs-from . nixpkgs#perf --command perf
record -g -- zig-out/bin/fastest-scan <video> -o out/perf.pdf --cache-dir .cache`,
then `perf report --no-children --sort symbol`.

## Consequences

- 12 donor pages fewer register, of 466. The start value from the small frame is
  less exact, and a donor with too few tiles after 3 rounds is dropped. The
  result did not get worse.
- The result is not the same bytes as before: the 32-bit division and the order
  of the sums change the last bits of a pixel.
- Vector code is explicit (`@Vector`), with a scalar loop for the rest of a row
  and for samples at the border.
- What still costs time: the page warp (about 40 % of the CPU time), the analysis
  pass (about 11 s), and about 20 s of system time for fresh memory in each
  render job.
