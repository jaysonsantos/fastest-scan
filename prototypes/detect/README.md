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
```

Each script writes one picture for each frame and prints one or two lines for
each frame.
