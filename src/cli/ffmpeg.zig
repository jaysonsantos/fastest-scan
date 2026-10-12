//! The video input of the program: `ffprobe` for the properties and the frame list,
//! and `ffmpeg` processes that write raw frames to a pipe.
//!
//! See `docs/decisions/0003-ffmpeg-subprocess-in-the-cli.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fastscan = @import("fastscan");
const image = fastscan.image;

// region: constants

/// A seek to this much after a keyframe lands on that keyframe with `-noaccurate_seek`.
const seek_margin_seconds = 0.005;
const pipe_buffer_bytes = 256 * 1024;
const quarter_turn_degrees = 90;

const probe_key = struct {
    const width = "width";
    const height = "height";
    const color_range = "color_range";
    const color_space = "color_space";
    const time_base = "time_base";
    const rotation = "rotation";
};

// endregion: constants

pub const Error = error{
    /// The system has no program with the name of `ffprobe` or `ffmpeg`.
    ToolNotFound,
    /// `ffprobe` or `ffmpeg` did not start, or ended with an error.
    ToolFailed,
    /// The output of `ffprobe` has no video stream or misses a property.
    NoVideoStream,
    /// `ffmpeg` gave fewer bytes than one frame.
    TruncatedFrame,
};

// region: probe

pub const FrameEntry = struct {
    /// The display time in units of the time base.
    pts: i64,
    key: bool,
};

pub const VideoInfo = struct {
    /// The size of the decoded frames, after the rotation that ffmpeg applies.
    width: u32,
    height: u32,
    colorimetry: image.Colorimetry,
    time_base_numerator: u32,
    time_base_denominator: u32,
    /// All frames in display order.
    frames: []FrameEntry,

    pub fn deinit(self: VideoInfo, allocator: Allocator) void {
        allocator.free(self.frames);
    }

    pub fn seconds(self: VideoInfo, frame_index: usize) f64 {
        const pts: f64 = @floatFromInt(self.frames[frame_index].pts);
        return pts * @as(f64, @floatFromInt(self.time_base_numerator)) / @as(f64, @floatFromInt(self.time_base_denominator));
    }

    /// The index of the last keyframe at or before `frame_index`.
    pub fn keyframeAtOrBefore(self: VideoInfo, frame_index: usize) usize {
        var index = frame_index;
        while (index > 0 and !self.frames[index].key) index -= 1;
        return index;
    }

    /// The index of the first frame at or after `time` seconds.
    pub fn frameAtSeconds(self: VideoInfo, time: f64) usize {
        for (0..self.frames.len) |index| {
            if (self.seconds(index) >= time) return index;
        }
        return self.frames.len;
    }
};

/// Start `ffmpeg` or `ffprobe` with its standard output in a pipe. The message
/// names the program: the user must see which tool is missing, and why a tool did
/// not start.
fn startTool(io: Io, argv: []const []const u8) (Error || Allocator.Error || Io.Cancelable)!std.process.Child {
    return std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |passed| return passed,
        error.FileNotFound => {
            std.debug.print("cannot find the program '{s}'\n", .{argv[0]});
            return error.ToolNotFound;
        },
        else => {
            std.debug.print("cannot start the program '{s}': {t}\n", .{ argv[0], err });
            return error.ToolFailed;
        },
    };
}

/// The error for a read from the pipe of a tool that failed. The reader interface
/// gives a general error only; the reader keeps the cause.
fn readError(reader: *const Io.File.Reader) (Error || Io.Cancelable) {
    const cause = reader.err orelse return error.ToolFailed;
    if (cause == error.Canceled) return error.Canceled;
    std.debug.print("cannot read the output of the tool: {t}\n", .{cause});
    return error.ToolFailed;
}

/// Run a program and return all of its standard output. The caller frees it.
fn capture(io: Io, allocator: Allocator, argv: []const []const u8) (Error || Allocator.Error || Io.Cancelable)![]u8 {
    var child = try startTool(io, argv);
    defer child.kill(io);

    var buffer: [pipe_buffer_bytes]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    const output = reader.interface.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => return readError(&reader),
        // The limit is `.unlimited`.
        error.StreamTooLong => unreachable,
    };
    errdefer allocator.free(output);
    const term = child.wait(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.debug.print("cannot wait for the program '{s}': {t}\n", .{ argv[0], err });
            return error.ToolFailed;
        },
    };
    if (!term.success()) return error.ToolFailed;
    return output;
}

pub fn probe(io: Io, allocator: Allocator, ffprobe: []const u8, video: []const u8) !VideoInfo {
    const stream_text = try capture(io, allocator, &.{
        ffprobe,                                                                           "-v",  "error",
        "-select_streams",                                                                 "v:0", "-show_entries",
        "stream=width,height,color_range,color_space,time_base:stream_side_data=rotation", "-of", "default=nw=1",
        video,
    });
    defer allocator.free(stream_text);
    var info = try parseStream(stream_text);

    const packet_text = try capture(io, allocator, &.{
        ffprobe,            "-v",  "error",
        "-select_streams",  "v:0", "-show_entries",
        "packet=pts,flags", "-of", "csv=p=0",
        video,
    });
    defer allocator.free(packet_text);
    info.frames = try parsePackets(allocator, packet_text);
    if (info.frames.len == 0) return error.NoVideoStream;
    return info;
}

fn parseStream(text: []const u8) Error!VideoInfo {
    var width: ?u32 = null;
    var height: ?u32 = null;
    var numerator: ?u32 = null;
    var denominator: ?u32 = null;
    var rotation: i32 = 0;
    var colorimetry: image.Colorimetry = .{};

    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..equals];
        const value = line[equals + 1 ..];
        if (std.mem.eql(u8, key, probe_key.width)) {
            width = std.fmt.parseInt(u32, value, 10) catch null;
        } else if (std.mem.eql(u8, key, probe_key.height)) {
            height = std.fmt.parseInt(u32, value, 10) catch null;
        } else if (std.mem.eql(u8, key, probe_key.time_base)) {
            const slash = std.mem.indexOfScalar(u8, value, '/') orelse continue;
            numerator = std.fmt.parseInt(u32, value[0..slash], 10) catch null;
            denominator = std.fmt.parseInt(u32, value[slash + 1 ..], 10) catch null;
        } else if (std.mem.eql(u8, key, probe_key.rotation)) {
            rotation = std.fmt.parseInt(i32, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, probe_key.color_range)) {
            // "pc" and "jpeg" are the names of the full range.
            if (std.mem.eql(u8, value, "pc") or std.mem.eql(u8, value, "jpeg")) colorimetry.range = .full;
        } else if (std.mem.eql(u8, key, probe_key.color_space)) {
            if (std.mem.eql(u8, value, "bt470bg") or std.mem.eql(u8, value, "smpte170m")) colorimetry.matrix = .bt601;
        }
    }

    var info: VideoInfo = .{
        .width = width orelse return error.NoVideoStream,
        .height = height orelse return error.NoVideoStream,
        .colorimetry = colorimetry,
        .time_base_numerator = numerator orelse return error.NoVideoStream,
        .time_base_denominator = denominator orelse return error.NoVideoStream,
        .frames = &.{},
    };
    if (info.time_base_denominator == 0 or info.width == 0 or info.height == 0) return error.NoVideoStream;
    // ffmpeg turns the frames of a rotated video upright, so the two sides change places.
    if (@mod(@abs(rotation), 2 * quarter_turn_degrees) == quarter_turn_degrees) {
        std.mem.swap(u32, &info.width, &info.height);
    }
    return info;
}

fn parsePackets(allocator: Allocator, text: []const u8) ![]FrameEntry {
    var entries: std.ArrayList(FrameEntry) = .empty;
    errdefer entries.deinit(allocator);
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const comma = std.mem.indexOfScalar(u8, line, ',') orelse continue;
        // A packet without a time ("N/A") gives no frame that the pipeline can address.
        const pts = std.fmt.parseInt(i64, line[0..comma], 10) catch continue;
        const flags = line[comma + 1 ..];
        try entries.append(allocator, .{ .pts = pts, .key = std.mem.indexOfScalar(u8, flags, 'K') != null });
    }
    // The packets come in decode order. The decoder gives the frames in display order.
    std.mem.sort(FrameEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: FrameEntry, b: FrameEntry) bool {
            return a.pts < b.pts;
        }
    }.lessThan);
    return entries.toOwnedSlice(allocator);
}

// endregion: probe

// region: frame reader

pub const ReaderOptions = struct {
    ffmpeg: []const u8,
    hwaccel: ?[]const u8 = null,
    video: []const u8,
    /// The first frame of the range. It must be a keyframe.
    first_frame: usize,
    /// The number of frames of the range.
    frame_count: usize,
    /// The frames of the range that the reader gives, as offsets from `first_frame`
    /// in rising order. Null gives each frame of the range.
    ///
    /// The decoder must decode each frame from the keyframe to the last frame of
    /// the list. With the list, only the listed frames go through the pipe: a
    /// full-size frame of a 4K video has 12 MB.
    select: ?[]const u32 = null,
    /// The size of the output frames. Null keeps the size of the video.
    scale: ?image.Size = null,
    /// The number of threads of the decoder. 0 lets ffmpeg take one thread per
    /// CPU thread.
    ///
    /// The default is one thread, because the readers run in parallel. On a 4K
    /// HEVC video, a run of 26 frames takes 1.9 s of CPU time with one thread. With
    /// 16 threads it takes 3.1 s of CPU time, 5 times the memory (700 MB), and
    /// almost the same run time: the decoder decodes frames after the last frame
    /// that it gives.
    threads: usize = 1,
};

/// The `select` filter of ffmpeg for a list of frame numbers. `n` is the number of
/// a frame at the input of the filter, from 0.
fn selectFilter(allocator: Allocator, offsets: []const u32) Allocator.Error![]const u8 {
    var filter: std.ArrayList(u8) = .empty;
    errdefer filter.deinit(allocator);
    try filter.appendSlice(allocator, "select='");
    for (offsets, 0..) |offset, index| {
        if (index > 0) try filter.append(allocator, '+');
        try filter.print(allocator, "eq(n,{d})", .{offset});
    }
    try filter.append(allocator, '\'');
    return filter.toOwnedSlice(allocator);
}

/// One `ffmpeg` process that decodes a range of frames into packed I420 buffers.
pub const FrameReader = struct {
    io: Io,
    allocator: Allocator,
    child: std.process.Child,
    pipe_buffer: []u8,
    file_reader: Io.File.Reader,
    frame: []u8,
    width: u32,
    height: u32,
    colorimetry: image.Colorimetry,
    remaining: usize,

    /// The reader is returned by pointer because the pipe reader keeps a pointer to itself.
    pub fn open(io: Io, allocator: Allocator, info: *const VideoInfo, options: ReaderOptions) !*FrameReader {
        std.debug.assert(info.frames[options.first_frame].key);

        var arena_state: std.heap.ArenaAllocator = .init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ options.ffmpeg, "-v", "error", "-nostdin" });
        if (options.threads > 0) try argv.appendSlice(arena, &.{ "-threads", try arena.print("{d}", .{options.threads}) });
        if (options.hwaccel) |name| try argv.appendSlice(arena, &.{ "-hwaccel", name });
        if (options.first_frame > 0) {
            const seek = info.seconds(options.first_frame) + seek_margin_seconds;
            try argv.appendSlice(arena, &.{ "-ss", try arena.print("{d:.6}", .{seek}), "-noaccurate_seek" });
        }
        try argv.appendSlice(arena, &.{ "-i", options.video, "-an", "-sn", "-dn" });
        const output_count = if (options.select) |offsets| offsets.len else options.frame_count;
        if (options.select) |offsets| {
            std.debug.assert(offsets.len > 0 and offsets[offsets.len - 1] < options.frame_count);
            for (offsets[1..], offsets[0 .. offsets.len - 1]) |later, earlier| std.debug.assert(later > earlier);
        }
        // ffmpeg stops the decoder after this number of output frames.
        try argv.appendSlice(arena, &.{ "-frames:v", try arena.print("{d}", .{output_count}) });
        const width = if (options.scale) |size| size.width else info.width;
        const height = if (options.scale) |size| size.height else info.height;
        var filters: std.ArrayList(u8) = .empty;
        if (options.select) |offsets| try filters.appendSlice(arena, try selectFilter(arena, offsets));
        if (options.scale != null) {
            if (filters.items.len > 0) try filters.append(arena, ',');
            // The area filter is a box filter: each output pixel is the mean of its source pixels.
            try filters.print(arena, "scale={d}:{d}:flags=area", .{ width, height });
        }
        if (filters.items.len > 0) try argv.appendSlice(arena, &.{ "-vf", filters.items });
        // Without passthrough, ffmpeg duplicates or drops frames of a variable-rate video.
        try argv.appendSlice(arena, &.{ "-fps_mode", "passthrough", "-pix_fmt", "yuv420p", "-f", "rawvideo", "-" });

        const self = try allocator.create(FrameReader);
        errdefer allocator.destroy(self);
        const pipe_buffer = try allocator.alloc(u8, pipe_buffer_bytes);
        errdefer allocator.free(pipe_buffer);
        const frame = try allocator.alloc(u8, image.packedFrameSize(width, height));
        errdefer allocator.free(frame);

        self.* = .{
            .io = io,
            .allocator = allocator,
            .child = try startTool(io, argv.items),
            .pipe_buffer = pipe_buffer,
            .file_reader = undefined,
            .frame = frame,
            .width = width,
            .height = height,
            .colorimetry = info.colorimetry,
            .remaining = output_count,
        };
        self.file_reader = self.child.stdout.?.readerStreaming(io, self.pipe_buffer);
        return self;
    }

    /// The next frame, or null after the last frame of the range. The view is valid
    /// until the next call.
    pub fn next(self: *FrameReader) (Error || Io.Cancelable)!?image.FrameView {
        if (self.remaining == 0) return null;
        const count = self.file_reader.interface.readSliceShort(self.frame) catch return readError(&self.file_reader);
        if (count == 0) return null;
        if (count != self.frame.len) {
            std.debug.print("ffmpeg gave {d} bytes of a frame of {d} bytes, with {d} frames to go\n", .{ count, self.frame.len, self.remaining });
            return error.TruncatedFrame;
        }
        self.remaining -= 1;
        return image.FrameView.fromPacked(self.frame, self.width, self.height, self.colorimetry);
    }

    /// The bytes of the frame that `next` returned last.
    pub fn frameBytes(self: *const FrameReader) []const u8 {
        return self.frame;
    }

    pub fn close(self: *FrameReader) void {
        // The process can still have frames to write when the caller stops early.
        self.child.kill(self.io);
        self.allocator.free(self.pipe_buffer);
        self.allocator.free(self.frame);
        self.allocator.destroy(self);
    }
};

// endregion: frame reader

// region: tests

const testing = std.testing;

test "the select filter names each frame of the list" {
    const filter = try selectFilter(testing.allocator, &.{ 0, 7, 29 });
    defer testing.allocator.free(filter);
    try testing.expectEqualStrings("select='eq(n,0)+eq(n,7)+eq(n,29)'", filter);
}

test "parse the stream properties" {
    const text =
        \\width=3840
        \\height=2160
        \\color_range=tv
        \\color_space=bt709
        \\time_base=1/90000
        \\
    ;
    const info = try parseStream(text);
    try testing.expectEqual(@as(u32, 3840), info.width);
    try testing.expectEqual(@as(u32, 2160), info.height);
    try testing.expectEqual(@as(u32, 90000), info.time_base_denominator);
    try testing.expectEqual(image.ColorRange.limited, info.colorimetry.range);
    try testing.expectEqual(image.ColorMatrix.bt709, info.colorimetry.matrix);
}

test "a quarter turn swaps the sides" {
    const text = "width=1920\nheight=1080\ntime_base=1/600\nrotation=-90\ncolor_range=pc\n";
    const info = try parseStream(text);
    try testing.expectEqual(@as(u32, 1080), info.width);
    try testing.expectEqual(@as(u32, 1920), info.height);
    try testing.expectEqual(image.ColorRange.full, info.colorimetry.range);
}

test "a stream without a size is an error" {
    try testing.expectError(error.NoVideoStream, parseStream("time_base=1/90000\n"));
}

test "parse the packet list and sort it by time" {
    const text = "0,K__\n6000,___\n3000,___\nN/A,___\n9000,K__\n";
    const frames = try parsePackets(testing.allocator, text);
    defer testing.allocator.free(frames);
    try testing.expectEqual(@as(usize, 4), frames.len);
    try testing.expectEqual(@as(i64, 3000), frames[1].pts);
    try testing.expect(frames[0].key and frames[3].key and !frames[1].key);

    const info: VideoInfo = .{
        .width = 16,
        .height = 16,
        .colorimetry = .{},
        .time_base_numerator = 1,
        .time_base_denominator = 3000,
        .frames = frames,
    };
    try testing.expectEqual(@as(f64, 2), info.seconds(2));
    try testing.expectEqual(@as(usize, 0), info.keyframeAtOrBefore(2));
    try testing.expectEqual(@as(usize, 3), info.keyframeAtOrBefore(3));
    try testing.expectEqual(@as(usize, 2), info.frameAtSeconds(1.5));
    try testing.expectEqual(@as(usize, 4), info.frameAtSeconds(99));
}

// endregion: tests
