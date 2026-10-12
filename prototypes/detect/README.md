# Detector prototypes (Python)

This directory is a record of experiments, not a part of the product.
`docs/decisions/0009-python-prototypes-before-zig.md` has the reason for a
prototype in Python. The Zig library does not use this code. No linter checks it.

The two scripts looked on 2026-10-12 for the paper of a book that lies on a
surface as bright as its pages. `docs/decisions/0024-outline-search-for-bright-surroundings.md`
has the result.

- `region_search.py`: the regions above each of 16 brightness thresholds, and a
  number that says how much each region is like a sheet of paper. It finds the
  cover of the book. For a spread it finds only the part of the page in the
  light. This approach did not go into the Zig code.
- `edge_flood.py`: the pixels with a strong step of luma or chroma are walls, a
  flood runs from the frame border, and the paper is the largest region that the
  flood does not reach. It finds the whole book in the test frames.
  `detect.outlineRegion` in `src/lib/detect.zig` is this experiment in Zig:
  change the two together.

`line_quads.py` looked on the same day for a page on a white desk with a wood
grain and with things around the book, where the outline search fails.
`docs/decisions/0026-line-search-for-a-page-on-a-bright-desk.md` has the result.

- `line_quads.py`: the straight lines of the frame (a Hough transform with the
  direction of the gradient), and then four lines that make a quad with a page
  inside. It finds the page in all test frames of the desk. `lines.find` in
  `src/lib/lines.zig` and `detect.lineRegion` in `src/lib/detect.zig` are this
  experiment in Zig. The script is the experiment as it ran. The Zig code then
  got more: a line has its distance from the middle of the frame and a vote
  that is larger for the direction of the step, three sides of a page need
  steps along 90 % of their length, and the surface around a page needs another
  colour. The script imports `edge_flood.py`.

## What they need

- `uv`, which gets Python with numpy, Pillow, and scipy from the header of each
  script.
- Frames of 960 x 540 pixels as PNG files. The frames are not in the repository:

  ```sh
  ffmpeg -ss 17.3 -i video.mp4 -frames:v 1 -vf "scale=960:540:flags=area" out/detect/frames/a.png
  ```

## Run

```sh
uv run prototypes/detect/region_search.py out/detect/frames/*.png --out out/detect/regions
uv run prototypes/detect/edge_flood.py out/detect/frames/*.png --out out/detect/flood
uv run prototypes/detect/line_quads.py out/detect/frames/*.png --out out/detect/quads
```

Each script writes one picture for each frame and prints one or two lines for
each frame.
