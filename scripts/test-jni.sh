#!/usr/bin/env bash
# Test the JNI layer of the Android app on the Java machine of this computer: the
# same native code and the same Java class as in the app, with no Android tool.
# The JDK comes from the nix shell.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$script_dir")"

# region: constants

readonly JAVA_SOURCES=android/app/src/main/java
readonly NATIVE_CLASS="$JAVA_SOURCES/br/com/jayson/fastestscan/core/Native.java"
readonly TEST_CLASS=tests/jni/NativeSmoke.java
readonly CLASSES_DIR=zig-out/jni-test/classes
readonly LIBRARY_DIR=zig-out/lib

# endregion: constants

# The directory of the JDK: `javac` is in its `bin` directory.
java_home="${JAVA_HOME:-$(dirname "$(dirname "$(readlink --canonicalize "$(command -v javac)")")")}"

zig build jni -Djava-home="$java_home" "$@"

rm -rf "$CLASSES_DIR"
mkdir -p "$CLASSES_DIR"
javac -Xlint:all -Werror -d "$CLASSES_DIR" "$NATIVE_CLASS" "$TEST_CLASS"
# -Xcheck:jni makes the Java machine check each call of the native code.
java -Xcheck:jni -Djava.library.path="$LIBRARY_DIR" -cp "$CLASSES_DIR" NativeSmoke
