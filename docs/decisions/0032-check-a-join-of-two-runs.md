# 0032: The small pictures decide the join of two runs in the stream session

Date: 2026-10-15. Status: accepted. This record changes the join of two runs in
the stream session of decision 0019. The two passes keep the join of the
thumbnails.

## Context

The timeline cuts the video into runs of stable frames. After a short break,
`timeline.Tracker` joins a run with the spread before it when the thumbnails of
their best frames have a similarity of 0.9 or more (`merge_similarity`). The
joined run is a second view of the spread: in the stream session, its frames
become reference and donor frames of that spread.

Decision 0010 found a similarity of up to 0.91 for two different spreads. The
join stayed, because the value 0.9 is high and a page that appears two times is
a smaller fault than a missing page.

Two cases show that the thumbnails join different pages:

- **An invoice of two pages.** The phone app lost the second page of an invoice
  in a scan of 2026-10-14 (decision 0031, "Limits"). The thumbnails of the two
  pages have a similarity of 0.92. The video of the scan at 24 frames in a
  second gives that join on the desktop, and the PDF has 2 pages of 3. The
  phone gives the library 20 to 26 frames in a second.
- **A book with little print.** A book video of 2026-10-12 shows a title page, an
  epigraph, the start of a chapter, and other spreads with much blank paper.
  The thumbnails of five different spreads have similarities of 0.95 to 0.97,
  so the timeline joined them to one spread. The PDF has 7 pages, and 3 spreads
  are missing.

The thumbnails are a grid of ink cells of the analysis frame. They show where
the print is, not what it is.

## Decision

The tracker asks a judge of the caller before each join:

1. `Tracker.push` and `Tracker.finish` take a `judge`. When two runs have the
   same layout and similar thumbnails, the tracker calls
   `judge.sameSpread(previous, run)`. The run joins only when the judge says
   yes. The tracker changes only after the judge, so an error of the judge
   leaves the tracker as it was.
2. `timeline.build`, and with it the two passes, uses `Tracker.by_thumbnails`.
   That judge always says yes, so the two passes do not change.
3. The stream session renders the small picture of each page of the two runs,
   from the frames that it holds, and compares them with `dedup.compare`: the
   test of the duplicate search, with the rule of decision 0031. The run joins
   only when that test finds the same pages.
4. The frame for the small picture is the best frame of the run. When the
   session holds that frame no more, it takes the first choice of its last
   choice of frames. With no frame of a run, the thumbnails decide, as before.
5. Before the page size is final (the first two spreads), the page size for the
   small pictures comes from the two runs.

`Stream.stats.runs_kept_apart` counts the runs that the judge kept apart. The
command-line program shows the count with `--stream -v`.

### Why the whole test and not only the print on blank paper

The rule of decision 0031 alone keeps 4 of the 5 wrong joins of the book video
apart. One pair has 2.4 % and 21.2 % of its print on blank paper, under the
limit of 25 %, but matched fractions of 0.226 and 0.455: the right pages have
text at different places. The matched fraction of the duplicate search finds
it. The real joins of the local videos match on 0.802 or more.

## Measurements

All runs on 2026-10-15, on the desktop, in the stream mode (`--stream`). The
table has each join that the thumbnails asked for. The values come from a run
that joined as before, so each pair is a join of the old code.

| Video | Pair (reference frames) | What the frames show | Matched fraction | Print on blank paper | Now |
|---|---|---|---|---|---|
| The invoice scan at 30 frames in a second | 269, 326 | Two views of one page | 0.802 | 0.019 | Joined |
| The invoice scan at 24 frames in a second, 1200 x 1600 | 245, 357 | The two pages of the invoice | 0.416 | 0.284 | Apart |
| The invoice scan at 24 frames in a second, 2160 x 2880 | 243, 357 | The two pages of the invoice | 0.417 | 0.400 | Apart |
| The camera scan of a book | 886, 997 | Two views of one spread | 0.976, 0.968 | 0.000, 0.000 | Joined |
| The book video | 8, 42 | Two views of the cover | 1.000 | 0.000 | Joined |
| The book video | 8, 82 | Two views of the cover | 1.000 | 0.000 | Joined |
| The book video | 514, 626 | Two different spreads | 0.128, 0.943 | 0.699, 0.189 | Apart |
| The book video | 626, 722 | Two different spreads | 0.226, 0.455 | 0.024, 0.212 | Apart |
| The book video | 626, 831 | Two different spreads | 0.000, 0.037 | 0.077, 0.604 | Apart |
| The book video | 626, 937 | Two different spreads | 0.286, 0.108 | 0.765, 0.585 | Apart |

The other local videos have no join that the thumbnails ask for.

## Results

| Video | Before | With this decision |
|---|---|---|
| Benchmark, stream mode | 63 pages | 63 pages, the same bytes of the PDF |
| The invoice scan at 24 frames in a second, two sizes, stream mode | 2 pages: the second page of the invoice is missing | 3 pages, all correct |
| The book video, stream mode | 7 pages: 3 spreads are missing | 16 pages: no spread is missing, and 3 pages are extra (see "Limits") |
| The other local videos, stream mode: the scans of 2026-10-14 and the other 6 variants, the camera scan of the book, the other phone videos of 2026-10-12, the first 30 s of the benchmark | | The same bytes of the PDF for each |
| All local videos and the benchmark, two passes | | The same bytes of the PDF for each |

The cost: for each join that the thumbnails ask for, the session renders two
small pictures and compares them. In two runs on the desktop, the session time
of the book video was 30.6 s and 31.2 s before, and 32.1 s and 33.0 s with this
decision. That time also has the work of the 4 spreads more. The judge runs on
the thread of the source, at the end of a run: the time of a page turn.

## Limits

- **The two passes keep the join of the thumbnails.** The two passes decode
  the full-size frames only after the timeline is complete. So in two passes the
  book video still gives 7 pages, and the invoice scan at 24 frames in a second
  2 pages. A fix needs the reference frames of the joined runs before the
  timeline is final.
- **A wrong "apart" gives a page two times.** The duplicate search later
  compares the same two pictures and keeps both spreads. A page that appears
  two times is a smaller fault than a missing page.
- **The extra pages of the book video.** They are faults of the duplicate
  search, which the join hid before:
  - The copyright spread is in the PDF two times. In the first view, a hand
    bends the right page, its outline is wrong, and the right pages do not
    register (matched fraction 0.000). Before, the second view joined a later
    spread, and the duplicate search never compared the two views.
  - The front cover is in the PDF at the start and at the end. The duplicate
    search compares a weak spread with the 4 kept spreads before it only
    (decision 0010). Before, the joins made the list of kept spreads short
    enough.
