# Decisions

One file per decision. A file has the context, the decision, and the consequences.
Add a new file for a new decision. To change an old decision, add a file that
replaces it and name the old file in the new one.

| Number | Decision |
|---|---|
| [0001](0001-library-and-cli.md) | A library does the work; the CLI is a thin program on top |
| [0002](0002-two-passes-over-the-video.md) | Two passes: small frames for analysis, then selected full frames |
| [0003](0003-ffmpeg-subprocess-in-the-cli.md) | The CLI decodes video with `ffmpeg` processes |
| [0004](0004-page-detection-by-paper-mask.md) | The first page detector uses a paper mask |
| [0005](0005-reference-plus-patch-fusion.md) | Fusion keeps one reference frame and patches it |
| [0006](0006-own-jpeg-and-pdf-writers.md) | The library has its own JPEG encoder and PDF writer |
| [0007](0007-credit-every-source.md) | Credit every source; take ideas, not code, from programs with another license |
| [0008](0008-machine-learning-only-at-phone-speed.md) | Machine learning only when a phone runs it fast |
| [0009](0009-python-prototypes-before-zig.md) | Python prototypes can come before the Zig code |
| [0010](0010-duplicates-by-registration.md) | Two spreads are the same when their pages register |
| [0011](0011-fusion-rule.md) | The dark frames show the ink; a finger gives no data |
| [0012](0012-page-curl-is-optional.md) | The page-curl correction exists, and it is off by default |
| [0013](0013-page-reference-and-patch-check.md) | Each page has its own reference frame; a patch must agree with the reference |
| [0014](0014-paint-over-fingers.md) | A new finger rule; a finger that stays gets the colour of the paper |
| [0015](0015-donor-corners-from-the-first-pass.md) | A donor frame takes the page corners of the first pass; the hot loops use vector code |
| [0016](0016-sharp-donor-in-the-region.md) | A region takes the donor that is sharp in the region |
| [0017](0017-worker-memory-from-a-block-cache.md) | A worker keeps its large blocks of memory |
| [0018](0018-skin-test-for-dark-hands.md) | The skin test accepts dark hands and skin in a shadow |
| [0020](0020-one-thread-per-decoder.md) | A decoder has one thread and gives only the frames that a job needs |
