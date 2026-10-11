#!/usr/bin/env bash
# Extract the frames of the three studied spreads ONCE (one decode pass, 4 threads).
# JPEG q:v 1 (not exact PNG). Output: frames/f_<index>.jpg with the CSV frame index.
set -euo pipefail
cd "$(dirname "$0")"
VIDEO=${FASTEST_SCAN_BENCH_VIDEO:-$HOME/VID_20261009_180010.mp4}
mkdir -p frames_raw frames
ffmpeg -v error -threads 4 -t 41.4 -i "$VIDEO" \
  -vf "select='between(n,462,578)+between(n,795,925)+between(n,1062,1165)'" \
  -fps_mode passthrough -q:v 1 frames_raw/out_%05d.jpg
i=1
for n in $(seq 462 578) $(seq 795 925) $(seq 1062 1165); do
  src=$(printf "frames_raw/out_%05d.jpg" "$i")
  [ -f "$src" ] || { echo "missing $src for frame $n" >&2; exit 1; }
  mv "$src" "$(printf "frames/f_%06d.jpg" "$n")"
  i=$((i+1))
done
rmdir frames_raw
ls frames | wc -l
