# 0009: Python prototypes can come before the Zig code

Date: 2026-10-09. Status: accepted. The owner of the repository allowed this.

## Context

The fusion step has many choices: the registration method, the block size, the
thresholds of the glare mask, the blend. Each choice needs a test on real frames.
OpenCV and numpy make such a test fast to write.

## Decision

- A prototype in Python can test an algorithm on the benchmark frames first.
- A prototype uses only operations that are easy to write by hand in Zig, or it
  says which heavier operation it used as a comparison.
- The result of a prototype goes into `docs/research/` with its numbers. The
  product code stays in Zig. The library gets no Python dependency.

## Consequences

- The numbers of a prototype are start values for the Zig code, not proof. The
  benchmark of the Zig program decides.
