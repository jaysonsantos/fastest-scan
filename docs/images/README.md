# The pictures of the README

Each picture comes from a run of the program or of the app, at the commit
`7e00753`, on 2026-10-12. No picture is drawn by hand. ImageMagick puts the parts
of a picture side by side and makes them small.

The videos are not in the repository. The debug pictures come from this command:

```sh
zig-out/bin/fastest-scan video.mp4 -o out/book.pdf --debug-dir out/debug --debug-layers
```

| Picture | Run | Parts, from the left |
|---|---|---|
| `frame-to-pages.jpg` | The benchmark video, two passes: 63 pages. | `frames/f_000885.jpg`, `pages/p_005_0.jpg`, `pages/p_005_1.jpg`. |
| `repair.jpg` | The same run. | `layers/p_005_1_00.jpg` (the page of the reference frame, before the repair), `pages/p_005_1.jpg`, `faults/p_005_1.jpg`. |
| `colored-page.jpg` | The desk recording of decision 0026, two passes: 2 pages. | A part of `frames/f_000090.jpg`, `pages/p_000_0.jpg`, `pages/p_000_1.jpg`. |
| `android-video-scan.png` | The app on the Android emulator. It scans a clip of 30 seconds of the benchmark video: 11 pages. | The lower part of two screenshots (`adb exec-out screencap -p`): during the scan, and after it. |

The colours on a frame: green is the outline of the left page, blue is that of the
right page, and the red dots are the cells that the program takes for covered, for
example by a hand. `src/cli/debug.zig` has the colours of a map of repairs.

## A new picture

- Make it from a run, and add a row to the table.
- Keep each file below 512 kB: the large-file hook stops a larger one.
- Look at the picture before the commit. It must show no private thing: no
  address, no name, no document of a person. Cut a frame to the book when the desk
  has other things on it.
- No picture of the camera mode of the app is here yet. It needs a phone and a
  book: take a screenshot during a scan, and cut the status bar of the phone.
