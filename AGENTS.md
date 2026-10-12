# fastest-scan

A Zig library and a command-line program. The input is a phone video of the pages of
a book, a booklet, or a document. The output is a PDF with one clean image per page.

Read `docs/status.md` first. It says what works, what does not, and what is next.

## Paths

| Path | Purpose |
|---|---|
| `src/lib/` | The library `fastscan`. All image processing. No file access, no processes. |
| `src/lib/root.zig` | The Zig interface of the library. |
| `src/lib/c_api.zig`, `include/fastscan.h` | The C interface, for an Android (JNI) app or another language. |
| `src/cli/` | The program `fastest-scan`: arguments, `ffmpeg` processes, threads, the output file. |
| `build.zig`, `build.zig.zon` | The build. `build.zig.zon` holds the only version number. |
| `scripts/` | `lint.sh`, `test.sh`, `all.sh`, `build.sh`, `bench.sh`, `release.sh`. |
| `docs/status.md` | The state of the work and the next steps. Change it in each commit that changes the state. |
| `docs/decisions/` | One file per design decision, with the reason. |
| `docs/research/` | The research behind the decisions, with sources. |
| `docs/benchmark-log.md` | One row per benchmark run: page count, time, size, OCR numbers. |
| `docs/references.md`, `docs/references.bib` | The credits: every paper, standard, and program that the code uses, as a table and as BibTeX. |
| `prototypes/` | Python experiments that came before a part of the Zig code. A record, not product code. No linter checks it. |
| `.forgejo/workflows/` | CI for the Forgejo host. The jobs run on the host of the runner (label `cachyos-nix`), not in a container. `.github/actionlint.yaml` holds only the actionlint config. |

## Commands

- Dev shell: `nix develop`, or direnv. `.envrc` is local and has three lines:
  `source_up_if_exists`, `use flake`, `dotenv_if_exists .env`.
- Build (debug): `zig build`. Build (fast): `scripts/build.sh`.
- Run: `zig build run -- <video> -o out.pdf`, or `zig-out/bin/fastest-scan`.
- Test: `scripts/test.sh`. One file: `zig test src/lib/geometry.zig`.
- Lint: `scripts/lint.sh`. One linter: `prek run <hook-id> --all-files`.
  `scripts/check-deprecated.sh` finds a deprecated name of the Zig standard
  library; the compiler gives no warning for it.
- Lint and test: `scripts/all.sh`.
- Benchmark: `scripts/bench.sh`. It needs the video of `FASTEST_SCAN_BENCH_VIDEO`.
  `BENCH_NO_CACHE=1` runs it with no frame cache: the time that a user gets.
  The OCR sample of 16 pages is noisy. For a decision about quality, run
  `BENCH_OCR_STEP=1 scripts/bench.sh` and look at `faults/` in the debug directory.
- Debug pictures: `--debug-dir DIR`. `faults/` shows what the fusion did in each
  cell, and `cover/` shows where the frames give no data. Add `--debug-layers` for
  the page of each frame before the fusion: the input for a prototype.
- Profile: `nix shell --inputs-from . nixpkgs#perf --command perf record -g --
  zig-out/bin/fastest-scan <video> -o out/perf.pdf --cache-dir .cache`, then
  `perf report --no-children --sort symbol`. Compare the CPU time (`user` of
  `time`), not the run time: the run time depends on the other work of the machine.
- Release: `scripts/release.sh`, then `git push --follow-tags`.

## Rules

- Never commit a video, a decoded frame, or a benchmark output. `.gitignore` and the
  large-file hook block them. Keep such files in `.cache/`, `out/`, or outside the
  repository.
- Use Zig 0.17. The standard library changed much between releases: read
  `docs/research/zig-toolchain.md` before you use an API from memory.
- The library must not import `std.Io`, `std.fs`, `std.process`, or `std.Thread`.
  The caller gives frames and receives bytes. Threads belong to the caller.
- The library has no C dependency.
- The library frees each block that it takes, also from a `scratch` allocator: do
  not rely on an arena. The CLI gives each worker a `memory.BlockCache`, which uses
  a large block again for the next request of the same size (decision 0017).
- Free a block also when a later step fails: put the `defer` or the `errdefer`
  directly after the allocation. Each entry point of the library has a test with
  `alloc_check.eachFailure`, which makes each allocation fail one time. A new
  entry point gets such a test. Do not use
  `std.testing.checkAllAllocationFailures`: it needs the same number of
  allocations in each run, and a list that grows does not give that.
- Keep the name of an error. Do not change each error into one name, and do not
  drop an error with `catch {}`: handle the errors that have a meaning (for
  example `error.FileNotFound` for a cache), and give the others to the caller.
- Credit every source. Name the paper (authors, title, year) in the comment of the
  algorithm. In the same commit, add it to `docs/references.md` (where it is used)
  and to `docs/references.bib` (the BibTeX entry). The README lists the main
  papers only.
- Never copy code from a program with a license that does not fit MIT (for example
  GPL). Take the idea, write the code new, and say so in `docs/references.md`.
- Use machine learning only when a phone runs the model fast. See decision 0008.
- A Python prototype can test an algorithm first. The product code stays in Zig.
- Give a name to each number with a meaning. Keep tuning constants in the `Options`
  struct or the constant block of their module, with the unit in the name or the
  comment.
- A coordinate is in pixels of the image that the comment names. Say which image.
- Write the docs, the commit bodies, and this file in Simplified Technical English.
- Commit messages follow Conventional Commits.
- When a decision changes, add a file in `docs/decisions/`. Do not rewrite an old one.
- A CI job assumes three tools of the runner host only: `nix`, `git`, and `node` (for
  the checkout action). Take each other tool from `flake.nix` with
  `nix develop --command`. Do not call a tool of the host in a workflow.

## Facts that surprise

- `ffmpeg` duplicates or drops frames of a variable-rate video unless the command has
  `-fps_mode passthrough`. The frame indexes then do not match the `ffprobe` list.
- `ffmpeg -ss <t> -noaccurate_seek` starts at the keyframe at or before `t`. The CLI
  relies on this for exact frame indexes.
- The `ffmpeg` of the nix shell cannot open VAAPI on a non-NixOS host. Use
  `--ffmpeg /usr/bin/ffmpeg --hwaccel vaapi` for hardware decode.
- Phone video is limited-range BT.709: paper white is near luma 160 to 235, not 255.
- `ffmpeg` takes one thread per CPU thread by default. A decoder with 16 threads
  uses 5 times the memory of one with 1 thread, and it decodes frames after the
  last frame that it gives. The CLI starts each decoder with `-threads 1` and
  runs many of them (decision 0020).
- The benchmark time with `--cache-dir` has no decoder in it. A run with no cache
  takes about three times as long: `BENCH_NO_CACHE=1 scripts/bench.sh`.
