#!/usr/bin/env bash
# Run the tests of the Android app on the phone or the emulator that adb shows.
# Run this script in the Android shell of the flake: see scripts/build-android.sh.
#
#   scripts/test-android.sh                     # a synthetic video: one minute
#   scripts/test-android.sh <video> <pages>     # a recorded video and its page count
#
# With a video, the script copies the video to the device, scans it with the decoder
# of the device, and copies the PDF and a report with the times and the memory to
# out/android/. The video stays on the device, in the files directory of the app.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$script_dir")"

# region: constants

readonly APP_PACKAGE=br.com.jayson.fastestscan
readonly TEST_RUNNER="$APP_PACKAGE.test/androidx.test.runner.AndroidJUnitRunner"
readonly VIDEO_TEST="$APP_PACKAGE.VideoScanTest"
readonly DEVICE_DIR="/sdcard/Android/data/$APP_PACKAGE/files"
readonly DEVICE_VIDEO=video.mp4
readonly OUT_DIR=out/android

# endregion: constants

scripts/build-android.sh

if [[ $# -eq 0 ]]; then
  # Gradle installs the app, runs the tests, and removes the app again.
  (cd android && gradle --no-daemon connectedDebugAndroidTest)
  exit 0
fi

video="$1"
pages="${2:?give the number of pages that the video has}"
[[ -f $video ]] || {
  echo "the video is missing: $video" >&2
  exit 1
}

# The app stays on the device: Gradle removes the files of the app with the app.
(cd android && gradle --no-daemon installDebug installDebugAndroidTest)
adb shell mkdir -p "$DEVICE_DIR"
adb push "$video" "$DEVICE_DIR/$DEVICE_VIDEO"
# `am instrument` gives the exit code 0 also for a test that failed: read the result.
result="$(adb shell am instrument -w -e class "$VIDEO_TEST" -e video "$DEVICE_VIDEO" -e pages "$pages" "$TEST_RUNNER")"
echo "$result"

mkdir -p "$OUT_DIR"
adb pull "$DEVICE_DIR/scan.pdf" "$OUT_DIR/scan.pdf" || true
adb pull "$DEVICE_DIR/scan-report.txt" "$OUT_DIR/scan-report.txt" || true
[[ -f $OUT_DIR/scan-report.txt ]] && cat "$OUT_DIR/scan-report.txt"

[[ $result == *"OK (1 test)"* ]] || {
  echo "the video test failed" >&2
  exit 1
}
