//! fastest-scan: the command-line program on top of the fastscan library.

const std = @import("std");
const Io = std.Io;
const fastscan = @import("fastscan");
const args = @import("args.zig");
const ffmpeg = @import("ffmpeg.zig");
const pipeline = @import("pipeline.zig");
const stream = @import("stream.zig");
const system = @import("system.zig");

const exit_code = struct {
    const ok = 0;
    const failed = 1;
    const usage = 2;
};

const stdout_buffer_bytes = 4096;
/// A worker runs `pipeline.decoders_per_worker` decoders, each with one thread.
const cpu_threads_per_worker = pipeline.decoders_per_worker;
const percent = 100.0;
const bytes_per_megabyte = 1024 * 1024;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [stdout_buffer_bytes]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const raw_arguments = try init.minimal.args.toSlice(arena);
    const arguments = try arena.alloc([]const u8, raw_arguments.len -| 1);
    for (arguments, 0..) |*argument, index| argument.* = raw_arguments[index + 1];

    const environment: args.Environment = .{ .context = init.environ_map, .getFn = lookupEnvironment };
    const action = args.parse(arguments, environment) catch |err| {
        std.debug.print("error: {t}\n{s}\nRun with --help for the list of options.\n", .{ err, args.usage_line });
        return exit_code.usage;
    };
    switch (action) {
        .help => try stdout.writeAll(args.help_text),
        .version => try stdout.print("fastest-scan {s}\n", .{fastscan.version}),
        .run => |config| run(init, &config, stdout) catch |err| {
            std.debug.print("error: {t}\n", .{err});
            return exit_code.failed;
        },
    }
    // A flush that fails is an error of the program: its last line did not go out.
    stdout.flush() catch |err| {
        // The writer interface gives a general error; the file writer keeps the cause.
        if (stdout_writer.err) |cause| {
            std.debug.print("error: cannot write to the standard output: {t}\n", .{cause});
        } else {
            std.debug.print("error: cannot write to the standard output: {t}\n", .{err});
        }
        return exit_code.failed;
    };
    return exit_code.ok;
}

fn lookupEnvironment(context: ?*const anyopaque, name: []const u8) ?[]const u8 {
    const map: *const std.process.Environ.Map = @ptrCast(@alignCast(context.?));
    return map.get(name);
}

fn run(init: std.process.Init, config: *const args.Config, stdout: *Io.Writer) !void {
    const io = init.io;
    const gpa = init.gpa;
    const start = Io.Timestamp.now(io, .awake);

    const info = try ffmpeg.probe(io, gpa, config.ffprobe, config.input);
    defer info.deinit(gpa);
    const worker_count: usize = if (config.jobs > 0)
        config.jobs
    else
        @max(1, (std.Thread.getCpuCount() catch 1) / cpu_threads_per_worker);
    // The stream mode has one decoder, and its workers only render.
    if (config.stream) return stream.run(io, gpa, config, &info, worker_count, stdout);
    if (config.verbose) {
        std.debug.print("video: {d}x{d}, {d} frames, {d:.1} s; {d} workers, {d} decoders\n", .{
            info.width,
            info.height,
            info.frames.len,
            info.seconds(info.frames.len - 1),
            worker_count,
            worker_count * pipeline.decoders_per_worker,
        });
    }

    const analysis = try pipeline.analyze(io, gpa, config, &info, worker_count);
    defer analysis.deinit(gpa);
    var detected: usize = 0;
    for (analysis.observations[analysis.first_frame..analysis.end_frame]) |*observation| {
        if (observation.detected) detected += 1;
    }
    const analysis_ms = start.untilNow(io, .awake).toMilliseconds();
    if (config.verbose) {
        std.debug.print("analysis: {d} frames, pages detected in {d}, {d} ms\n", .{
            analysis.end_frame - analysis.first_frame,
            detected,
            analysis_ms,
        });
    }

    const duration = info.seconds(info.frames.len - 1);
    const frames_per_second: f32 = if (duration > 0)
        @floatCast(@as(f64, @floatFromInt(info.frames.len - 1)) / duration)
    else
        fastscan.timeline.Options.reference_frame_rate;
    const timeline = try fastscan.timeline.build(gpa, analysis.observations, .{ .frames_per_second = frames_per_second });
    defer timeline.deinit(gpa);
    try pipeline.writeTimelineDebug(io, gpa, config, &info, &analysis, &timeline);

    if (config.verbose) {
        std.debug.print("timeline: {d} spreads, {d} pages\n", .{ timeline.segments.len, timeline.pageCount() });
    }

    const document = try pipeline.renderDocument(io, gpa, config, &info, &analysis, &timeline, worker_count);
    defer document.deinit(gpa);
    const render_ms = start.untilNow(io, .awake).toMilliseconds();
    if (config.verbose) {
        std.debug.print("render: {d} spreads ({d} duplicates removed), {d} pages of {d}x{d}, {d} with the curl correction, {d} ms\n", .{
            document.spreads,
            document.duplicate_spreads,
            document.pages.len,
            document.page_size.width,
            document.page_size.height,
            document.curled_pages,
            render_ms - analysis_ms,
        });
        std.debug.print("fusion: {d} donor pages registered; mean page area with glare {d:.2} %, covered {d:.2} %, outside the frame {d:.2} %, not repaired {d:.2} % (no donor agreed: {d:.2} %)\n", .{
            document.donors_used,
            document.glare * percent,
            document.cover * percent,
            document.outside * percent,
            document.unrepaired * percent,
            document.rejected * percent,
        });
        std.debug.print("fingers: mean page area painted {d:.2} %; a finger stays on {d:.2} % of the page area, on {d} pages\n", .{
            document.painted * percent,
            document.finger_left * percent,
            document.finger_pages,
        });
        std.debug.print("memory: {d} large blocks from the system, {d} MB; a large block was used again {d} times\n", .{
            document.memory.fresh_blocks,
            document.memory.fresh_bytes / bytes_per_megabyte,
            document.memory.reused_blocks,
        });
        std.debug.print("decode: the render pass needs {d} full-size frames; with no frame cache, the decoders decode {d} frames for them\n", .{
            document.frames_needed,
            document.frames_to_decode,
        });
        if (system.peakMemoryBytes(io)) |bytes| {
            std.debug.print("memory: at most {d} MB in this process\n", .{bytes / bytes_per_megabyte});
        }
    }

    const pdf_bytes = try pipeline.writePdf(io, gpa, config.output, &document, config.dpi);
    try stdout.print("{s}: {d} pages, {d} bytes, {d} ms\n", .{
        config.output,
        document.pages.len,
        pdf_bytes,
        start.untilNow(io, .awake).toMilliseconds(),
    });
}

test {
    _ = args;
    _ = ffmpeg;
    _ = pipeline;
    _ = stream;
    _ = system;
    _ = @import("parallel.zig");
}
