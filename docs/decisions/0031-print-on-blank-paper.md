# 0031: Print on blank paper makes two pages different

Date: 2026-10-15. Status: accepted. This record adds a rule to decision 0010.

## Context

A camera scan on the phone of 2026-10-14 shows three sheets: a letter, and the
two pages of an invoice. The PDF of the app has two pages: the second page of
the invoice is missing.

The two pages of the invoice come from one form. They have the same header, the
same block with the address and the numbers, the same head of the table, and
the same footer. The first page also has the rows of the table and a paragraph
of text. On the second page that part is blank paper, with two lines of text.

The video of the scan gives three pages on the desktop. But the duplicate search
of decision 0010 compares the two pages and finds 48.9 % of the textured tiles
of the first page again. The limit is 50 %. A real second view of the first
page in the same video gives 51.6 %. So the matched fraction cannot separate the
two cases.

The camera scan of a book (decisions 0029 and 0030) has the same case. The
duplicate search took the title page for a copy of the half-title: the
half-title has the title of the title page, and nothing more. The transform
explained 94.4 % of the tiles of the half-title. No page was lost, because the
next spread shows the title page again.

## Decision

The duplicate search also measures the print on blank paper
(`dedup.Options.max_print_on_blank`):

1. After the alignment, take each tile of 16 x 16 pixels of the small picture.
   A tile with texture in one of the two pictures is a printed tile.
2. A printed tile is on blank paper when the other picture has no pixel below
   the luma code 248 in that tile and in a margin of 8 pixels around it. The
   margin takes the error of the alignment.
3. A tile does not count when one of the two pictures does not show the paper
   there: outside the frame, or a finger with its margin and halo.
4. Two pages are different when 25 % of the printed tiles, or more, lie on
   blank paper. For a spread and a single page, only the page that matches
   counts.

The small picture of each page (`render.SpreadSignature`) gets a mask of the
pixels that do not show the paper (`hidden`). The finger search of
`finger.zig` runs on the flattened page, before the last step of the
enhancement. So the pixels of the small picture do not change.

`duplicates.csv` in the debug directory has the new value for each comparison:
`print_on_blank_page_0` and `print_on_blank_page_1`.

### Why a mask of the fingers

The enhancement makes a finger white, the same as blank paper. On the
benchmark, the fingers of the user hold the lower edge of the booklet, and in
one view they cover the last lines of text. Without the mask, that pair gave
about 0.30. The `covered` cells of the observation do not help: they have only
the dark tips of the fingers, at the border of the page.

### Why the luma code 248 and the margin

The enhancement makes blank paper pure white (255). With the limit 224, the
motion blur of one view of the benchmark made thin lines pale enough to count
as blank paper. With the limit 248, pale print is not blank. Without the
margin, an alignment error of a few pixels puts a line of text of one picture
next to a blank tile of the other picture. The first form had no margin and no
mask, and two views of one page gave up to 0.38 with it.

## Measurements

All runs on 2026-10-15, on the desktop, two passes, from `duplicates.csv`. The
pairs are those with a matched fraction of 35 % or more. The variants are the
video of the invoice at 10, 15, 20, and 24 frames in a second, at 1200 x 1600
and at 2160 x 2880 pixels: the phone gives the library 20 to 26 frames in a
second, at 2160 x 2880 pixels.

| Pair | Matched fraction | Print on blank paper |
|---|---|---|
| The two pages of the invoice: the video and its variants (4 pairs) | 0.393 to 0.489 | 0.245 to 0.336 |
| The half-title and the title page | 0.944 | 0.330 |
| Two views of one page (31 pairs): the benchmark, the camera scan of the book, two other phone videos of 2026-10-12, and the video of the invoice with its variants | 0.399 to 1.000 | 0.000 to 0.119 |
| A bad view of the second page of the invoice (a wrong outline on a bent sheet) and a good view of it | 0.681 | 0.228 |

The limit 0.25 puts each pair on its side. The margin is small on two sides:

- A bad view of a page can look like a page with less print. Its wrong outline
  folds a part of the sheet away. With the limit 0.20, the variant at 15 frames
  in a second got that bad view as an extra page.
- One pair of the invoice gave 0.245. Its matched fraction is 0.393, so the rule
  of decision 0010 keeps the two pages apart. The two pairs of different pages
  with a matched fraction of 50 % or more gave 0.330 and more.

## Results

| Video | With this decision |
|---|---|
| Benchmark, two passes and stream mode | 63 pages, the same bytes of the PDF |
| The other videos, two passes and stream mode: the scans of 2026-10-14 and the 8 variants, the camera scan of the book, the other phone videos of 2026-10-12, the first 30 s of the benchmark | The same bytes of the PDF for each |

The title page of the camera scan joins the next spread now, which shows the
same page. The pages of the PDF are the same.

The two new unit tests make the case with pictures of random blobs: two pages
of one form with the same header and footer, and a copy with a finger on its
print.

## Limits

- **The timeline joins two runs before the duplicate search.** When two runs
  come one after the other, and the thumbnails of their best frames have a
  similarity of 0.9 or more, the timeline makes one spread of them. The
  duplicate search then sees one spread only. Decision 0010 found a similarity
  of up to 0.91 for two different spreads. The two pages of the invoice have
  0.92. The variants at 24 frames in a second give that join, and their PDF has
  two pages, as on the phone. So this join is the probable cause of the missing
  page in the app, and this decision does not change it. The ink map of the
  observation cannot replace the small picture there: for the invoice it gave
  0.10, and for two views of one page up to 0.097.
- **A page that is not white paper.** The test has no blank paper on such a
  page, and no finger mask. The rule of decision 0010 stays for it.
- **Few pairs of different pages.** They come from 2 documents. A form with
  more print in common can stay under the limit.
- **Memory.** The mask has the size of the small picture. The stream session
  keeps the small pictures of up to 5 spreads: on the phone, about 7 MB more.
