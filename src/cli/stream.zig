//! The stream mode of the program: one pass through the video, in order, as the
//! phone app does. `ffmpeg` gives each frame one time at its full size, and the
//! stream session of the library keeps the few frames that a spread needs.
//!
//! This mode shows on a desktop what the phone app gets from a video. See
//! `docs/decisions/0019-stream-session-for-a-phone.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fastscan = @import("fastscan");
const args = @import("args.zig");
const ffmpeg = @import("ffmpeg.zig");
const system = @import("system.zig");

const image = fastscan.image;
const stream = fastscan.stream;
const BlockCache = fastscan.memory.BlockCache;

// region: constants

const debug_pages_dir = "pages";
const stream_table_name = "stream.csv";
const pdf_buffer_bytes = 256 * 1024;
/// The main thread looks for a finished job after this time, when it has no other work.
const poll_milliseconds = 2;
const bytes_per_megabyte = 1024 * 1024;
const percent = 100.0;
const nanoseconds_per_millisecond = 1_000_000;

// endregion: constants

// region: render workers

/// A job that a worker finished.
const Finished = struct {
    job: *stream.Job,
    done: bool,
};

/// What the main thread and the render workers share.
const Workers = struct {
    io: Io,
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    /// The working memory of the workers. A worker takes one for a job.
    idle_caches: std.ArrayList(*BlockCache) = .empty,
    finished: std.ArrayList(Finished) = .empty,
    first_error: ?anyerror = null,
    /// The jobs that a worker has.
    running: usize = 0,
    limit: usize,
    group: Io.Group = .init,
    caches: []BlockCache,

    fn init(io: Io, gpa: Allocator, limit: usize) !Workers {
        const caches = try gpa.alloc(BlockCache, limit);
        errdefer gpa.free(caches);
        var workers: Workers = .{ .io = io, .gpa = gpa, .limit = limit, .caches = caches };
        errdefer workers.idle_caches.deinit(gpa);
        try workers.idle_caches.ensureTotalCapacity(gpa, limit);
        try workers.finished.ensureTotalCapacity(gpa, limit);
        for (caches) |*cache| {
            cache.* = .init(gpa);
            workers.idle_caches.appendAssumeCapacity(cache);
        }
        return workers;
    }

    fn deinit(self: *Workers) void {
        // All render threads have ended here: `drain` waits for each job. An error
        // of the wait changes nothing for the memory that this function frees.
        self.group.await(self.io) catch |err| std.debug.print("the wait for the render threads failed: {t}\n", .{err});
        for (self.caches) |*cache| cache.deinit();
        self.gpa.free(self.caches);
        self.idle_caches.deinit(self.gpa);
        self.finished.deinit(self.gpa);
    }

    /// Run a job on a thread of its own.
    fn start(self: *Workers, job: *stream.Job) void {
        self.running += 1;
        self.group.concurrent(self.io, work, .{ self, job }) catch |err| switch (err) {
            // The system gives no more threads: the calling thread does the job.
            error.ConcurrencyUnavailable => work(self, job),
        };
    }

    fn work(self: *Workers, job: *stream.Job) void {
        self.mutex.lockUncancelable(self.io);
        const cache = self.idle_caches.pop().?;
        self.mutex.unlock(self.io);

        var done = true;
        var failure: ?anyerror = null;
        job.run(cache.allocator()) catch |err| {
            done = false;
            failure = err;
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.idle_caches.appendAssumeCapacity(cache);
        self.finished.appendAssumeCapacity(.{ .job = job, .done = done });
        if (failure) |err| {
            if (self.first_error == null) self.first_error = err;
        }
    }

    /// Give the finished jobs back to the session, and start the jobs that are
    /// ready. After a job failed, no new job starts: the jobs that are ready go
    /// back to the session with no pages.
    fn exchange(self: *Workers, session: *stream.Stream) void {
        var batch: [64]Finished = undefined;
        var count: usize = 0;
        self.mutex.lockUncancelable(self.io);
        while (count < batch.len) : (count += 1) batch[count] = self.finished.pop() orelse break;
        const failed = self.first_error != null;
        self.mutex.unlock(self.io);

        for (batch[0..count]) |finished| {
            session.complete(finished.job, finished.done);
            self.running -= 1;
        }
        while (failed or self.running < self.limit) {
            const job = session.takeJob() orelse break;
            if (failed) session.complete(job, false) else self.start(job);
        }
    }

    /// The first error of a job.
    fn check(self: *Workers) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.first_error) |err| return err;
    }

    fn memoryStats(self: *const Workers) BlockCache.Stats {
        var total: BlockCache.Stats = .{};
        for (self.caches) |*cache| total.add(cache.stats);
        return total;
    }
};

// endregion: render workers

/// Make the PDF in one pass through the video.
pub fn run(io: Io, gpa: Allocator, config: *const args.Config, info: *const ffmpeg.VideoInfo, worker_count: usize, stdout: *Io.Writer) !void {
    const start = Io.Timestamp.now(io, .awake);
    const frame_count = info.frames.len;
    const requested_first = if (config.from_seconds) |time| info.frameAtSeconds(time) else 0;
    const end = if (config.to_seconds) |time| info.frameAtSeconds(time) else frame_count;
    if (requested_first >= end) return error.EmptyTimeRange;
    const first = info.keyframeAtOrBefore(requested_first);

    const duration = info.seconds(frame_count - 1);
    const frames_per_second: f32 = if (duration > 0)
        @floatCast(@as(f64, @floatFromInt(frame_count - 1)) / duration)
    else
        fastscan.timeline.Options.reference_frame_rate;

    var session: stream.Stream = .init(gpa, .{
        .source_size = .{ .width = info.width, .height = info.height },
        // ffmpeg gives the frames in the upright view.
        .rotation = .none,
        .colorimetry = info.colorimetry,
        .frames_per_second = frames_per_second,
        .analysis_short_side = config.analysis_height,
        .donor = .{ .count = config.stream_frames, .cut_count = (config.stream_frames + 1) / 2 },
        .render = .{
            .detect = .{ .layout = config.layout },
            .jpeg = .{ .quality = config.quality, .dpi = config.dpi },
            .curl = config.curl,
            .fuse = .{ .finger = .{ .paint = config.fingers } },
        },
        .max_held_frames = config.stream_held_frames,
    });
    defer session.deinit();

    var workers = try Workers.init(io, gpa, @max(1, worker_count));
    defer workers.deinit();
    if (config.verbose) {
        std.debug.print("video: {d}x{d}, {d} frames, {d:.1} s; one decoder, {d} render threads\n", .{
            info.width,
            info.height,
            frame_count,
            duration,
            workers.limit,
        });
    }
    // The session must get each job back before it goes.
    defer drain(io, &workers, &session);

    // The working memory of the analysis, on the main thread.
    var analysis_cache: BlockCache = .init(gpa);
    defer analysis_cache.deinit();
    const scratch = analysis_cache.allocator();

    const reader = try ffmpeg.FrameReader.open(io, gpa, info, .{
        .ffmpeg = config.ffmpeg,
        .hwaccel = config.hwaccel,
        .video = config.input,
        .first_frame = first,
        .frame_count = end - first,
        // This mode has one decoder for the whole video, so the decoder takes all
        // the CPU threads that the render threads leave.
        .threads = 0,
    });
    defer reader.close();

    var push_nanoseconds: i96 = 0;
    var frames_read: usize = 0;
    for (first..end) |frame_index| {
        // The packet list can name more frames than the decoder gives at the end of a video.
        const frame = (try reader.next()) orelse break;
        frames_read += 1;
        const before = Io.Timestamp.now(io, .awake);
        _ = try session.push(scratch, fastscan.intake.Source.fromFrame(frame), info.seconds(frame_index));
        push_nanoseconds += before.untilNow(io, .awake).toNanoseconds();
        workers.exchange(&session);
        try workers.check();
    }
    const read_ms = start.untilNow(io, .awake).toMilliseconds();
    try session.finish(scratch);
    drain(io, &workers, &session);
    try workers.check();
    const render_ms = start.untilNow(io, .awake).toMilliseconds();

    const stats = session.stats;
    if (config.verbose) {
        const page_size = session.pageSize() orelse image.Size{ .width = 0, .height = 0 };
        std.debug.print("stream: {d} frames, pages detected in {d}, {d} ms; the session took {d} ms of that time, {d:.1} ms for each frame\n", .{
            frames_read,
            stats.detected_frames,
            read_ms,
            @divTrunc(push_nanoseconds, nanoseconds_per_millisecond),
            @as(f64, @floatFromInt(push_nanoseconds)) / nanoseconds_per_millisecond / @as(f64, @floatFromInt(@max(frames_read, 1))),
        });
        std.debug.print("timeline: {d} spreads ({d} runs kept apart from a similar spread, {d} duplicates removed, {d} with no usable picture), {d} pages of {d}x{d}\n", .{
            stats.segments,
            stats.runs_kept_apart,
            stats.duplicate_spreads,
            stats.unusable_spreads,
            session.pageCount(),
            page_size.width,
            page_size.height,
        });
        const frame_megabytes = @as(f64, @floatFromInt(image.packedFrameSize(info.width, info.height))) / bytes_per_megabyte;
        std.debug.print("frames in memory: at most {d} of {d:.1} MB each, {d:.0} MB; {d} choices of frames, {d} of them with fewer donor frames for the limit; {d} donor frames taken from a job for the limit\n", .{
            stats.peak_held_frames,
            frame_megabytes,
            @as(f64, @floatFromInt(stats.peak_held_frames)) * frame_megabytes,
            stats.selections,
            stats.donor_limits,
            stats.donors_dropped,
        });
        var report: Report = .{};
        var pages = session.pageIterator();
        while (pages.next()) |page| report.add(page.report);
        report.print();
        const memory = workers.memoryStats();
        std.debug.print("render: {d} ms after the last frame; {d} large blocks from the system, {d} MB; a large block was used again {d} times\n", .{
            render_ms - read_ms,
            memory.fresh_blocks,
            memory.fresh_bytes / bytes_per_megabyte,
            memory.reused_blocks,
        });
        if (system.peakMemoryBytes(io)) |bytes| {
            std.debug.print("memory: at most {d} MB in this process, with {d} render threads\n", .{ bytes / bytes_per_megabyte, workers.limit });
        }
    }
    if (config.debug_dir) |path| try writeDebug(io, gpa, path, &session);

    const pdf_bytes = try writePdf(io, gpa, config.output, &session);
    try stdout.print("{s}: {d} pages, {d} bytes, {d} ms\n", .{
        config.output,
        session.pageCount(),
        pdf_bytes,
        start.untilNow(io, .awake).toMilliseconds(),
    });
}

/// Run the jobs of the session until none is left.
fn drain(io: Io, workers: *Workers, session: *stream.Stream) void {
    while (true) {
        workers.exchange(session);
        if (!session.busy()) return;
        // A wait that is cut short only makes the next look come earlier.
        io.sleep(.fromMilliseconds(poll_milliseconds), .awake) catch |err| switch (err) {
            error.Canceled => {},
        };
    }
}

/// The sums of the page reports, for the verbose output.
const Report = struct {
    pages: usize = 0,
    donor_frames: usize = 0,
    donors_used: usize = 0,
    glare: f32 = 0,
    cover: f32 = 0,
    outside: f32 = 0,
    unrepaired: f32 = 0,
    rejected: f32 = 0,
    painted: f32 = 0,
    finger_left: f32 = 0,
    finger_pages: usize = 0,

    fn add(self: *Report, page: stream.PageReport) void {
        self.pages += 1;
        self.donor_frames += page.donor_frames;
        self.donors_used += page.donors_used;
        self.glare += page.fusion.glare;
        self.cover += page.fusion.cover;
        self.outside += page.fusion.outside;
        self.unrepaired += page.fusion.unrepaired;
        self.rejected += page.fusion.rejected;
        self.painted += page.fusion.painted;
        self.finger_left += page.fusion.finger_left;
        if (page.fusion.finger_left > 0) self.finger_pages += 1;
    }

    fn print(self: Report) void {
        const count: f32 = @floatFromInt(@max(self.pages, 1));
        std.debug.print("fusion: {d} donor pages registered of {d}; mean page area with glare {d:.2} %, covered {d:.2} %, outside the frame {d:.2} %, not repaired {d:.2} % (no donor agreed: {d:.2} %)\n", .{
            self.donors_used,
            self.donor_frames,
            self.glare / count * percent,
            self.cover / count * percent,
            self.outside / count * percent,
            self.unrepaired / count * percent,
            self.rejected / count * percent,
        });
        std.debug.print("fingers: mean page area painted {d:.2} %; a finger stays on {d:.2} % of the page area, on {d} pages\n", .{
            self.painted / count * percent,
            self.finger_left / count * percent,
            self.finger_pages,
        });
    }
};

/// Write each page as a JPEG file, and a table with one line per page.
fn writeDebug(io: Io, gpa: Allocator, path: []const u8, session: *const stream.Stream) !void {
    const dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, debug_pages_dir);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "spread,page,reference,donor_frames,donors_used,glare,cover,outside,unrepaired,rejected,finger_painted,finger_left,outside_after\n");
    var line_buffer: [224]u8 = undefined;
    var name_buffer: [64]u8 = undefined;
    var pages = session.pageIterator();
    while (pages.next()) |page| {
        const name = try std.mem.print(&name_buffer, debug_pages_dir ++ "/p_{d:0>3}_{d}.jpg", .{ page.spread, page.index });
        try dir.writeFile(io, .{ .sub_path = name, .data = page.encoded.jpeg });
        const report = page.report;
        try text.appendSlice(gpa, try std.mem.print(&line_buffer, "{d},{d},{d},{d},{d},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4}\n", .{
            page.spread,
            page.index,
            report.reference,
            report.donor_frames,
            report.donors_used,
            report.fusion.glare,
            report.fusion.cover,
            report.fusion.outside,
            report.fusion.unrepaired,
            report.fusion.rejected,
            report.fusion.painted,
            report.fusion.finger_left,
            report.outside_fraction,
        }));
    }
    try dir.writeFile(io, .{ .sub_path = stream_table_name, .data = text.items });
}

/// Write the pages of the session into a PDF file.
fn writePdf(io: Io, gpa: Allocator, path: []const u8, session: *const stream.Stream) !u64 {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    const buffer = try gpa.alloc(u8, pdf_buffer_bytes);
    defer gpa.free(buffer);
    var file_writer: Io.File.Writer = .init(file, io, buffer);

    const Sink = struct {
        fn write(context: ?*anyopaque, bytes: []const u8) fastscan.pdf.WriteError!void {
            const writer: *Io.Writer = @ptrCast(@alignCast(context.?));
            writer.writeAll(bytes) catch return error.WriteFailed;
        }
    };
    try session.writePdf(
        .{ .context = &file_writer.interface, .writeFn = Sink.write },
        .{ .producer = "fastest-scan " ++ fastscan.version },
    );
    try file_writer.interface.flush();
    return file_writer.logicalPos();
}
