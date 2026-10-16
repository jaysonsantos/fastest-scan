# Benchmark log

Each row is one run of `scripts/bench.sh` on the benchmark video
(`docs/research/benchmark-video.md`). Add a row after each change that can move a
number. The run time depends on the other work of the machine; compare it only
between runs of the same hour.

The run time with a warm cache is for the work on the program: all frames come
from `--cache-dir`, and no decoder runs. The run time with no cache is the time
that a user gets: `BENCH_NO_CACHE=1 scripts/bench.sh`.

OCR: every 4th page, Tesseract 5.5 with the English model. The booklet has five
languages, so the confidence is a relative number, not a measure of correct text.
The sample of 16 pages is small: the number of good words of one text page moves
by 10 to 20 between two results that look the same. For a decision, run
`BENCH_OCR_STEP=1 scripts/bench.sh` (all pages) and look at the pages.

The history before the first commit of this repository was squashed into that
commit. The commit names of the older rows are from that history: they do not
exist any more.

| Date | Commit | Pages (expected 63) | Run time, warm cache | Run time, no cache | PDF size | OCR words | OCR good words (≥ 80) | OCR mean confidence | Note |
|---|---|---|---|---|---|---|---|---|---|
| 2026-10-09 | `1833df0` | 63 | 24.3 s | not measured | 13.4 MB | 1318 | 894 | 77.0 | One frame per page. No glare repair, no finger repair. |
| 2026-10-09 | `d4dc3b1` | 63 | 43 s to 73 s | not measured | 13.6 MB | 1394 | 1020 | 79.5 | Fusion with 6 donor frames per spread: glare repair, finger repair, and pages that the frame cuts. |
| 2026-10-11 | not a default | 63 | 43 s | not measured | 13.4 MB | 1345 | 862 | 74.4 | Experiment: `--curl`, each edge with its own cubic. Worse. See decision 0012. |
| 2026-10-11 | not a default | 65 | 41 s | not measured | 13.9 MB | 1278 | 769 | 73.1 | Experiment: `--curl`, bottom edge with the bend of the top edge. Worse, and one duplicate spread. |
| 2026-10-11 | `8a2c87f` | 63 | 42 s | not measured | 13.6 MB | 1394 | 1020 | 79.5 | Default (curl correction off): the same bytes as `d4dc3b1`. |
| 2026-10-11 | `2f395a2` | 63 | 69 s | not measured | 13.7 MB | 1397 | 1022 | 79.8 | Reference frame per page, frames that cut a page as donors, patch check. On all 63 pages: 2382 good words, before 2330. The gain is in the pictures: see decision 0013. |
| 2026-10-11 | the first commit | 63 | 63 s | not measured | 13.2 MB | 1394 | 1034 | 80.7 | New finger rule, and paint over the fingers that stay (`--fingers all`): no page shows a thumb. On all 63 pages: 2394 good words, before 2382. Faults with no repair: 0.10 % of the page area, before 0.18 %. See decision 0014. |
| 2026-10-11 | the commit of decision 0015 | 63 | 38 s to 41 s | not measured | 13.1 MB | 1396 | 1038 | 80.7 | Speed: no page search in donor frames, vector code in the warp, the registration, and the flatten step, one pass per layer in the fusion. CPU time 158 s to 172 s, before 340 s. On all 63 pages: 2417 good words, before 2394. See decision 0015. |
| 2026-10-11 | the commit of decision 0016 | 63 | 40 s | not measured | 13.2 MB | 1401 | 1035 | 80.2 | A region takes the donor that is sharp in the region. The header "BUTTON FUNCTIONS" is sharp again. On all 63 pages: 2379 good words, before 2417; the pages with the largest loss changed in less than 0.1 % of their pixels. See decision 0016. |
| 2026-10-12 | the commit of decision 0017 | 63 | 29 s | 142 s | 13.2 MB | 1401 | 1035 | 80.2 | Each worker keeps its large blocks of memory. The PDF has the same bytes as the row before. Page faults 1.05 million, before 5.82 million; system time 8.4 s, before 20.4 s. The same binary as the row before takes 31 s on this day: the machine did no other work. See decision 0017. |
| 2026-10-12 | the commit of decision 0018 | 63 | 27.5 s | 136 s | 13.1 MB | 1401 | 1035 | 80.2 | The skin test accepts dark hands and skin in a shadow. 9 pages changed, each in less than 1 % of its pixels: less wood of the desk at page corners. On four public videos with darker hands, enlarged four times: 6 of 105 pages keep skin, before 13. See decision 0018. |
| 2026-10-12 | the commit of decision 0020 | 63 | 27.6 s | 92 s | 13.1 MB | 1401 | 1035 | 80.2 | One thread per decoder, two decoders per worker, only the needed frames through the pipe, one load per spread. The PDF has the same bytes as the row before. With no cache: CPU time 964 s, before 1530 s; peak memory with the decoders 6.1 GB, before 8.9 GB. See decision 0020. |
| 2026-10-12 | the commit of decision 0021 | 63 | 27 s | not measured | 13.1 MB | 1401 | 1035 | 80.2 | The sizes of the finger rule follow the page width. The PDF has the same bytes as the row before: the benchmark page has the reference width. On ten small public videos, 30 of 434 pages keep skin, before 166. On the copy of the benchmark at 1920 x 1080, no page keeps a thumb tip at the bottom edge, before 4. See decision 0021. |
| 2026-10-12 | the commit of decision 0022 | 63 | 27.0 s | not measured | 13.1 MB | 1404 | 1036 | 80.1 | A thin blob of skin in the light is a finger. No page shows the tip of a thumb, before 4; a thin line of a tip stays on 2 pages. 87 places on 42 pages changed, each one checked: thumb tips and strips of desk wood are gone, no text and no header bar changed. See decision 0022. |
| 2026-10-12 | the commit of decision 0025 | 63 | 27 s | not measured | 13.1 MB | 1403 | 1036 | 80.2 | The halo of a finger reaches 16 cells, the rim of a pale finger belongs to the mask, and the size limit of the paint counts the finger alone. The corner of one page with a pale thumb tip is clean. 60 places on 34 pages changed, each one checked: no text, no drawing, and no header bar changed. See decision 0025. |
| 2026-10-12 | the commit of decision 0019 | 63 | no cache in this mode | 145 s to 178 s | 14.9 MB | 1398 | 1060 | 80.6 | Not the default: `--stream`, the flow of the Android app. One pass in order, 4 donor frames and 2 views from near for a spread, at most 38 full-size frames in memory. On all 63 pages: 2317 good words; the two passes give 2281. The default (two passes) gives the same bytes as the row before. See decision 0019. |
| 2026-10-12 | the commit after decision 0019 | 63 | no cache in this mode | 151 s on a phone | 14.5 MB | 1384 | 1047 | 81.0 | Not `scripts/bench.sh`: the Android app on a REDMI Note 15 Pro+ 5G, with the hardware decoder of the phone (`scripts/test-android.sh`). Pages of 1424 x 2000 pixels, 29 ms for each frame, at most 26 full-size frames and 1137 MB of native memory. On all 63 pages: 2311 good words. See decision 0019. |
| 2026-10-12 | the commit of decision 0024 | 63 | 29.8 s | not measured | 13.1 MB | not measured | not measured | not measured | The outline search for a book on a bright surface. The PDF has the same bytes as before the change (OCR not run again); 145 of 4984 frames get another observation. A phone video of a bright room gives 7 pages of the book, before 18 pages of the wall and the floor. See decision 0024. |
| 2026-10-15 | the commit of decision 0031 | 63 | 37.5 s | not measured | 13.1 MB | 1403 | 1036 | 80.2 | The test for print on blank paper in the duplicate search. The PDF has the same bytes as before, in two passes and in stream mode: the 10 duplicate views of the benchmark give at most 0.09, and the limit is 0.25. See decision 0031. |
| 2026-10-15 | the commit of decision 0032 | 63 | 32.9 s | 162 s, stream mode | 13.1 MB | not measured | not measured | not measured | The small pictures decide the join of two runs in stream mode. The PDF has the same bytes as before, in two passes and in stream mode: no join of the benchmark was kept apart. Stream mode: 14.8 MB. See decision 0032. |
| 2026-10-16 | the commit of decision 0033 | 63 | 35.7 s | not measured | 13.1 MB | 1402 | 1033 | 80.1 | A shadow that the paper surface cannot follow keeps its own paper colour. 46 of 63 pages have no pixel change of more than 16 codes; the changes are at the page edges. On all 63 pages: 2294 good words, the same as before. A letter on a wooden table: 5 % of the page has a tint, before 14 % to 18 %. See decision 0033. |
