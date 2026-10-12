//! The C interface of the library. `include/fastscan.h` declares these functions
//! and has the rules for the caller.
//!
//! The interface is the stream session of `stream.zig`: frames go in, in the order
//! of the video, and pages and PDF bytes come out. A JNI layer for an Android app
//! sits on top of it.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const image = @import("image.zig");
const intake = @import("intake.zig");
const detect = @import("detect.zig");
const document = @import("document.zig");
const finger = @import("finger.zig");
const jpeg = @import("jpeg.zig");
const pdf = @import("pdf.zig");
const memory = @import("memory.zig");
const stream = @import("stream.zig");

/// The memory of the sessions, the workers, and the pages. The tests take the
/// allocator that finds a block that was not freed.
const gpa: std.mem.Allocator = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

const version_z: [:0]const u8 = build_options.version ++ "";

/// The version of the library as a C string. The string lives as long as the program.
export fn fastscan_version() callconv(.c) [*:0]const u8 {
    return version_z.ptr;
}

// region: results

/// The result of a function. The values are a part of the interface: never change one.
const Result = enum(c_int) {
    ok = 0,
    out_of_memory = 1,
    invalid_argument = 2,
    invalid_frame = 3,
    stream_ended = 4,
    unsupported_dimensions = 5,
    write_failed = 6,

    fn message(self: Result) [:0]const u8 {
        return switch (self) {
            .ok => "no error",
            .out_of_memory => "the memory is full",
            .invalid_argument => "an argument is not valid",
            .invalid_frame => "the frame has another size than the stream, or a plane is too short",
            .stream_ended => "the stream has ended",
            .unsupported_dimensions => "a side of the page is zero or above 65535 pixels",
            .write_failed => "the write function reported an error",
        };
    }
};

fn resultOf(err: anyerror) c_int {
    const result: Result = switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidFrame => .invalid_frame,
        error.StreamEnded => .stream_ended,
        error.UnsupportedDimensions => .unsupported_dimensions,
        error.WriteFailed => .write_failed,
        else => .invalid_argument,
    };
    return @backingInt(result);
}

const ok: c_int = @backingInt(Result.ok);
const invalid_argument: c_int = @backingInt(Result.invalid_argument);

/// A text for a result code. The string lives as long as the program.
export fn fastscan_result_message(result: c_int) callconv(.c) [*:0]const u8 {
    inline for (@typeInfo(Result).@"enum".field_names) |name| {
        const value = @field(Result, name);
        if (@backingInt(value) == result) return value.message().ptr;
    }
    return "unknown result";
}

// endregion: results

// region: options

/// The same fields in the same order as `fastscan_options` of the header.
const Options = extern struct {
    struct_size: u32,
    width: u32,
    height: u32,
    rotation_degrees: u32,
    color_range: u32,
    color_matrix: u32,
    frames_per_second: f32,
    layout: u32,
    donor_frames: u32,
    max_held_frames: u32,
    max_page_height: u32,
    jpeg_quality: u32,
    dpi: u32,
    fingers: u32,
};

const default_donor_frames = 4;
const max_donor_frames = 12;
const min_jpeg_quality = 1;
const max_jpeg_quality = 100;
const min_dpi = 50;
const max_dpi = 1200;

/// Fill the options with the defaults. The caller then sets the frame size.
export fn fastscan_options_init(options: ?*Options) callconv(.c) void {
    const target = options orelse return;
    const page_limits: document.GeometryOptions = .{};
    target.* = .{
        .struct_size = @sizeOf(Options),
        .width = 0,
        .height = 0,
        .rotation_degrees = 0,
        .color_range = @backingInt(image.ColorRange.limited),
        .color_matrix = @backingInt(image.ColorMatrix.bt709),
        .frames_per_second = 0,
        .layout = layout_auto,
        .donor_frames = default_donor_frames,
        .max_held_frames = 0,
        .max_page_height = page_limits.max_height_px,
        .jpeg_quality = jpeg.Options.default_quality,
        .dpi = jpeg.Options.default_dpi,
        .fingers = fingers_all,
    };
}

const layout_auto = 0;
const layout_single = 1;
const layout_spread = 2;
const fingers_all = 0;
const fingers_blank = 1;
const fingers_keep = 2;

/// The options of the stream session for the options of the C caller.
fn streamOptions(options: *const Options) ?stream.Options {
    if (options.struct_size != @sizeOf(Options)) return null;
    if (options.width == 0 or options.height == 0) return null;
    const rotation = intake.Rotation.fromDegrees(std.math.cast(i32, options.rotation_degrees) orelse return null) orelse return null;
    const range: image.ColorRange = switch (options.color_range) {
        @backingInt(image.ColorRange.limited) => .limited,
        @backingInt(image.ColorRange.full) => .full,
        else => return null,
    };
    const matrix: image.ColorMatrix = switch (options.color_matrix) {
        @backingInt(image.ColorMatrix.bt709) => .bt709,
        @backingInt(image.ColorMatrix.bt601) => .bt601,
        else => return null,
    };
    const layout: detect.LayoutMode = switch (options.layout) {
        layout_auto => .auto,
        layout_single => .single,
        layout_spread => .spread,
        else => return null,
    };
    const paint: finger.Paint = switch (options.fingers) {
        fingers_all => .all,
        fingers_blank => .blank_paper,
        fingers_keep => .none,
        else => return null,
    };
    if (options.donor_frames > max_donor_frames) return null;
    if (options.jpeg_quality < min_jpeg_quality or options.jpeg_quality > max_jpeg_quality) return null;
    if (options.dpi < min_dpi or options.dpi > max_dpi) return null;
    if (!(options.frames_per_second >= 0)) return null;

    var result: stream.Options = .{
        .source_size = .{ .width = options.width, .height = options.height },
        .rotation = rotation,
        .colorimetry = .{ .range = range, .matrix = matrix },
        .frames_per_second = options.frames_per_second,
        .max_held_frames = options.max_held_frames,
    };
    result.donor.count = @intCast(options.donor_frames);
    result.donor.cut_count = @intCast((options.donor_frames + 1) / 2);
    result.render.detect.layout = layout;
    result.render.jpeg.quality = @intCast(options.jpeg_quality);
    result.render.jpeg.dpi = @intCast(options.dpi);
    result.render.fuse.finger.paint = paint;
    if (options.max_page_height > 0) {
        result.geometry.max_height_px = options.max_page_height;
        result.geometry.min_height_px = @min(result.geometry.min_height_px, options.max_page_height);
    }
    return result;
}

// endregion: options

// region: workers

/// The working memory of one thread.
const Worker = struct {
    cache: memory.BlockCache,
};

/// Make the working memory of one thread. Returns null when the memory is full.
export fn fastscan_worker_create() callconv(.c) ?*Worker {
    const worker = gpa.create(Worker) catch return null;
    worker.* = .{ .cache = .init(gpa) };
    return worker;
}

export fn fastscan_worker_destroy(worker: ?*Worker) callconv(.c) void {
    const target = worker orelse return;
    target.cache.deinit();
    gpa.destroy(target);
}

/// Give the large blocks that the worker keeps back to the system. The worker
/// stays in use. An app calls this when the system asks for memory.
export fn fastscan_worker_release_memory(worker: ?*Worker) callconv(.c) void {
    const target = worker orelse return;
    target.cache.release();
}

// endregion: workers

// region: stream

const Stream = stream.Stream;
const Job = stream.Job;

/// The same fields in the same order as `fastscan_frame` of the header.
const Frame = extern struct {
    y: ?[*]const u8,
    u: ?[*]const u8,
    v: ?[*]const u8,
    y_stride: u32,
    chroma_stride: u32,
    chroma_step: u32,
    reserved: u32,
    seconds: f64,
};

const corner_values = 8;

/// The same fields in the same order as `fastscan_status` of the header.
const Status = extern struct {
    detected: u32,
    page_count: u32,
    /// For each page: the x and the y of the top left, the top right, the bottom
    /// right, and the bottom left corner.
    corners: [detect.max_pages][corner_values]f32,
    steady: u32,
    captured: u32,
    spreads: u32,
    pages: u32,
    jobs_ready: u32,
    held_frames: u32,
};

/// The same fields in the same order as `fastscan_page` of the header.
const Page = extern struct {
    jpeg: ?[*]const u8,
    jpeg_size: usize,
    width: u32,
    height: u32,
    gray: u32,
    spread: u32,
    index: u32,
    reserved: u32,
};

/// Make a stream session. `out` gets the session.
export fn fastscan_stream_create(options: ?*const Options, out: ?*?*Stream) callconv(.c) c_int {
    const target = out orelse return invalid_argument;
    target.* = null;
    const converted = streamOptions(options orelse return invalid_argument) orelse return invalid_argument;
    const session = gpa.create(Stream) catch return resultOf(error.OutOfMemory);
    session.* = .init(gpa, converted);
    target.* = session;
    return ok;
}

/// Free a session. The caller gives each job back first.
export fn fastscan_stream_destroy(session: ?*Stream) callconv(.c) void {
    const target = session orelse return;
    target.deinit();
    gpa.destroy(target);
}

/// The frame of the caller as a frame of the intake. The lengths of the planes
/// come from the strides: C has no slices.
fn sourceOf(session: *const Stream, frame: *const Frame) ?intake.Source {
    const size = session.options.source_size;
    var source: intake.Source = .{
        .width = size.width,
        .height = size.height,
        .y = &.{},
        .y_stride = frame.y_stride,
        .u = &.{},
        .v = &.{},
        .chroma_stride = frame.chroma_stride,
        .chroma_step = frame.chroma_step,
    };
    const y = frame.y orelse return null;
    const u = frame.u orelse return null;
    const v = frame.v orelse return null;
    if (frame.chroma_step == 0 or frame.y_stride < size.width) return null;
    if (frame.chroma_stride < (image.chromaDimension(size.width) - 1) * frame.chroma_step + 1) return null;
    source.y = y[0..source.lumaBytes()];
    source.u = u[0..source.chromaBytes()];
    source.v = v[0..source.chromaBytes()];
    return source;
}

/// Take the next frame of the video. `status`, when given, gets what the session
/// knows after the frame.
export fn fastscan_stream_push(session: ?*Stream, worker: ?*Worker, frame: ?*const Frame, status: ?*Status) callconv(.c) c_int {
    const target = session orelse return invalid_argument;
    const scratch = (worker orelse return invalid_argument).cache.allocator();
    const given = frame orelse return invalid_argument;
    const source = sourceOf(target, given) orelse return resultOf(error.InvalidFrame);
    const result = target.push(scratch, source, given.seconds) catch |err| return resultOf(err);
    if (status) |out| {
        out.* = .{
            .detected = @intFromBool(result.detected),
            .page_count = result.page_count,
            .corners = undefined,
            .steady = @intFromBool(result.steady),
            .captured = @intFromBool(result.captured),
            .spreads = result.spreads,
            .pages = result.pages,
            .jobs_ready = result.jobs_ready,
            .held_frames = result.held_frames,
        };
        for (&out.corners, result.quads) |*values, quad| {
            const corners = quad.corners();
            for (corners, 0..) |corner, index| {
                values[2 * index] = corner.x;
                values[2 * index + 1] = corner.y;
            }
        }
    }
    return ok;
}

/// The video has no more frames. The caller then runs the jobs that are left.
export fn fastscan_stream_finish(session: ?*Stream, worker: ?*Worker) callconv(.c) c_int {
    const target = session orelse return invalid_argument;
    const scratch = (worker orelse return invalid_argument).cache.allocator();
    target.finish(scratch) catch |err| return resultOf(err);
    return ok;
}

/// The next job, or null when no job is ready.
export fn fastscan_stream_take_job(session: ?*Stream) callconv(.c) ?*Job {
    return (session orelse return null).takeJob();
}

/// Render the pages of a job. This function can run on another thread than the
/// functions of the session, with a worker that no other thread uses.
export fn fastscan_job_run(job: ?*Job, worker: ?*Worker) callconv(.c) c_int {
    const target = job orelse return invalid_argument;
    const scratch = (worker orelse return invalid_argument).cache.allocator();
    target.run(scratch) catch |err| return resultOf(err);
    return ok;
}

/// Give a job back to its session. `run_result` is the result of
/// `fastscan_job_run`, or a value that is not 0 when the job did not run.
export fn fastscan_stream_complete_job(session: ?*Stream, job: ?*Job, run_result: c_int) callconv(.c) void {
    const target = session orelse return;
    target.complete(job orelse return, run_result == ok);
}

/// 1 when the session has a job that is ready or that the caller did not give back.
export fn fastscan_stream_busy(session: ?*const Stream) callconv(.c) c_int {
    return @intFromBool((session orelse return 0).busy());
}

/// The number of pages that are complete.
export fn fastscan_stream_page_count(session: ?*const Stream) callconv(.c) u32 {
    return @intCast((session orelse return 0).pageCount());
}

/// One page of the document. The bytes belong to the session: they are valid until
/// the next call of a function that changes the session.
export fn fastscan_stream_page(session: ?*const Stream, index: u32, out: ?*Page) callconv(.c) c_int {
    const target = session orelse return invalid_argument;
    const result = out orelse return invalid_argument;
    var pages = target.pageIterator();
    var position: u32 = 0;
    while (pages.next()) |page| : (position += 1) {
        if (position != index) continue;
        result.* = .{
            .jpeg = page.encoded.jpeg.ptr,
            .jpeg_size = page.encoded.jpeg.len,
            .width = page.encoded.width,
            .height = page.encoded.height,
            .gray = @intFromBool(page.encoded.gray),
            .spread = page.spread,
            .index = page.index,
            .reserved = 0,
        };
        return ok;
    }
    return invalid_argument;
}

/// The size of each page image in pixels. The result is `invalid_argument` while
/// the session does not know the size.
export fn fastscan_stream_page_size(session: ?*const Stream, width: ?*u32, height: ?*u32) callconv(.c) c_int {
    const size = (session orelse return invalid_argument).pageSize() orelse return invalid_argument;
    if (width) |out| out.* = size.width;
    if (height) |out| out.* = size.height;
    return ok;
}

/// Gets the bytes of the PDF in order. Returns 0, or another value to stop.
const WriteFn = *const fn (context: ?*anyopaque, bytes: [*]const u8, size: usize) callconv(.c) c_int;

/// Write the pages that are complete as a PDF. The bytes go to `write` in order.
export fn fastscan_stream_write_pdf(session: ?*const Stream, write: ?WriteFn, context: ?*anyopaque) callconv(.c) c_int {
    const target = session orelse return invalid_argument;
    const Sink = struct {
        write: WriteFn,
        context: ?*anyopaque,

        fn send(pointer: ?*anyopaque, bytes: []const u8) pdf.WriteError!void {
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            if (bytes.len == 0) return;
            if (self.write(self.context, bytes.ptr, bytes.len) != 0) return error.WriteFailed;
        }
    };
    var sink: Sink = .{ .write = write orelse return invalid_argument, .context = context };
    target.writePdf(
        .{ .context = &sink, .writeFn = Sink.send },
        .{ .producer = "fastest-scan " ++ build_options.version },
    ) catch |err| return resultOf(err);
    return ok;
}

// endregion: stream

// region: tests

const testing = std.testing;

test "the version string is not empty" {
    try testing.expect(std.mem.len(fastscan_version()) > 0);
}

test "each result has a text" {
    try testing.expectEqualStrings("no error", std.mem.span(fastscan_result_message(0)));
    try testing.expectEqualStrings("the stream has ended", std.mem.span(fastscan_result_message(4)));
    try testing.expectEqualStrings("unknown result", std.mem.span(fastscan_result_message(99)));
}

test "the options need a frame size and valid values" {
    var options: Options = undefined;
    fastscan_options_init(&options);
    var session: ?*Stream = null;
    try testing.expectEqual(invalid_argument, fastscan_stream_create(&options, &session));
    options.width = 320;
    options.height = 240;
    options.rotation_degrees = 45;
    try testing.expectEqual(invalid_argument, fastscan_stream_create(&options, &session));
    options.rotation_degrees = 270;
    try testing.expectEqual(ok, fastscan_stream_create(&options, &session));
    try testing.expectEqual(intake.Rotation.three_quarters, session.?.options.rotation);
    try testing.expectEqual(@as(u32, 240), session.?.upright_size.width);
    fastscan_stream_destroy(session);
}

const test_width = 320;
const test_height = 240;
const test_stride = 336;

/// A frame in the layout NV12 with a stride: a dark desk and, when `seed` is not
/// 0, a bright page with dots and a dark bar.
fn fillNv12(luma: []u8, chroma: []u8, seed: u32) void {
    @memset(luma, 70);
    for (0..test_height / 2) |y| {
        for (0..test_width / 2) |x| {
            chroma[y * test_stride + 2 * x] = 128;
            chroma[y * test_stride + 2 * x + 1] = 150;
        }
    }
    if (seed == 0) return;
    for (30..210) |y| {
        for (80..230) |x| {
            const u = (@as(f32, @floatFromInt(x)) - 80) / 150;
            const v = (@as(f32, @floatFromInt(y)) - 30) / 180;
            const bar_top = 0.25 + 0.1 * @as(f32, @floatFromInt(seed % 5));
            const on_bar = u > 0.2 and u < 0.8 and v > bar_top and v < bar_top + 0.12;
            const column: u32 = @intFromFloat(u * 40);
            const row: u32 = @intFromFloat(v * 50);
            const dot = (column * (7 + seed) + row * (13 + 2 * seed)) % 11 == 0;
            luma[y * test_stride + x] = if (on_bar) 40 else if (dot) 120 else 200;
            chroma[(y / 2) * test_stride + 2 * (x / 2) + 1] = 128;
        }
    }
}

test "frames go in through the C functions, and pages and a PDF come out" {
    var options: Options = undefined;
    fastscan_options_init(&options);
    options.width = test_width;
    options.height = test_height;
    options.frames_per_second = 30;
    options.max_page_height = 360;
    var session: ?*Stream = null;
    try testing.expectEqual(ok, fastscan_stream_create(&options, &session));
    defer fastscan_stream_destroy(session);
    const worker = fastscan_worker_create().?;
    defer fastscan_worker_destroy(worker);

    const luma = try testing.allocator.alloc(u8, test_stride * test_height);
    defer testing.allocator.free(luma);
    const chroma = try testing.allocator.alloc(u8, test_stride * test_height / 2);
    defer testing.allocator.free(chroma);
    var frame: Frame = .{
        .y = luma.ptr,
        .u = chroma.ptr,
        .v = chroma.ptr + 1,
        .y_stride = test_stride,
        .chroma_stride = test_stride,
        .chroma_step = 2,
        .reserved = 0,
        .seconds = 0,
    };

    // Two pages, each in view for 12 frames, with the desk between them.
    var status: Status = undefined;
    var index: usize = 0;
    var captured = false;
    for ([_]u32{ 1, 0, 2, 0 }) |seed| {
        fillNv12(luma, chroma, seed);
        const frames: usize = if (seed == 0) 8 else 12;
        for (0..frames) |_| {
            frame.seconds = @as(f64, @floatFromInt(index)) / 30.0;
            try testing.expectEqual(ok, fastscan_stream_push(session, worker, &frame, &status));
            index += 1;
            try testing.expectEqual(@as(u32, @intFromBool(seed != 0)), status.detected);
            if (seed != 0) {
                try testing.expectApproxEqAbs(@as(f32, 80), status.corners[0][0], 3);
                try testing.expectApproxEqAbs(@as(f32, 210), status.corners[0][5], 3);
            }
            captured = captured or status.captured != 0;
        }
    }
    try testing.expect(captured);
    try testing.expectEqual(@as(u32, 2), status.spreads);
    try testing.expectEqual(ok, fastscan_stream_finish(session, worker));
    try testing.expectEqual(@backingInt(Result.stream_ended), fastscan_stream_push(session, worker, &frame, null));

    var jobs: usize = 0;
    while (fastscan_stream_take_job(session)) |job| : (jobs += 1) {
        try testing.expectEqual(@as(c_int, 1), fastscan_stream_busy(session));
        const result = fastscan_job_run(job, worker);
        fastscan_stream_complete_job(session, job, result);
        try testing.expectEqual(ok, result);
    }
    try testing.expectEqual(@as(usize, 2), jobs);
    try testing.expectEqual(@as(c_int, 0), fastscan_stream_busy(session));
    try testing.expectEqual(@as(u32, 2), fastscan_stream_page_count(session));

    var width: u32 = 0;
    var height: u32 = 0;
    try testing.expectEqual(ok, fastscan_stream_page_size(session, &width, &height));
    try testing.expectEqual(@as(u32, 360), height);
    var page: Page = undefined;
    try testing.expectEqual(ok, fastscan_stream_page(session, 1, &page));
    try testing.expectEqual(width, page.width);
    try testing.expectEqual(@as(u32, 1), page.spread);
    // A JPEG file starts with the marker FF D8.
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD8 }, page.jpeg.?[0..2]);
    try testing.expectEqual(invalid_argument, fastscan_stream_page(session, 2, &page));

    const Collect = struct {
        var bytes: std.ArrayList(u8) = .empty;

        fn write(_: ?*anyopaque, data: [*]const u8, size: usize) callconv(.c) c_int {
            bytes.appendSlice(testing.allocator, data[0..size]) catch return 1;
            return 0;
        }

        fn refuse(_: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) c_int {
            return 1;
        }
    };
    defer Collect.bytes.deinit(testing.allocator);
    try testing.expectEqual(ok, fastscan_stream_write_pdf(session, Collect.write, null));
    try testing.expect(std.mem.startsWith(u8, Collect.bytes.items, "%PDF-"));
    try testing.expect(std.mem.find(u8, Collect.bytes.items, "/Count 2") != null);
    try testing.expectEqual(@backingInt(Result.write_failed), fastscan_stream_write_pdf(session, Collect.refuse, null));

    fastscan_worker_release_memory(worker);
}

test "a frame with a stride below the width is an error" {
    var options: Options = undefined;
    fastscan_options_init(&options);
    options.width = test_width;
    options.height = test_height;
    var session: ?*Stream = null;
    try testing.expectEqual(ok, fastscan_stream_create(&options, &session));
    defer fastscan_stream_destroy(session);
    const worker = fastscan_worker_create().?;
    defer fastscan_worker_destroy(worker);
    const data = [_]u8{0};
    const frame: Frame = .{ .y = &data, .u = &data, .v = &data, .y_stride = 16, .chroma_stride = 8, .chroma_step = 1, .reserved = 0, .seconds = 0 };
    try testing.expectEqual(@backingInt(Result.invalid_frame), fastscan_stream_push(session, worker, &frame, null));
    try testing.expectEqual(invalid_argument, fastscan_stream_push(session, worker, null, null));
    try testing.expectEqual(invalid_argument, fastscan_stream_push(null, worker, &frame, null));
}

// endregion: tests
