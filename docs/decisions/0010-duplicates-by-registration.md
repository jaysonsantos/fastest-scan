# 0010: Two spreads are the same when their pages register

Date: 2026-10-09. Status: accepted.

## Context

The timeline cuts the video into stable runs of frames. One spread often gives two
or three runs: a hand passes, or the camera moves. The first rule joined two runs
when the thumbnails of their reference frames were alike.

Measurements on the benchmark showed that thumbnails cannot decide this:

- Two views of one spread had a thumbnail similarity as low as 0.54, because a
  finger on an edge moves the corners of the quad.
- Two different spreads with the same layout (two pictures and some text) had a
  similarity up to 0.91.

## Decision

- The render pass makes a small picture (half the page size) of each page of each
  run, from the reference frame at full size.
- `register.zig` aligns the pictures of two runs: tiles on a pyramid, then one
  plane transform. `dedup.zig` repeats this from the moved picture, up to three
  times.
- Two runs show the same spread when the transform explains 50 % or more of the
  textured tiles of one page and 35 % or more of the other page.
- The run with the better reference frame stays, at its own place in the order.
- A weak run (short, or with a hand on it) is also compared with the four spreads
  before it. A strong run is compared with its neighbour only.

On the benchmark, views of one spread match on 42 % to 95 % of the tiles and
different spreads on at most 23 %.

## Consequences

- The text decides, not the layout: the same page in two languages is two pages.
- A page with almost no texture cannot be compared. It is never a duplicate.
- The reference frame of each run is decoded before the duplicate search. Runs
  that are removed cost that work.
- A page that appears two times in the book on purpose, next to each other, is
  joined. No such book is known.
