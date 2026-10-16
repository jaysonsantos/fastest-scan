# The Android app

The app in `android/` scans a book with the camera, or from a recorded video, and
writes a PDF. It uses the stream session of the library: see
`docs/decisions/0019-stream-session-for-a-phone.md`.

State on 2026-10-16: the app scans a recorded video on a phone (a REDMI Note 15
Pro+ 5G) and on the Android emulator. The benchmark video gives its 63 pages on
the two, and the PDF is correct. The camera of the phone scanned a paperback,
letters, and an invoice: decisions 0029 to 0033 use these scans. The list of what
is not verified is in decision 0019.

## Parts

| Path | Purpose |
|---|---|
| `include/fastscan.h`, `src/lib/c_api.zig` | The C interface of the library: the stream session. |
| `android/app/src/main/cpp/fastscan_jni.c` | The JNI layer: one native function for each C function. |
| `android/app/src/main/java/.../core/Native.java` | The declarations of the native functions. Java, so that a desktop test can compile it. |
| `android/app/src/main/java/.../core/ScanSession.kt` | One scan. It keeps the handles and the thread rules of the library. |
| `android/app/src/main/java/.../core/PdfName.kt` | The rule for the file name of the PDF. It uses no class of Android. |
| `android/app/src/main/java/.../source/CameraSource.kt` | The camera as a source of frames (CameraX). |
| `android/app/src/main/java/.../source/VideoFileSource.kt` | A recorded video as a source of frames (`MediaExtractor`, `MediaCodec`). |
| `android/app/src/main/java/.../ui/` | The one screen of the app, and the page outline on the preview. |
| `android/app/src/main/res/xml/file_paths.xml` | The directories that the `FileProvider` of the app gives to other apps. |
| `android/gradle/libs.versions.toml` | The versions of the Android Gradle plugin and of the libraries. |
| `android/app/src/test/` | The unit tests on the Java machine of the computer. `gradle testDebugUnitTest` runs them. |
| `android/app/src/androidTest/` | The tests that run on a phone or an emulator. `scripts/test-android.sh` runs them. |
| `tests/c_api.c` | A C program on the header. `zig build test` runs it. |
| `tests/jni/NativeSmoke.java` | A Java program on the JNI layer. `scripts/test-jni.sh` runs it. |

## Test with no Android tool

These two checks need only the usual dev shell (`nix develop`):

```sh
scripts/test.sh        # the unit tests, and the C program on the header
scripts/test-jni.sh    # the JNI layer on the Java machine of this computer
```

`scripts/test-jni.sh` builds `libfastscan_jni.so` for this computer, compiles
`Native.java` and the test, and runs the test with `-Xcheck:jni`. The native code
and the Java class are the files of the app.

To see what the app gets from a video, run the stream session on a desktop:

```sh
scripts/build.sh
zig-out/bin/fastest-scan video.mp4 -o out/stream.pdf --stream --verbose
```

## Build the app

The build needs the Android SDK and the NDK. The SDK has a licence of Google that
each user must accept, and it is not free software. The Android shell of
`flake.nix` gives the SDK only to a person who says that they accept the licence,
with two variables:

```sh
NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ACCEPT_ANDROID_SDK_LICENSE=1 \
  nix develop --impure .#android --command scripts/build-android.sh
```

The first run downloads about 3.3 GB: the SDK platform, the build tools, the NDK,
the emulator, one system image, Gradle, and the libraries of the app.

The script has two steps:

1. `zig build android --release=fast -Dandroid-ndk="$ANDROID_NDK_HOME"` makes
   `zig-out/android/jniLibs/<ABI>/libfastscan_jni.so` for `arm64-v8a` (a phone) and
   `x86_64` (the emulator of a desktop).
2. `gradle assembleDebug` in `android/` makes
   `android/app/build/outputs/apk/debug/app-debug.apk`. The app takes the native
   libraries from `zig-out/android/jniLibs/`.

With no NDK, `zig build android` makes only the static libraries in
`zig-out/android/static/<ABI>/`. They show that the library compiles for the two
targets.

The unit tests of the app run on the Java machine of the computer, with no device.
Run them in the Android shell, in `android/`:

```sh
gradle testDebugUnitTest
```

Install the app on a phone with USB debugging, or on an emulator that runs:

```sh
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

## Test on a phone or an emulator

All commands of this section run in the Android shell of the flake.

Make a virtual device one time, and start the emulator. The emulator needs
`/dev/kvm`. `-no-window` runs it with no screen:

```sh
avdmanager create avd -n fastscan -k "system-images;android-36;default;x86_64" -d pixel_6
emulator -avd fastscan -no-window -no-audio -memory 8192 -cores 8
```

Then run the tests on the device that `adb devices` shows:

```sh
scripts/test-android.sh                    # a synthetic video: one minute
scripts/test-android.sh video.mp4 63       # a recorded video, and its page count when known
```

- With no argument, Gradle runs the tests of `android/app/src/androidTest/`.
  `NativeLibraryTest` scans a synthetic video of two pages: the check that the
  native library loads and works on the device.
- With a video, the script copies the video to the device and runs
  `VideoScanTest` with the decoder of the device. It copies `scan.pdf` and
  `scan-report.txt` to `out/android/`. The report has the page count, the time
  for a frame, the frames in memory, and the native memory. The app must be able
  to read the video: `adb push` gives a file that all can read, and `adb shell
  cp` does not.

The benchmark video (180 s) gives 63 pages in 151 s on the phone, and in 698 s on
the emulator: the software decoder of the emulator needs most of that time.
Decision 0019 has the numbers.

A phone with wireless debugging announces itself on the network. Find its address
and connect:

```sh
avahi-browse --resolve --terminate _adb-tls-connect._tcp
adb connect <address>:<port>
```

A Xiaomi phone asks on its screen for each install over adb ("Install via USB").
The install fails when no person answers in about 10 seconds. The script installs
two packages: the app and its tests.

To try the app by hand on a device with no camera scene, give it a video from the
shell. The app can read a file of its own directory. Start the app one time after
the install: Android makes the directory `files/` of the app at the first start.
Then copy the video with `run-as`, which works only on a debug build:

```sh
adb push video.mp4 /data/local/tmp/video.mp4
adb shell run-as br.com.jayson.fastestscan cp /data/local/tmp/video.mp4 files/video.mp4
adb shell rm /data/local/tmp/video.mp4
adb shell am start -a android.intent.action.VIEW -t video/mp4 \
  -d file:///data/user/0/br.com.jayson.fastestscan/files/video.mp4 \
  -n br.com.jayson.fastestscan/.ui.MainActivity
```

Do not push the video to `/sdcard/Android/data/br.com.jayson.fastestscan/files/`
on a new install. When `adb` makes that directory, the directory belongs to the
shell user, and the app cannot read the video: it shows "Failed to instantiate
extractor".

## Keep a video of a camera scan

A scan with the camera writes no video file: the library keeps only the frames
that it needs. So a scan that goes wrong cannot be done again. For a test, turn
on "Keep a video of the scan" before the scan. The camera then gives a third
stream, and the app writes it to a file while the scan runs. After the scan,
the screen and the log show the name of the file.

Copy the file to the computer and do the scan again with the desktop program,
in the flow of the app:

```sh
adb pull /sdcard/Android/data/br.com.jayson.fastestscan/files/Movies/scan-20261012-165209.mp4 out/
zig-out/bin/fastest-scan out/scan-20261012-165209.mp4 -o out/replay.pdf --stream -v --debug-dir out/replay
```

The video is not the same as the frames that the library got:

- On the phone of the tests the video has 1600 x 1200 pixels, the size of the
  preview. The frames for the library have 2880 x 2160 pixels. The camera of
  that phone gives no third stream of the large size next to the two other
  streams.
- The video has all frames of the camera. The library gets fewer frames: the
  camera drops the frames that come while the library works.
- The video has the compression of the encoder of the phone.

In a test on the phone, the scan with the camera and the scan of its video on
the desktop gave the same page: one page of a book on a white desk. With the
video stream on, the speed of the scan was the same as with it off.

## How the app uses the library

- A source gives each frame to `ScanSession.push` on its own thread: the camera
  thread, or the decoder thread. The library reads the buffers of the frame
  during the call only. It makes a copy of the frames that it keeps.
- The session makes its native stream with the first frame: the size and the
  rotation of the frames are known only then.
- The screen turns with the phone (`screenOrientation="fullUser"`), and the camera
  frames turn with the screen: `CameraSource` gives the rotation of the screen to
  the two streams of the camera. The library needs upright frames, because the
  fold of a book must go from the top to the bottom. For an open book, hold the
  phone on its side.
- The activity is not made new for a turn (`configChanges`): a new activity would
  lose the scan and its pages. `MainActivity.arrange` puts the panel with the
  text and the buttons below the picture or at its side.
- During a scan with the camera, the screen keeps its direction: a session has
  one rotation for all its frames.
- The preview and the frames for the library have the same shape, 4 x 3 parts.
  The screen then shows all that the library sees.
- The camera drops the frames that come while the library works on a frame.
  During a scan, `CameraSource` writes one line to the log for each 60 frames:
  the frames in a second that the library gets, and the time that it works on a
  frame. Read it with `adb logcat -s fastscan`. On the phone of the tests, on a
  white desk where each frame runs the three rules of the detector, the library
  gets 20 to 26 frames in a second and works 37 ms to 49 ms on a frame of 2880 x
  2160 pixels.
- `push` returns the status of the frame: the page corners, `steady`, and
  `captured`. The screen draws the outline of each page: white for a page that
  moves, yellow for a steady view, green when the user can turn the page.
- The corners are in pixels of the upright frame. Two maps of CameraX bring them
  to the screen: from the frame to the sensor
  (`ImageInfo.getSensorToBufferTransformMatrix`, inverted), and from the sensor to
  the preview view (`PreviewView.getSensorToViewTransform`). They are correct for
  each rotation and each shape of the two streams.
- After each `push`, the session gives each job that is ready to a render thread.
  A render thread has its own worker: the working memory of the library.
- One lock guards the functions of the native stream. The render of a job runs
  outside the lock.
- At the end, `finish` makes the last spreads final. When no job is left, the
  user can save the PDF.
- Another app can open a video with this app: the app has a filter for the
  action `VIEW` with a video.

## The name of the PDF

After a scan with pages, the panel shows a name field and a check box. "Save PDF"
and "Share" use the same file name:

```text
<prefix> <name>.pdf          for example: 2026-10-15 21-30 Scan.pdf
```

- The prefix is the local date and time when the user started the scan: the tap
  on "Scan", or the choice of a video. The format is `yyyy-MM-dd HH-mm`, with
  ASCII digits also in a language with other digits, for example Arabic.
- The name is the text of the field. Each new scan sets the field to `Scan`.
- The check box "Start the name with the date and time" turns the prefix on and
  off. The app keeps its value in `SharedPreferences`, also after a restart. The
  default is on.
- The rule removes `/ \ : * ? " < > |`, the control characters, and the spaces at
  the two ends. An empty name becomes `Scan`.
- The part before `.pdf` has at most 100 characters (Unicode code points) and at
  most 251 bytes in UTF-8. The file systems of Android take a file name of 255
  bytes at most, and one character can take 4 bytes.

`core/PdfName.kt` has the rule, and `android/app/src/test/` has its unit tests.
"Save PDF" gives the name to the "create document" dialog of the system. The
user can change the name there too.

## Share the PDF

"Share" sends the PDF to another app, for example Telegram or ChatGPT. The
button is on when "Save PDF" is on.

1. The app writes the PDF to `share/` in its cache directory, with the name of
   the panel. The bytes are the bytes of "Save PDF": the PDF has no time stamp.
2. The app starts the share sheet of the system (`Intent.createChooser`) with an
   `ACTION_SEND` intent of the type `application/pdf`. The intent has a content
   URI of the `FileProvider` in `EXTRA_STREAM` and in its `ClipData`, and
   `FLAG_GRANT_READ_URI_PERMISSION`. The other app can read this file only.
3. The other app gets the file name from the `FileProvider`.

When a new scan starts, the app deletes the files in `share/`. It deletes no file
of another directory. The app has one `FileProvider`, and
`res/xml/file_paths.xml` has one directory for each use.

## Settings and memory

`ScanOptions` has the settings that set the memory of a scan:

| Setting | Default | Effect |
|---|---|---|
| `donorFrames` | 4 | The other frames of a spread that repair glare and covered parts. A frame of 3840 x 2160 pixels takes 12 MB. |
| `maxHeldFrames` | 24 | The limit for the full-size frames in memory. At the limit, a spread gets fewer other frames. |
| `maxPageHeight` | 2000 | The largest height of a page image in pixels. The working memory of a render grows with the page area. |
| `renderThreads` | 2 | The threads that render pages. |

A render thread gives its working memory back to the system after each job.

With the defaults and frames of 3840 x 2160 pixels, the app holds at most 1137 MB
of native memory on the phone, and 774 MB on the emulator. The desktop program
holds 1.2 GB with the same settings. With one render thread, 2 other frames, and
a limit of 16 frames, the desktop program holds 0.7 GB, and the pages are worse.
The tables are in decision 0019.

The defaults give the best pages. They are too high for a phone with little
memory: no run with smaller settings was made on a phone.

## Limits

- The whole book must be inside the frame. On a dark surface a page can run out
  of the frame; on a bright surface it must not (decisions 0024 and 0026).
- On a bright desk, the paper must have another colour than the desk: cream
  paper on a white desk is found, white paper on a desk of the same white is
  not (decision 0026).
- The detector wants a stable view of each spread for 0.3 seconds, with the
  hands off most of the page.
- The video must have 8 bits per sample. A video with 10 bits (HDR) is not supported.
- The camera source asks for frames of 2880 x 2160 pixels (4 x 3 parts, 9 MB for
  each frame) and takes the nearest size that the phone gives. With smaller
  frames, the pages have fewer pixels.
- The screen does not turn while the phone is flat above the book: the phone
  cannot know its direction then. Turn the phone while it is upright, then point
  it down. The screen also does not turn when the user has locked the rotation
  of the screen.
- A change of the configuration that is not a turn makes the activity new, and
  the scan is lost: for example a change of the language or of the dark mode.
