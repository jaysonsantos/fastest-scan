# Finger prototype (Python)

This directory is a record of an experiment, not a part of the product. It tested
a new rule for the finger mask of the fusion on 2026-10-11, before the Zig code
of `src/lib/finger.zig`. `docs/decisions/0014-paint-over-fingers.md` has the
result. `docs/decisions/0009-python-prototypes-before-zig.md` has the reason for a
prototype in Python.

The Zig library does not use this code. No linter checks it.

## What it needs

- Python 3 with numpy and Pillow.
- The layer pictures of the Zig program: the page of each frame before the fusion.

  ```sh
  zig-out/bin/fastest-scan "$FASTEST_SCAN_BENCH_VIDEO" -o out/bench.pdf \
    --cache-dir .cache --debug-dir .cache/debug --debug-layers
  ```

  A layer picture has the name `p_<spread>_<page>_<layer>.jpg`. Layer 00 is the
  reference frame.

## Run

```sh
# The old mask and the new mask on each layer of one page.
python3 prototypes/fingers/finger_mask.py .cache/debug/layers/p_005_0_*.jpg --out out/masks

# Which fingers of the reference frames have blank paper around them.
cd prototypes/fingers
python3 paint_rule.py ../../.cache/debug/layers/p_*_00.jpg --out ../../out/paint
```

## What is different in the Zig code

The scripts hold the state of the first experiment. These parts came later, in
Zig, and are not in the scripts:

- the halo of a finger, and the cells that the mask closes in;
- the paint that keeps the ink next to a finger;
- the ring of the paint, which starts at the border of the mask with its halo.
