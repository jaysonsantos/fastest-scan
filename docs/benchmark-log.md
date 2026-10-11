# Benchmark log

Each row is one run of `scripts/bench.sh` on the benchmark video
(`docs/research/benchmark-video.md`). Add a row after each change that can move a
number. The run time depends on the other work of the machine; compare it only
between runs of the same hour.

OCR: every 4th page, Tesseract 5.5 with the English model. The booklet has five
languages, so the confidence is a relative number, not a measure of correct text.
The sample of 16 pages is small: the number of good words of one text page moves
by 10 to 20 between two results that look the same. For a decision, run
`BENCH_OCR_STEP=1 scripts/bench.sh` (all pages) and look at the pages.

The history before the first commit of this repository was squashed into that
commit. The commit names of the older rows are from that history: they do not
exist any more.

| Date | Commit | Pages (expected 63) | Run time, warm cache | PDF size | OCR words | OCR good words (≥ 80) | OCR mean confidence | Note |
|---|---|---|---|---|---|---|---|---|
| 2026-10-09 | `1833df0` | 63 | 24.3 s | 13.4 MB | 1318 | 894 | 77.0 | One frame per page. No glare repair, no finger repair. |
| 2026-10-09 | `d4dc3b1` | 63 | 43 s to 73 s | 13.6 MB | 1394 | 1020 | 79.5 | Fusion with 6 donor frames per spread: glare repair, finger repair, and pages that the frame cuts. |
| 2026-10-11 | not a default | 63 | 43 s | 13.4 MB | 1345 | 862 | 74.4 | Experiment: `--curl`, each edge with its own cubic. Worse. See decision 0012. |
| 2026-10-11 | not a default | 65 | 41 s | 13.9 MB | 1278 | 769 | 73.1 | Experiment: `--curl`, bottom edge with the bend of the top edge. Worse, and one duplicate spread. |
| 2026-10-11 | `8a2c87f` | 63 | 42 s | 13.6 MB | 1394 | 1020 | 79.5 | Default (curl correction off): the same bytes as `d4dc3b1`. |
| 2026-10-11 | `2f395a2` | 63 | 69 s | 13.7 MB | 1397 | 1022 | 79.8 | Reference frame per page, frames that cut a page as donors, patch check. On all 63 pages: 2382 good words, before 2330. The gain is in the pictures: see decision 0013. |
| 2026-10-11 | the first commit | 63 | 63 s | 13.2 MB | 1394 | 1034 | 80.7 | New finger rule, and paint over the fingers that stay (`--fingers all`): no page shows a thumb. On all 63 pages: 2394 good words, before 2382. Faults with no repair: 0.10 % of the page area, before 0.18 %. See decision 0014. |
| 2026-10-11 | the commit of decision 0015 | 63 | 38 s to 41 s | 13.1 MB | 1396 | 1038 | 80.7 | Speed: no page search in donor frames, vector code in the warp, the registration, and the flatten step, one pass per layer in the fusion. CPU time 158 s to 172 s, before 340 s. On all 63 pages: 2417 good words, before 2394. See decision 0015. |
