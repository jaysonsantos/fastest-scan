# Fusion prototype (Python)

This directory is a record of an experiment, not a part of the product. A research
agent wrote it on 2026-10-09 to find which fusion algorithm repairs glare and
fingers on the benchmark video. `docs/research/fusion-prototype.md` has the results.
`docs/decisions/0009-python-prototypes-before-zig.md` has the reason for a
prototype in Python.

The Zig library does not use this code. No linter checks it.

## What it needs

- `uv`, which gets numpy and OpenCV for each run. Nothing is installed globally.
- `ffmpeg`.
- The benchmark video. `FASTEST_SCAN_BENCH_VIDEO` names it.
- The debug output of the Zig program, for the page corners of each frame:

  ```sh
  zig-out/bin/fastest-scan "$FASTEST_SCAN_BENCH_VIDEO" -o out/bench.pdf \
    --cache-dir .cache --debug-dir .cache/debug
  ```

  The frame ranges in `config.py` belong to the corner table of the commit of
  2026-10-09. A later detector can give other corners.

## Run

```sh
prototypes/fusion/run_all.sh
```

The script extracts 352 frames one time (`frames/`, about 140 MB), then runs each
question of the study. The pictures and the JSON results go to `out/`. The
directories `frames/`, `out/`, `cache/`, and `logs/` are not in git.

## Files

| File | Purpose |
|---|---|
| `config.py` | The frame ranges and reference frames of the three spreads |
| `fslib.py`, `register.py`, `stack.py`, `analysis.py`, `fusion.py` | The primitives: warp, block matching, homography fit, glare and finger masks, fusion rules |
| `q1q2_registration.py`, `q2_chain*.py` | Registration error and the start pose |
| `q3_exposure.py` | Exposure and white balance drift |
| `q4_glare.py` | Glare confidence and donor coverage |
| `q5_fusion.py` | Reference plus patch, soft minimum, and median |
| `q6_fingers.py` | Finger mask and finger repair |
| `q7_*.py` | Sharpness scores |
| `q8_cost.py` | Run time of each step |
| `diag_edge_ghost.py` | Why a patch shows text two times at a bent page corner |
