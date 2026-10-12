#!/usr/bin/env bash
# Build the Android app: the native library with Zig, then the APK with Gradle.
# The tools come from the Android shell of the flake, which needs the licence of
# the Android SDK:
#
#   NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ACCEPT_ANDROID_SDK_LICENSE=1 \
#     nix develop --impure .#android --command scripts/build-android.sh
#
# The result is android/app/build/outputs/apk/debug/app-debug.apk.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$script_dir")"

: "${ANDROID_NDK_HOME:?run this script in the Android shell of the flake: see the top of the script}"

# The JNI libraries for a phone (arm64-v8a) and for the emulator (x86_64), in
# zig-out/android/jniLibs/. The app takes them from there.
zig build android --release=fast -Dandroid-ndk="$ANDROID_NDK_HOME"

cd android
gradle --no-daemon assembleDebug "$@"
