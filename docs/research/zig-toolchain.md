# Research: the Zig 0.17 toolchain and standard library

Source: a research agent, 2026-10-09, on Linux x86_64 (CachyOS, 16 threads). The
agent compiled and ran every statement on this page, unless the statement has the
word "unverified". Its probe project was in a scratch directory and is gone.

Read this page before you use a standard library API from memory. The API changed
much from Zig 0.14 to 0.17.

## Versions

| Item | Result |
|---|---|
| Latest stable Zig | 0.17.0, released 2026-10-01 |
| `nixpkgs#zig` | 0.16.0. Use `pkgs.zig_0_17`. |
| `zls` in nixpkgs | 0.16.0. It does not support Zig 0.17: modules from `build.zig` do not resolve. |
| `pkgs.zigscient` | 0.17.0, a language server that takes the place of `zls`. Hover and go-to-definition work. |
| Zig 0.16.0 on this host | Debug builds with libc fail to link outside `mkShell` (`unhandled relocation type R_X86_64_PC64`). 0.17.0 links. |

The flake of this repository uses `pkgs.mkShell` with `pkgs.zig_0_17`. Only
`x86_64-linux` was run.

## Patterns that work in 0.17.0

- Entry point: `pub fn main(init: std.process.Init) !u8`. It gives `init.io`,
  `init.gpa`, `init.arena`, `init.environ_map`, and `init.minimal.args`.
- Arguments: `try init.minimal.args.toSlice(arena)` gives `[]const [:0]const u8`.
- Environment: `init.environ_map.get("HOME")`.
- stdout: `var w: std.Io.File.Writer = .init(.stdout(), io, &buffer);` then
  `w.interface.print(...)` and `flush()`. stderr: `std.debug.print`.
- Files: `std.Io.Dir.cwd().createFile(io, path, .{})`, `file.close(io)`,
  `file.readPositionalAll(io, buffer, offset)`, `file.writePositionalAll(io, bytes,
  offset)`. A file writer gives its position with `logicalPos()`. `close` does not
  flush.
- Child process: `std.process.spawn(io, .{ .argv = ..., .stdout = .pipe })`, then
  `child.stdout.?.readerStreaming(io, &buffer)`, `reader.interface.readSliceShort`,
  `child.wait(io)`, `term.success()`, `child.kill(io)`.
- All output of a short command: `std.process.run(gpa, io, .{ .argv = ... })`.
- Jobs on threads: `var group: std.Io.Group = .init; group.async(io, f, .{...});
  try group.await(io);`. A job returns `void` or `std.Io.Cancelable!void`.
  `group.async` can run the job on the caller thread; `group.concurrent` always
  takes another thread.
- Time: `const t0 = std.Io.Timestamp.now(io, .awake);` then
  `t0.untilNow(io, .awake).toMilliseconds()`.
- Lists: `var list: std.ArrayList(T) = .empty; try list.append(gpa, x);
  list.deinit(gpa);`.
- Tests: `std.testing.io`, `std.testing.allocator`, `std.testing.tmpDir(.{})`.
- Formatting: `std.mem.print(&buffer, fmt, args)` and `allocator.print(fmt, args)`.
  `std.fmt.bufPrint` and `std.fmt.allocPrint` still compile but are deprecated.
- C code: `@cImport` is removed. Use `extern fn` declarations with
  `module.addCSourceFile`, or the `translate_c` package pinned at `#2.0.0`.

## Old form to new form

"both" = breaks in 0.16 and 0.17. "0.17" = breaks only in 0.17.

### Language

| Old form | New form | In |
|---|---|---|
| `[_]u8{0} ** 16` | `const z: [16]u8 = @splat(0);` | 0.17 |
| `@cImport({ @cInclude("x.h"); })` | `extern fn`, or translate-c in `build.zig` | 0.17 |
| `@typeInfo(T).@"struct".fields` | `.field_names`, `.field_types`, `.field_attrs` | 0.17 |
| `callconv(.C)` | `callconv(.c)` | both |
| `v[i]` on a `@Vector` with a runtime `i` | `const arr: [4]u8 = v; arr[i]` | both |
| `usingnamespace` | explicit declarations | both |
| `async f()` / `await` | `io.async(f, .{})` / `future.await(io)` | both |
| `.Monotonic` | `.monotonic` | both |
| `optimize != .Debug`, `.ReleaseFast` | `.debug`, `.safe`, `.fast`, `.small` | 0.17 |
| `std.builtin.X` | `std.lang.X` (the old name is a deprecated alias) | 0.17 |
| `format(self, comptime fmt, options, writer)` with `{}` | `pub fn format(self: T, w: *std.Io.Writer) std.Io.Writer.Error!void` with `{f}`. The old method gives no error and no output of its own. | both |
| `print("{}", .{slice})` | `{s}` or `{any}` | both |

### Input, output, and files

| Old form | New form | In |
|---|---|---|
| `std.io.getStdOut().writer()` | `std.Io.File.Writer` with `.init(.stdout(), io, &buffer)` | both |
| `std.io.bufferedWriter(f.writer())` | `f.writer(io, &buffer)`; the buffer is in the writer | both |
| `std.fs.cwd().createFile(p, .{})`, `f.close()`, `f.writeAll(b)` | `std.Io.Dir.cwd().createFile(io, p, .{})`, `f.close(io)`, `f.writeStreamingAll(io, b)` | both |
| `f.getPos()`, `std.io.countingWriter` | `file_writer.logicalPos()` | both |
| `std.io.fixedBufferStream(&buf)` | `var w: std.Io.Writer = .fixed(&buf)`; `var r: std.Io.Reader = .fixed(bytes)` | both |
| `std.io.AnyWriter`, `writer: anytype` | `w: *std.Io.Writer` | both |
| `f.reader()` | `f.reader(io, &buf)` or `f.readerStreaming(io, &buf)`, then `.interface` | both |
| `f.readAll(&b)`, `r.readNoEof(&b)` | `r.readSliceShort(&b)` (gives the count), `r.readSliceAll(&b)` | both |
| `dir.readFileAlloc(a, path, max)` | `dir.readFileAlloc(io, path, a, .unlimited)` | both |

### Process, memory, threads, time

| Old form | New form | In |
|---|---|---|
| `std.process.argsAlloc(a)` | `init.minimal.args.toSlice(arena)` | both |
| `std.process.Child.init(argv, a)`, `.stdout_behavior = .Pipe`, `child.spawn()` | `std.process.spawn(io, .{ .argv = ..., .stdout = .pipe })` | both |
| `term.Exited == 0` | `term.success()` | 0.17 adds it |
| `std.posix.getenv`, `std.process.getEnvVarOwned` | `init.environ_map.get("HOME")` | both |
| `std.heap.GeneralPurposeAllocator(.{}){}` | `init.gpa`, or `std.heap.SafeAllocator` | both |
| `std.ArrayList(T).init(a)`, `list.append(x)` | `var l: std.ArrayList(T) = .empty; l.append(gpa, x)` | both |
| `std.BoundedArray(u8, 8)` | `var l: std.ArrayList(u8) = .initBuffer(&storage); try l.appendBounded(x)` | both |
| `a.dupeZ(u8, s)` | `a.dupeSentinel(u8, s, 0)` | 0.17 |
| `std.fmt.bufPrint`, `std.fmt.allocPrint(a, ...)` | `std.mem.print(&buf, fmt, args)`, `a.print(fmt, args)`. The old forms compile. | 0.17 |
| `std.Thread.Pool`, `WaitGroup` | `std.Io.Group` | both |
| `std.Thread.Mutex` | `var m: std.Io.Mutex = .init; try m.lock(io); m.unlock(io)` | both |
| `std.time.Timer`, `milliTimestamp()` | `std.Io.Timestamp.now(io, .awake)` | both |
| `std.Thread.sleep(ns)` | `try io.sleep(.fromMilliseconds(5), .awake)` | both |
| `std.atomic.Atomic`, `std.rand`, `std.sort.sort` | `std.atomic.Value`, `std.Random`, `std.mem.sort` | both |

Still valid: `std.Thread.spawn`, `std.Thread.getCpuCount()`, `std.AutoHashMap`,
`std.fs.path.join`, `std.mem.splitScalar`, `std.fmt.parseInt`, `std.debug.print`.

### Build system

| Old form | New form | In |
|---|---|---|
| `b.addExecutable(.{ .name, .root_source_file, .target, .optimize })` | `.root_module = b.createModule(.{ ... })` | both |
| `b.addTest(.{ .root_source_file = ... })` | `b.addTest(.{ .root_module = mod })` | both |
| `.{ .path = "src/main.zig" }` | `b.path("src/main.zig")` | both |
| `exe.linkLibC()` | `.link_libc = true` in `createModule` | both |
| `b.addStaticLibrary(...)` | `b.addLibrary(.{ .name, .linkage = .static, .root_module })` | both |
| `if (b.args) \|args\| run.addArgs(args);` | `run.addPassthruArgs();` | 0.17 |
| `b.addFmt(.{ .paths = &.{"src"} })` | `.paths = b.pathList(&.{"src"})` | 0.17 |
| zon `.name = "probe"`, no fingerprint | `.name = .probe`, `.fingerprint = 0x...` (run `zig build` for the value) | both |
| `-Doptimize=ReleaseFast` | `-Doptimize=fast`, or `--release=fast`. The old spelling still works. | 0.17 |

## Behaviour without a compile error

| Gotcha | Action |
|---|---|
| LLVM loop vectorization is off in 0.16 and 0.17. A scalar pixel loop gets no automatic SIMD. | Write `@Vector` code for hot loops. Measure only in `fast` or `safe` mode. |
| An explicit `-Dtarget=...` resets the CPU to the baseline. `std.simd.suggestVectorLength(u8)` goes from 32 to 16. | Add `-Dcpu=native` or `-Dcpu=x86_64_v3`. |
| `close` does not flush. `error.WriteFailed` and `error.ReadFailed` are generic. | Call `flush()`. Read the cause from `file_writer.err` or `file_reader.err`. |
| A test that prints to stderr makes `zig build test` print `failed command`, with exit code 0. | Do not print in tests. |
| The first `zig build` with an empty global cache takes more than 2 minutes: Zig builds its build runner. | Keep `~/.cache/zig`. Cache it in CI. |
| `nixpkgs#zlint` is an X.509 certificate linter. | The Zig linter is `nixpkgs#zig-zlint`. |
| `init.gpa` is `c_allocator` in fast mode with libc, and `smp_allocator` without libc. It reports no leaks then. | Run the tests in debug mode for leak checks. |
| Zig compiles C with UBSan in debug mode. | Not relevant here: the repository has no C code. |

## Lint and format tools

| Tool | Command | Note |
|---|---|---|
| zig fmt | `zig fmt --check src build.zig build.zig.zon` | The prek hook runs it. |
| AST check | `zig ast-check <file>` | Finds unused locals. `zig build check` finds more. |
| ziglint 0.5.3 (`nixpkgs#ziglint`) | `ziglint --ignore Z006 --ignore Z024 src build.zig` | Reports deprecated std API (Z011). Not in the flake yet. |
| zlint 0.9.1 (`nixpkgs#zig-zlint`) | `zlint` | Not in the flake yet. |

## Build times (Zig 0.17.0, on a loaded machine)

| Case | Debug | fast |
|---|---|---|
| Clean build, warm global cache | 1.7 to 2.7 s | 15 to 20 s |
| Rebuild after one change | 0.4 s | 12 to 14 s |
| No change | 0.05 s | 0.04 s |

- Debug mode uses the self-hosted x86_64 backend. The fast and safe modes use LLVM.
- `zig build --watch` and `zig build test --watch` work: 0.5 s per change.
- `zig build --watch -fincremental` compiles a change in 14 to 38 ms. On tmpfs the
  steps after the compile step did not run again (the install step said `cached`).
  The behaviour on btrfs is unverified.
