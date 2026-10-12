#!/usr/bin/env bash
# Convert the benchmark video and print the numbers that show the quality of the
# result: the page count, the run time, the size, and the confidence of an OCR pass.
#
#   scripts/bench.sh                 # every 4th page goes through OCR
#   BENCH_OCR_STEP=1 scripts/bench.sh
#   BENCH_NO_CACHE=1 scripts/bench.sh # no frame cache: the time that a user gets
#
# The video is not in the repository. FASTEST_SCAN_BENCH_VIDEO names it.
# Needs ffmpeg, pdfimages (poppler), and tesseract, from the nix shell.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$script_dir")"

# region: constants

readonly DEFAULT_VIDEO="$HOME/VID_20261009_180010.mp4"
readonly VIDEO="${FASTEST_SCAN_BENCH_VIDEO:-$DEFAULT_VIDEO}"
# The page count of the default video: 1 cover and 31 spreads.
readonly EXPECTED_PAGES="${BENCH_EXPECTED_PAGES:-63}"
readonly OCR_STEP="${BENCH_OCR_STEP:-4}"
readonly OCR_LANGUAGE="${BENCH_OCR_LANGUAGE:-eng}"
readonly OUT_DIR=out/bench
readonly CACHE_DIR="${FASTEST_SCAN_CACHE_DIR:-.cache}"
# With a value other than 0, the decoders give each frame: the run has no cache.
readonly NO_CACHE="${BENCH_NO_CACHE:-0}"
readonly PDF="$OUT_DIR/bench.pdf"
readonly PAGES_DIR="$OUT_DIR/pages"
# tesseract writes one line per word; column 11 is the confidence, column 12 the text.
readonly TSV_CONFIDENCE_COLUMN=11
readonly TSV_TEXT_COLUMN=12
readonly GOOD_WORD_CONFIDENCE=80

# endregion: constants

[[ -f $VIDEO ]] || {
  echo "the benchmark video is missing: $VIDEO" >&2
  echo "set FASTEST_SCAN_BENCH_VIDEO to its path" >&2
  exit 1
}

scripts/build.sh

rm -rf "$OUT_DIR"
mkdir -p "$PAGES_DIR"

cache_arguments=(--cache-dir "$CACHE_DIR")
cache_note="frame cache: $CACHE_DIR"
if [[ $NO_CACHE != 0 ]]; then
  cache_arguments=()
  cache_note="no frame cache"
fi

start_seconds=$(date +%s.%N)
zig-out/bin/fastest-scan "$VIDEO" -o "$PDF" "${cache_arguments[@]}" --verbose 2>&1 |
  grep --invert-match --extended-regexp 'PPS changed|Last message repeated' || true
end_seconds=$(date +%s.%N)
run_seconds=$(awk "BEGIN { printf \"%.1f\", $end_seconds - $start_seconds }")

pdfimages -j "$PDF" "$PAGES_DIR/page"
page_count=$(find "$PAGES_DIR" -name 'page-*.jpg' | wc --lines)
pdf_bytes=$(stat --format %s "$PDF")

# OCR on a part of the pages: the mean word confidence and the number of good words.
ocr_pages=0
ocr_words=0
ocr_good_words=0
ocr_confidence_sum=0
index=0
while IFS= read -r page; do
  if ((index % OCR_STEP == 0)); then
    tsv=$(tesseract "$page" stdout -l "$OCR_LANGUAGE" --psm 3 tsv 2>/dev/null || true)
    read -r words good sum < <(awk -F '\t' -v conf="$TSV_CONFIDENCE_COLUMN" -v text="$TSV_TEXT_COLUMN" -v good="$GOOD_WORD_CONFIDENCE" '
      NR > 1 && $conf >= 0 && length($text) > 1 { n++; s += $conf; if ($conf >= good) g++ }
      END { printf "%d %d %.1f\n", n, g, s }' <<<"$tsv")
    ocr_pages=$((ocr_pages + 1))
    ocr_words=$((ocr_words + words))
    ocr_good_words=$((ocr_good_words + good))
    ocr_confidence_sum=$(awk "BEGIN { printf \"%.1f\", $ocr_confidence_sum + $sum }")
  fi
  index=$((index + 1))
done < <(find "$PAGES_DIR" -name 'page-*.jpg' | sort)
mean_confidence=$(awk "BEGIN { if ($ocr_words > 0) printf \"%.1f\", $ocr_confidence_sum / $ocr_words; else print \"0.0\" }")

echo
echo "benchmark result"
echo "  video              $VIDEO"
echo "  pages              $page_count (expected $EXPECTED_PAGES)"
echo "  run time           $run_seconds s ($cache_note)"
echo "  PDF size           $pdf_bytes bytes"
echo "  bytes per page     $((pdf_bytes / (page_count > 0 ? page_count : 1)))"
echo "  OCR pages          $ocr_pages (every ${OCR_STEP}th page, language $OCR_LANGUAGE)"
echo "  OCR words          $ocr_words"
echo "  OCR good words     $ocr_good_words (confidence >= $GOOD_WORD_CONFIDENCE)"
echo "  OCR mean confidence $mean_confidence"

if [[ $page_count != "$EXPECTED_PAGES" ]]; then
  echo "the page count is not the expected count" >&2
  exit 1
fi
