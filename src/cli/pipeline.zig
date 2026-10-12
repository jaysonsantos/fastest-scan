//! The steps of the program between the arguments and the PDF: the analysis pass
//! over small frames, and the files for the cache and for debugging.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fastscan = @import("fastscan");
const args = @import("args.zig");
const ffmpeg = @import("ffmpeg.zig");
const parallel = @import("parallel.zig");
const debug = @import("debug.zig");

const image = fastscan.image;
const observe = fastscan.observe;
const BlockCache = fastscan.memory.BlockCache;
const FrameObservation = observe.FrameObservation;

// region: constants

/// One decoder job gets about this many frames. A job starts at a keyframe.
const frames_per_job = 90;
/// With `--debug-dir`, every frame with an index that is a multiple of this value
/// gets a picture with the detected pages.
const debug_frame_step = 15;
const debug_frames_dir = "frames";
const analysis_table_name = "analysis.csv";
const segments_table_name = "segments.csv";
const debug_segments_dir = "segments";
const debug_pages_dir = "pages";
/// The pages again, with a tint on each cell where the fusion found a fault.
const debug_faults_dir = "faults";
const debug_layers_dir = "layers";
/// The pages again, with a tint where the reference frame shows a finger and where
/// no other frame shows the page.
const debug_cover_dir = "cover";
const dedup_table_name = "duplicates.csv";
const fusion_table_name = "fusion.csv";
/// How much the part of a page outside the frame, and each page side that the frame
/// cuts, lower the quality of a spread in the duplicate search.
const outside_quality_weight = 2.0;
const clipped_quality_weight = 0.5;
/// Donor frames can also come from this much time before and after the stable time
/// of a spread. In that time the hand is at another place and the glare too.
const donor_margin_seconds = 1.2;
const pdf_buffer_bytes = 256 * 1024;
/// The working memory of one analysis job. One frame needs about 4 MB at 960 x 540.
const scratch_bytes = 96 * 1024 * 1024;

// endregion: constants

// region: frame ranges

pub const FrameRange = struct {
    /// The first frame. It is a keyframe.
    first: usize,
    count: usize,
};

/// Split the frames `first..end` into ranges that each start at a keyframe.
/// `first` must be a keyframe.
pub fn splitAtKeyframes(allocator: Allocator, info: *const ffmpeg.VideoInfo, first: usize, end: usize, target: usize) Allocator.Error![]FrameRange {
    var ranges: std.ArrayList(FrameRange) = .empty;
    errdefer ranges.deinit(allocator);
    var start = first;
    var index = first + 1;
    while (index < end) : (index += 1) {
        if (info.frames[index].key and index - start >= target) {
            try ranges.append(allocator, .{ .first = start, .count = index - start });
            start = index;
        }
    }
    if (end > start) try ranges.append(allocator, .{ .first = start, .count = end - start });
    return ranges.toOwnedSlice(allocator);
}

/// The size of the analysis frames: the short side is `short_side`, the two sides are even.
pub fn analysisSize(info: *const ffmpeg.VideoInfo, short_side: u32) image.Size {
    const source_short = @min(info.width, info.height);
    if (source_short <= short_side) return .{ .width = info.width & ~@as(u32, 1), .height = info.height & ~@as(u32, 1) };
    const factor = @as(f64, @floatFromInt(short_side)) / @as(f64, @floatFromInt(source_short));
    const width: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(info.width)) * factor / 2) * 2);
    const height: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(info.height)) * factor / 2) * 2);
    return .{ .width = width, .height = height };
}

// endregion: frame ranges

// region: analysis pass

pub const Analysis = struct {
    /// One observation for each frame of the video. Frames outside the processed
    /// range hold `FrameObservation.none`.
    observations: []FrameObservation,
    size: image.Size,
    first_frame: usize,
    end_frame: usize,

    pub fn deinit(self: Analysis, allocator: Allocator) void {
        allocator.free(self.observations);
    }
};

const AnalysisContext = struct {
    io: Io,
    gpa: Allocator,
    config: *const args.Config,
    info: *const ffmpeg.VideoInfo,
    ranges: []const FrameRange,
    size: image.Size,
    observations: []FrameObservation,
    detect_options: fastscan.detect.Options,
    /// The file with all analysis frames, when the cache directory is set.
    cache_file: ?Io.File,
    /// True when the cache file holds every frame from an earlier run.
    cache_complete: bool,
    debug_dir: ?Io.Dir,
    frames_done: *std.atomic.Value(usize),

    fn job(self: *const AnalysisContext, _: usize, range_index: usize) anyerror!void {
        const range = self.ranges[range_index];
        const frame_bytes = image.packedFrameSize(self.size.width, self.size.height);
        // One block of memory per job, used again for each frame. An arena on top of the
        // general allocator maps and unmaps memory for each frame, and the threads
        // then wait for each other in the kernel.
        const scratch = try self.gpa.alloc(u8, scratch_bytes);
        defer self.gpa.free(scratch);
        var arena_state: std.heap.FixedBufferAllocator = .init(scratch);

        if (self.cache_complete) {
            const buffer = try self.gpa.alloc(u8, frame_bytes);
            defer self.gpa.free(buffer);
            for (range.first..range.first + range.count) |frame_index| {
                const count = try self.cache_file.?.readPositionalAll(self.io, buffer, @as(u64, frame_index) * frame_bytes);
                if (count != frame_bytes) return error.TruncatedFrame;
                const frame = image.FrameView.fromPacked(buffer, self.size.width, self.size.height, self.info.colorimetry);
                try self.observeOne(&arena_state, frame, frame_index);
            }
            return;
        }

        const reader = try ffmpeg.FrameReader.open(self.io, self.gpa, self.info, .{
            .ffmpeg = self.config.ffmpeg,
            .hwaccel = self.config.hwaccel,
            .video = self.config.input,
            .first_frame = range.first,
            .frame_count = range.count,
            .scale = self.size,
        });
        defer reader.close();
        for (range.first..range.first + range.count) |frame_index| {
            // The packet list can name more frames than the decoder gives at the end of a video.
            const frame = (try reader.next()) orelse break;
            if (self.cache_file) |file| {
                try file.writePositionalAll(self.io, reader.frameBytes(), @as(u64, frame_index) * frame_bytes);
            }
            try self.observeOne(&arena_state, frame, frame_index);
        }
    }

    fn observeOne(self: *const AnalysisContext, arena_state: *std.heap.FixedBufferAllocator, frame: image.FrameView, frame_index: usize) !void {
        defer arena_state.reset();
        const arena = arena_state.allocator();
        const observation = try observe.observeFrame(arena, frame, self.detect_options);
        self.observations[frame_index] = observation;
        _ = self.frames_done.fetchAdd(1, .monotonic);

        if (self.debug_dir) |dir| {
            if (frame_index % debug_frame_step != 0) return;
            const rgb = try debug.frameToRgb(arena, frame);
            if (observation.detected) {
                const colors = [_]debug.Color{ debug.palette.left_page, debug.palette.right_page };
                for (observation.pageSlice(), 0..) |*page, page_index| {
                    debug.drawCoveredCells(rgb, page);
                    debug.drawQuad(rgb, page.quad, colors[page_index]);
                }
            } else {
                debug.drawQuad(rgb, fastscan.geometry.Quad.rect(@floatFromInt(rgb.width - 1), @floatFromInt(rgb.height - 1)), debug.palette.not_detected);
            }
            var name_buffer: [64]u8 = undefined;
            const name = try std.mem.print(&name_buffer, debug_frames_dir ++ "/f_{d:0>6}.jpg", .{frame_index});
            try debug.writeJpeg(self.io, arena, dir, name, rgb);
        }
    }
};

/// Decode every frame of the selected time range at a small size and observe it.
pub fn analyze(io: Io, gpa: Allocator, config: *const args.Config, info: *const ffmpeg.VideoInfo, worker_count: usize) !Analysis {
    const frame_count = info.frames.len;
    const requested_first = if (config.from_seconds) |time| info.frameAtSeconds(time) else 0;
    const end = if (config.to_seconds) |time| info.frameAtSeconds(time) else frame_count;
    if (requested_first >= end) return error.EmptyTimeRange;
    const first = info.keyframeAtOrBefore(requested_first);

    const size = analysisSize(info, config.analysis_height);
    const frame_bytes = image.packedFrameSize(size.width, size.height);

    const observations = try gpa.alloc(FrameObservation, frame_count);
    errdefer gpa.free(observations);
    @memset(observations, FrameObservation.none);

    const ranges = try splitAtKeyframes(gpa, info, first, end, frames_per_job);
    defer gpa.free(ranges);

    // The cache: one file with all analysis frames, and a marker file that says the
    // file is complete.
    var cache_file: ?Io.File = null;
    defer if (cache_file) |file| file.close(io);
    var cache_complete = false;
    var cache_dir: ?Io.Dir = null;
    defer if (cache_dir) |dir| dir.close(io);
    var cache_name_buffer: [96]u8 = undefined;
    var marker_name_buffer: [96]u8 = undefined;
    var marker_name: []const u8 = "";
    if (config.cache_dir) |path| {
        const dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{});
        cache_dir = dir;
        const cache_name = try analysisCacheName(&cache_name_buffer, size, frame_count);
        marker_name = try std.mem.print(&marker_name_buffer, "{s}.complete", .{cache_name});
        const expected_bytes = @as(u64, frame_count) * frame_bytes;
        if (dir.access(io, marker_name, .{})) |_| {
            const file = try dir.openFile(io, cache_name, .{});
            if (try file.length(io) == expected_bytes) {
                cache_file = file;
                cache_complete = true;
            } else {
                file.close(io);
            }
        } else |_| {}
        if (!cache_complete) {
            const file = try dir.createFile(io, cache_name, .{ .read = true, .truncate = true });
            try file.setLength(io, expected_bytes);
            cache_file = file;
        }
    }

    var debug_dir: ?Io.Dir = null;
    defer if (debug_dir) |dir| dir.close(io);
    if (config.debug_dir) |path| {
        const dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{});
        debug_dir = dir;
        try dir.createDirPath(io, debug_frames_dir);
    }

    var frames_done: std.atomic.Value(usize) = .init(0);
    const context: AnalysisContext = .{
        .io = io,
        .gpa = gpa,
        .config = config,
        .info = info,
        .ranges = ranges,
        .size = size,
        .observations = observations,
        .detect_options = .{ .layout = config.layout },
        .cache_file = cache_file,
        .cache_complete = cache_complete,
        .debug_dir = debug_dir,
        .frames_done = &frames_done,
    };
    try parallel.forEach(io, worker_count, ranges.len, &context, AnalysisContext.job);

    // The cache is complete only after a run over the whole video.
    if (cache_dir) |dir| {
        if (!cache_complete and first == 0 and end == frame_count) {
            try dir.writeFile(io, .{ .sub_path = marker_name, .data = "" });
        }
    }
    if (debug_dir) |dir| try writeAnalysisTable(io, gpa, dir, info, observations, first, end);

    return .{ .observations = observations, .size = size, .first_frame = first, .end_frame = end };
}

fn analysisCacheName(buffer: []u8, size: image.Size, frame_count: usize) ![]const u8 {
    return std.mem.print(buffer, "analysis-{d}x{d}-{d}.yuv", .{ size.width, size.height, frame_count });
}

/// One line per frame, for a spreadsheet or a plot.
fn writeAnalysisTable(
    io: Io,
    gpa: Allocator,
    dir: Io.Dir,
    info: *const ffmpeg.VideoInfo,
    observations: []const FrameObservation,
    first: usize,
    end: usize,
) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "frame,seconds,detected,pages,clipped,gutter_response,edge_support,covered_0,covered_1,similarity_to_previous,motion_from_previous");
    // The corners of each page in pixels of the analysis frame: top left, top right,
    // bottom right, bottom left.
    for (0..fastscan.detect.max_pages) |page| {
        for ([_][]const u8{ "tl", "tr", "br", "bl" }) |corner| {
            var name_buffer: [32]u8 = undefined;
            try text.appendSlice(gpa, try std.mem.print(&name_buffer, ",p{d}_{s}_x,p{d}_{s}_y", .{ page, corner, page, corner }));
        }
    }
    try text.append(gpa, '\n');
    var line_buffer: [256]u8 = undefined;
    for (first..end) |index| {
        const observation = &observations[index];
        const previous: ?*const FrameObservation = if (index > first) &observations[index - 1] else null;
        const similarity: f32 = if (previous) |p| observe.frameSimilarity(p, observation) orelse -2 else -2;
        const motion: f32 = if (previous) |p| observe.frameMotion(p, observation) orelse -1 else -1;
        const covered_0: f32 = if (observation.detected) observation.pages[0].coveredFraction() else 0;
        const covered_1: f32 = if (observation.pageCount() > 1) observation.pages[1].coveredFraction() else 0;
        const line = try std.mem.print(&line_buffer, "{d},{d:.3},{d},{d},{d},{d:.2},{d:.2},{d:.3},{d:.3},{d:.3},{d:.4}", .{
            index,
            info.seconds(index),
            @intFromBool(observation.detected),
            observation.pageCount(),
            @intFromBool(observation.detected and observation.clipped),
            if (observation.detected) observation.gutter_response else 0,
            if (observation.detected) observation.edge_support else 0,
            covered_0,
            covered_1,
            similarity,
            motion,
        });
        try text.appendSlice(gpa, line);
        for (0..fastscan.detect.max_pages) |page| {
            const corners: [4]fastscan.geometry.Point = if (page < observation.pageCount())
                observation.pages[page].quad.corners()
            else
                @splat(fastscan.geometry.Point.zero);
            for (corners) |corner| {
                try text.appendSlice(gpa, try std.mem.print(&line_buffer, ",{d:.1},{d:.1}", .{ corner.x, corner.y }));
            }
        }
        try text.append(gpa, '\n');
    }
    try dir.writeFile(io, .{ .sub_path = analysis_table_name, .data = text.items });
}

// endregion: analysis pass

// region: timeline debug output

/// Write a table of the spreads and, when the frame cache exists, a picture of the
/// reference frame of each spread with its pages.
pub fn writeTimelineDebug(
    io: Io,
    gpa: Allocator,
    config: *const args.Config,
    info: *const ffmpeg.VideoInfo,
    analysis: *const Analysis,
    timeline: *const fastscan.timeline.Timeline,
) !void {
    const debug_path = config.debug_dir orelse return;
    const dir = try Io.Dir.cwd().createDirPathOpen(io, debug_path, .{});
    defer dir.close(io);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "segment,pages,first_frame,last_frame,first_seconds,last_seconds,stable_frames,reference,reference_seconds,covered,edge_support,clipped_edges,similarity_to_previous\n");
    var line_buffer: [256]u8 = undefined;
    for (timeline.segments, 0..) |segment, index| {
        const reference = &analysis.observations[segment.reference];
        const similarity: f32 = if (index > 0)
            observe.frameSimilarity(&analysis.observations[timeline.segments[index - 1].reference], reference) orelse -2
        else
            -2;
        try text.appendSlice(gpa, try std.mem.print(&line_buffer, "{d},{d},{d},{d},{d:.2},{d:.2},{d},{d},{d:.2},{d:.3},{d:.2},{d},{d:.3}\n", .{
            index,
            segment.kind.pageCount(),
            segment.first_frame,
            segment.last_frame,
            info.seconds(segment.first_frame),
            info.seconds(segment.last_frame),
            segment.stable_frames,
            segment.reference,
            info.seconds(segment.reference),
            reference.coveredFraction(),
            reference.edge_support,
            reference.clippedEdgeCount(),
            similarity,
        }));
    }
    try dir.writeFile(io, .{ .sub_path = segments_table_name, .data = text.items });

    // The pictures need the analysis frames of the cache.
    const cache_path = config.cache_dir orelse return;
    const cache_dir = Io.Dir.cwd().openDir(io, cache_path, .{}) catch return;
    defer cache_dir.close(io);
    var name_buffer: [96]u8 = undefined;
    const cache_file = cache_dir.openFile(io, try analysisCacheName(&name_buffer, analysis.size, info.frames.len), .{}) catch return;
    defer cache_file.close(io);

    try dir.createDirPath(io, debug_segments_dir);
    const frame_bytes = image.packedFrameSize(analysis.size.width, analysis.size.height);
    const buffer = try gpa.alloc(u8, frame_bytes);
    defer gpa.free(buffer);
    for (timeline.segments, 0..) |segment, index| {
        const count = try cache_file.readPositionalAll(io, buffer, @as(u64, segment.reference) * frame_bytes);
        if (count != frame_bytes) return error.TruncatedFrame;
        const frame = image.FrameView.fromPacked(buffer, analysis.size.width, analysis.size.height, info.colorimetry);
        const rgb = try debug.frameToRgb(gpa, frame);
        defer rgb.deinit(gpa);
        const colors = [_]debug.Color{ debug.palette.left_page, debug.palette.right_page };
        for (analysis.observations[segment.reference].pageSlice(), 0..) |*page, page_index| {
            debug.drawCoveredCells(rgb, page);
            debug.drawQuad(rgb, page.quad, colors[page_index]);
        }
        var picture_name_buffer: [64]u8 = undefined;
        const name = try std.mem.print(&picture_name_buffer, debug_segments_dir ++ "/s_{d:0>3}_f_{d:0>6}.jpg", .{ index, segment.reference });
        try debug.writeJpeg(io, gpa, dir, name, rgb);
    }
}

// endregion: timeline debug output

// region: render pass

pub const RenderedDocument = struct {
    /// The pages in the order of the video.
    pages: []fastscan.render.EncodedPage,
    page_size: image.Size,
    /// The number of spreads after the duplicate search.
    spreads: usize,
    /// The number of spreads that the duplicate search removed.
    duplicate_spreads: usize,
    /// The number of donor frames that registered, over all pages.
    donors_used: usize,
    /// The number of pages that were rendered with the curved page map.
    curled_pages: usize,
    /// Mean fractions of the page area, over all pages.
    glare: f32,
    cover: f32,
    outside: f32,
    unrepaired: f32,
    /// The part of the faults where no donor agreed with the reference around the fault.
    rejected: f32,
    /// A finger in all frames that has the colour of the paper now.
    painted: f32,
    /// A finger in all frames that stays, with ink around it.
    finger_left: f32,
    /// The number of pages with a finger that stays.
    finger_pages: usize,
    /// The large blocks of working memory of all workers.
    memory: BlockCache.Stats,

    pub fn deinit(self: RenderedDocument, allocator: Allocator) void {
        for (self.pages) |page| page.deinit(allocator);
        allocator.free(self.pages);
    }
};

/// Full-size frames by index: from the cache directory, or decoded with ffmpeg.
const FrameStore = struct {
    io: Io,
    gpa: Allocator,
    config: *const args.Config,
    info: *const ffmpeg.VideoInfo,
    cache_dir: ?Io.Dir,

    fn frameBytes(self: *const FrameStore) usize {
        return image.packedFrameSize(self.info.width, self.info.height);
    }

    fn cacheName(self: *const FrameStore, buffer: []u8, frame_index: usize) ![]const u8 {
        return std.mem.print(buffer, "frame-{d}x{d}-{d:0>6}.yuv", .{ self.info.width, self.info.height, frame_index });
    }

    /// Fill `buffers[i]` with frame `indexes[i]`. Each index must be larger than the
    /// index before it.
    fn load(self: *const FrameStore, indexes: []const u32, buffers: []const []u8) !void {
        std.debug.assert(indexes.len == buffers.len);
        for (indexes[1..], indexes[0 .. indexes.len - 1]) |later, earlier| std.debug.assert(later > earlier);
        const loaded = try self.gpa.alloc(bool, indexes.len);
        defer self.gpa.free(loaded);
        @memset(loaded, false);
        var name_buffer: [64]u8 = undefined;
        if (self.cache_dir) |dir| {
            for (indexes, buffers, loaded) |frame_index, buffer, *done| {
                const file = dir.openFile(self.io, try self.cacheName(&name_buffer, frame_index), .{}) catch continue;
                defer file.close(self.io);
                done.* = (try file.readPositionalAll(self.io, buffer, 0)) == buffer.len;
            }
        }

        // One decoder run gives all missing frames up to the next keyframe that
        // lies between two of them.
        var position: usize = 0;
        while (position < indexes.len) {
            if (loaded[position]) {
                position += 1;
                continue;
            }
            const first = self.info.keyframeAtOrBefore(indexes[position]);
            var last_position = position;
            var scan = position + 1;
            while (scan < indexes.len) : (scan += 1) {
                if (loaded[scan]) continue;
                // A frame after a later keyframe starts faster from that keyframe.
                if (self.info.keyframeAtOrBefore(indexes[scan]) > indexes[last_position]) break;
                last_position = scan;
            }
            const last_frame = indexes[last_position];
            const reader = try ffmpeg.FrameReader.open(self.io, self.gpa, self.info, .{
                .ffmpeg = self.config.ffmpeg,
                .hwaccel = self.config.hwaccel,
                .video = self.config.input,
                .first_frame = first,
                .frame_count = last_frame - first + 1,
            });
            defer reader.close();
            var want = position;
            for (first..last_frame + 1) |frame_index| {
                _ = (try reader.next()) orelse break;
                while (want <= last_position and (loaded[want] or indexes[want] < frame_index)) want += 1;
                if (want > last_position) break;
                if (indexes[want] != frame_index) continue;
                @memcpy(buffers[want], reader.frameBytes());
                loaded[want] = true;
                if (self.cache_dir) |dir| {
                    try dir.writeFile(self.io, .{ .sub_path = try self.cacheName(&name_buffer, frame_index), .data = buffers[want] });
                }
            }
            position = last_position + 1;
        }
        for (loaded, indexes) |done, frame_index| {
            if (!done) {
                std.debug.print("frame {d} did not decode (the video has {d} frames)\n", .{ frame_index, self.info.frames.len });
                return error.TruncatedFrame;
            }
        }
    }

    /// What the analysis pass knows about a frame, in pixels of the full frame.
    fn source(self: *const FrameStore, analysis: *const Analysis, frame_index: usize, buffer: []const u8) fastscan.render.SourceFrame {
        const observation = &analysis.observations[frame_index];
        const scale = @as(f32, @floatFromInt(self.info.width)) / @as(f32, @floatFromInt(analysis.size.width));
        var result: fastscan.render.SourceFrame = .{
            .frame = image.FrameView.fromPacked(buffer, self.info.width, self.info.height, self.info.colorimetry),
            .quads = undefined,
            .clipped_edges = undefined,
        };
        for (&result.quads, &result.clipped_edges, 0..) |*quad, *edges, index| {
            quad.* = scaleQuad(observation.pages[index].quad, scale);
            edges.* = observation.pages[index].clipped_edges;
        }
        return result;
    }
};

/// A quad of the analysis frame in pixels of the full frame. Pixel centers are at
/// integer coordinates in the two frames.
fn scaleQuad(quad: fastscan.geometry.Quad, scale: f32) fastscan.geometry.Quad {
    const Convert = struct {
        fn point(p: fastscan.geometry.Point, factor: f32) fastscan.geometry.Point {
            return .{ .x = (p.x + 0.5) * factor - 0.5, .y = (p.y + 0.5) * factor - 0.5 };
        }
    };
    return .{
        .tl = Convert.point(quad.tl, scale),
        .tr = Convert.point(quad.tr, scale),
        .br = Convert.point(quad.br, scale),
        .bl = Convert.point(quad.bl, scale),
    };
}

// The first step: a small picture of each spread, for the duplicate search.

const SignatureResult = struct {
    signature: ?fastscan.render.SpreadSignature = null,
    /// The quality for the duplicate search. Higher is better.
    quality: f32 = 0,
};

const SignatureContext = struct {
    store: *const FrameStore,
    analysis: *const Analysis,
    segments: []const fastscan.timeline.Segment,
    page_size: image.Size,
    options: fastscan.render.Options,
    results: []SignatureResult,
    /// The working memory of each worker.
    caches: []BlockCache,

    fn job(self: *const SignatureContext, worker: usize, segment_index: usize) anyerror!void {
        const store = self.store;
        const segment = self.segments[segment_index];
        const memory = self.caches[worker].allocator();
        const buffer = try memory.alloc(u8, store.frameBytes());
        defer memory.free(buffer);
        try store.load(&.{segment.reference}, &.{buffer});

        // The signature stays after the job, so it does not come from the cache.
        const signature = try fastscan.render.renderSignature(
            store.gpa,
            memory,
            store.source(self.analysis, segment.reference, buffer),
            segment.kind,
            self.page_size,
            self.options,
        );
        if (signature.page_count != segment.kind.pageCount()) {
            signature.deinit(store.gpa);
            return;
        }
        self.results[segment_index] = .{
            .signature = signature,
            .quality = segment.score -
                outside_quality_weight * signature.outside_fraction -
                clipped_quality_weight * @as(f32, @floatFromInt(signature.clipped_edge_count)),
        };
    }
};

// The second step: the pages of each spread that stays, repaired with donor frames.

const max_spread_members = 8;

const SpreadPlan = struct {
    segment: u32,
    /// The frame that gives the picture of each page.
    references: [fastscan.detect.max_pages]fastscan.timeline.Reference,
    /// The stable time of each view of this spread: the references come from here.
    views: [max_spread_members]fastscan.timeline.FrameSpan,
    /// The time ranges for donor frames: the views with the time around them.
    spans: [max_spread_members]fastscan.timeline.FrameSpan,
    span_count: usize,
};

const PageReport = struct {
    curled: bool = false,
    donor_frames: u8 = 0,
    donors_used: u8 = 0,
    fusion: fastscan.fuse.Stats = .{},
    outside_fraction: f32 = 0,
};

const SpreadResult = struct {
    pages: [fastscan.detect.max_pages]?fastscan.render.EncodedPage = @splat(null),
    reports: [fastscan.detect.max_pages]PageReport = @splat(.{}),

    fn deinit(self: SpreadResult, allocator: Allocator) void {
        for (self.pages) |maybe_page| if (maybe_page) |page| page.deinit(allocator);
    }
};

const RenderContext = struct {
    store: *const FrameStore,
    analysis: *const Analysis,
    segments: []const fastscan.timeline.Segment,
    plans: []const SpreadPlan,
    page_size: image.Size,
    options: fastscan.render.Options,
    donor_options: fastscan.timeline.DonorOptions,
    results: []SpreadResult,
    /// The working memory of each worker.
    caches: []BlockCache,
    debug_dir: ?Io.Dir,

    fn job(self: *const RenderContext, worker: usize, plan_index: usize) anyerror!void {
        const plan = self.plans[plan_index];
        const memory = self.caches[worker].allocator();
        const page_count = self.segments[plan.segment].kind.pageCount();

        var result: SpreadResult = .{};
        errdefer result.deinit(self.store.gpa);
        // Pages with the same reference frame share the donor frames and one render call.
        var shared = true;
        for (plan.references[0..page_count]) |reference| shared = shared and reference.frame == plan.references[0].frame;
        if (shared) {
            try self.renderPages(memory, plan_index, plan.references[0].frame, null, &result);
        } else {
            for (0..page_count) |page_index| {
                try self.renderPages(memory, plan_index, plan.references[page_index].frame, page_index, &result);
            }
        }
        self.results[plan_index] = result;
    }

    /// Render one page of a spread from its reference frame, or all pages when
    /// `only_page` is null, and put the encoded pages into `result`. `memory` gives
    /// the frames and the working memory; the encoded pages come from the general
    /// allocator, because they stay after the job.
    fn renderPages(
        self: *const RenderContext,
        memory: Allocator,
        plan_index: usize,
        reference_index: u32,
        only_page: ?usize,
        result: *SpreadResult,
    ) anyerror!void {
        const store = self.store;
        const gpa = store.gpa;
        const plan = self.plans[plan_index];
        const segment = self.segments[plan.segment];

        const donors = try fastscan.timeline.selectDonors(
            gpa,
            self.analysis.observations,
            plan.spans[0..plan.span_count],
            reference_index,
            only_page,
            self.donor_options,
        );
        defer gpa.free(donors);

        // The reference frame and the donor frames, in the order of the video.
        const frame_count = donors.len + 1;
        const indexes = try gpa.alloc(u32, frame_count);
        defer gpa.free(indexes);
        indexes[0] = reference_index;
        @memcpy(indexes[1..], donors);
        std.mem.sort(u32, indexes, {}, std.sort.asc(u32));
        const buffers = try gpa.alloc([]u8, frame_count);
        defer gpa.free(buffers);
        var allocated: usize = 0;
        defer for (buffers[0..allocated]) |buffer| memory.free(buffer);
        for (buffers) |*buffer| {
            buffer.* = try memory.alloc(u8, store.frameBytes());
            allocated += 1;
        }
        try store.load(indexes, buffers);

        var reference: fastscan.render.SourceFrame = undefined;
        const donor_sources = try gpa.alloc(fastscan.render.SourceFrame, donors.len);
        defer gpa.free(donor_sources);
        var donor_count: usize = 0;
        for (indexes, buffers) |frame_index, buffer| {
            const source = store.source(self.analysis, frame_index, buffer);
            if (frame_index == reference_index) {
                reference = source;
            } else {
                donor_sources[donor_count] = source;
                donor_count += 1;
            }
        }

        const spread = try fastscan.render.renderSpread(
            memory,
            memory,
            reference,
            donor_sources[0..donor_count],
            segment.kind,
            only_page,
            self.page_size,
            self.options,
        );
        defer spread.deinit(memory);

        for (spread.pageSlice()) |*page| {
            const page_index: usize = page.index;
            const encoded = try fastscan.render.encodePage(gpa, memory, page.rgb, self.options.jpeg);
            result.pages[page_index] = encoded;
            result.reports[page_index] = .{
                .curled = page.curled,
                .donor_frames = @intCast(donor_count),
                .donors_used = page.donors_used,
                .fusion = page.fusion,
                .outside_fraction = page.outside_fraction,
            };
            if (self.debug_dir) |dir| {
                var name_buffer: [64]u8 = undefined;
                const name = try std.mem.print(&name_buffer, debug_pages_dir ++ "/p_{d:0>3}_{d}.jpg", .{ plan_index, page_index });
                try dir.writeFile(store.io, .{ .sub_path = name, .data = encoded.jpeg });
                for (page.layers, 0..) |layer, layer_index| {
                    const layer_name = try std.mem.print(&name_buffer, debug_layers_dir ++ "/p_{d:0>3}_{d}_{d:0>2}.jpg", .{ plan_index, page_index, layer_index });
                    try debug.writeJpeg(store.io, memory, dir, layer_name, layer);
                }
                if (page.faults) |*faults| {
                    // The picture of the page is done, so the tints can go onto it.
                    const cover = try fastscan.image.Rgb8.init(memory, page.rgb.width, page.rgb.height);
                    defer cover.deinit(memory);
                    @memcpy(cover.data, page.rgb.data);
                    debug.drawCover(cover, faults);
                    const cover_name = try std.mem.print(&name_buffer, debug_cover_dir ++ "/p_{d:0>3}_{d}.jpg", .{ plan_index, page_index });
                    try debug.writeJpeg(store.io, memory, dir, cover_name, cover);
                    debug.drawFaults(page.rgb, faults);
                    const faults_name = try std.mem.print(&name_buffer, debug_faults_dir ++ "/p_{d:0>3}_{d}.jpg", .{ plan_index, page_index });
                    try debug.writeJpeg(store.io, memory, dir, faults_name, page.rgb);
                }
            }
        }
    }
};

/// Find the spreads that stay after the duplicate search, and render their pages.
pub fn renderDocument(
    io: Io,
    gpa: Allocator,
    config: *const args.Config,
    info: *const ffmpeg.VideoInfo,
    analysis: *const Analysis,
    timeline: *const fastscan.timeline.Timeline,
    worker_count: usize,
) !RenderedDocument {
    const segments = timeline.segments;
    const frame_scale = @as(f32, @floatFromInt(info.width)) / @as(f32, @floatFromInt(analysis.size.width));
    const page_geometry = (try fastscan.document.pageGeometry(gpa, analysis.observations, segments, analysis.size, frame_scale, .{})) orelse
        return error.NoPagesFound;

    var cache_dir: ?Io.Dir = null;
    defer if (cache_dir) |dir| dir.close(io);
    if (config.cache_dir) |path| cache_dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{});
    var debug_dir: ?Io.Dir = null;
    defer if (debug_dir) |dir| dir.close(io);
    if (config.debug_dir) |path| {
        const dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{});
        debug_dir = dir;
        try dir.createDirPath(io, debug_pages_dir);
        try dir.createDirPath(io, debug_faults_dir);
        try dir.createDirPath(io, debug_cover_dir);
        if (config.debug_layers) try dir.createDirPath(io, debug_layers_dir);
    }

    const store: FrameStore = .{ .io = io, .gpa = gpa, .config = config, .info = info, .cache_dir = cache_dir };
    // Each worker keeps its large blocks from one job to the next one.
    const caches = try gpa.alloc(BlockCache, @max(1, worker_count));
    defer gpa.free(caches);
    for (caches) |*cache| cache.* = .init(gpa);
    defer for (caches) |*cache| cache.deinit();
    const options: fastscan.render.Options = .{
        .detect = .{ .layout = config.layout },
        .jpeg = .{ .quality = config.quality, .dpi = config.dpi },
        .curl = config.curl,
        .fuse = .{ .finger = .{ .paint = config.fingers } },
        .fault_maps = config.debug_dir != null,
        .layer_pictures = config.debug_layers and config.debug_dir != null,
    };

    // Step 1: a small picture of each spread.
    const signature_results = try gpa.alloc(SignatureResult, segments.len);
    defer gpa.free(signature_results);
    @memset(signature_results, .{});
    defer for (signature_results) |result| if (result.signature) |signature| signature.deinit(gpa);
    const signature_context: SignatureContext = .{
        .store = &store,
        .analysis = analysis,
        .segments = segments,
        .page_size = page_geometry.size,
        .options = options,
        .results = signature_results,
        .caches = caches,
    };
    try parallel.forEach(io, worker_count, segments.len, &signature_context, SignatureContext.job);

    // Step 2: spreads that register with each other are one spread.
    var candidates: std.ArrayList(fastscan.dedup.Candidate) = .empty;
    defer candidates.deinit(gpa);
    var candidate_segments: std.ArrayList(u32) = .empty;
    defer candidate_segments.deinit(gpa);
    for (signature_results, segments, 0..) |*result, segment, segment_index| {
        const signature = result.signature orelse continue;
        var candidate: fastscan.dedup.Candidate = .{
            .kind = segment.kind,
            .signatures = undefined,
            .quality = result.quality,
            .weak = segment.weak,
        };
        for (&candidate.signatures, 0..) |*plane, page_index| {
            plane.* = signature.pages[if (page_index < signature.page_count) page_index else 0].view();
        }
        try candidates.append(gpa, candidate);
        try candidate_segments.append(gpa, @intCast(segment_index));
    }
    var comparisons: std.ArrayList(fastscan.dedup.Comparison) = .empty;
    defer comparisons.deinit(gpa);
    const resolution = try fastscan.dedup.resolve(gpa, candidates.items, .{}, &comparisons);
    defer resolution.deinit(gpa);

    // The spread that each segment belongs to after the duplicate search.
    const segment_owner = try gpa.alloc(?u32, segments.len);
    defer gpa.free(segment_owner);
    @memset(segment_owner, null);
    for (resolution.owner, 0..) |owner, candidate_index| {
        segment_owner[candidate_segments.items[candidate_index]] = candidate_segments.items[owner];
    }
    const duration = info.seconds(info.frames.len - 1);
    const frames_per_second = if (duration > 0) @as(f64, @floatFromInt(info.frames.len - 1)) / duration else 30.0;
    const donor_margin: u32 = @intFromFloat(@round(donor_margin_seconds * frames_per_second));

    // Each spread that stays, with the time ranges of all of its views. A range also
    // has the time around the stable frames, up to the stable frames of the spread
    // before and after it.
    const plans = try gpa.alloc(SpreadPlan, resolution.kept.len);
    defer gpa.free(plans);
    for (plans, resolution.kept) |*plan, kept_candidate| {
        const owner_segment = candidate_segments.items[kept_candidate];
        plan.* = .{
            .segment = owner_segment,
            .references = @splat(.{ .frame = segments[owner_segment].reference, .ink = 1, .score = segments[owner_segment].score }),
            .views = undefined,
            .spans = undefined,
            .span_count = 0,
        };
        for (segments, 0..) |member, member_index| {
            if (segment_owner[member_index] != owner_segment or plan.span_count == max_spread_members) continue;
            // Only views with the same layout can give frames to each other.
            if (member.kind != segments[owner_segment].kind) continue;
            var lower_limit: u32 = 0;
            var before = member_index;
            while (before > 0) {
                before -= 1;
                if (segment_owner[before] == owner_segment) continue;
                lower_limit = segments[before].last_frame + 1;
                break;
            }
            var upper_limit: u32 = @intCast(info.frames.len - 1);
            for (segments[member_index + 1 ..], member_index + 1..) |later, later_index| {
                if (segment_owner[later_index] == owner_segment) continue;
                upper_limit = later.first_frame -| 1;
                break;
            }
            plan.views[plan.span_count] = .{ .first = member.first_frame, .last = member.last_frame };
            plan.spans[plan.span_count] = .{
                .first = @max(lower_limit, member.first_frame -| donor_margin),
                .last = @min(upper_limit, member.last_frame + donor_margin),
            };
            plan.span_count += 1;
        }
        // Each page comes from the frame that shows it best in all the views.
        for (0..segments[owner_segment].kind.pageCount()) |page_index| {
            plan.references[page_index] = try fastscan.timeline.chooseReference(
                gpa,
                analysis.observations,
                plan.views[0..plan.span_count],
                segments[owner_segment].reference,
                page_index,
                .{ .page_aspect = page_geometry.aspect },
            );
        }
    }

    // Step 3: the pages.
    const results = try gpa.alloc(SpreadResult, plans.len);
    defer gpa.free(results);
    @memset(results, .{});
    // The pages that go into the document leave `results`; all the rest is freed here.
    defer for (results) |result| result.deinit(gpa);
    const render_context: RenderContext = .{
        .store = &store,
        .analysis = analysis,
        .segments = segments,
        .plans = plans,
        .page_size = page_geometry.size,
        .options = options,
        .donor_options = .{ .count = config.fusion_frames, .page_aspect = page_geometry.aspect },
        .results = results,
        .caches = caches,
        .debug_dir = debug_dir,
    };
    try parallel.forEach(io, worker_count, plans.len, &render_context, RenderContext.job);

    if (debug_dir) |dir| {
        try writeDuplicateTable(io, gpa, dir, comparisons.items, candidate_segments.items, resolution.kept);
        try writeFusionTable(io, gpa, dir, segments, plans, results);
    }

    var document: RenderedDocument = .{
        .pages = &.{},
        .page_size = page_geometry.size,
        .spreads = plans.len,
        .duplicate_spreads = candidates.items.len - plans.len,
        .donors_used = 0,
        .curled_pages = 0,
        .glare = 0,
        .cover = 0,
        .outside = 0,
        .unrepaired = 0,
        .rejected = 0,
        .painted = 0,
        .finger_left = 0,
        .finger_pages = 0,
        .memory = .{},
    };
    for (caches) |*cache| document.memory.add(cache.stats);
    var pages: std.ArrayList(fastscan.render.EncodedPage) = .empty;
    errdefer {
        for (pages.items) |page| page.deinit(gpa);
        pages.deinit(gpa);
    }
    for (results) |*result| {
        for (&result.pages, result.reports) |*maybe_page, report| {
            const page = maybe_page.* orelse continue;
            try pages.append(gpa, page);
            // The document owns the page now.
            maybe_page.* = null;
            document.donors_used += report.donors_used;
            if (report.curled) document.curled_pages += 1;
            document.glare += report.fusion.glare;
            document.cover += report.fusion.cover;
            document.outside += report.fusion.outside;
            document.unrepaired += report.fusion.unrepaired;
            document.rejected += report.fusion.rejected;
            document.painted += report.fusion.painted;
            document.finger_left += report.fusion.finger_left;
            if (report.fusion.finger_left > 0) document.finger_pages += 1;
        }
    }
    if (pages.items.len > 0) {
        const count: f32 = @floatFromInt(pages.items.len);
        document.glare /= count;
        document.cover /= count;
        document.outside /= count;
        document.unrepaired /= count;
        document.rejected /= count;
        document.painted /= count;
        document.finger_left /= count;
    }
    document.pages = try pages.toOwnedSlice(gpa);
    return document;
}

fn writeDuplicateTable(
    io: Io,
    gpa: Allocator,
    dir: Io.Dir,
    comparisons: []const fastscan.dedup.Comparison,
    candidate_segments: []const u32,
    kept: []const u32,
) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "first_segment,second_segment,same,matched_page_0,matched_page_1\n");
    var line_buffer: [128]u8 = undefined;
    for (comparisons) |comparison| {
        try text.appendSlice(gpa, try std.mem.print(&line_buffer, "{d},{d},{d},{d:.3},{d:.3}\n", .{
            candidate_segments[comparison.first],
            candidate_segments[comparison.second],
            @intFromBool(comparison.same),
            comparison.matched[0],
            comparison.matched[1],
        }));
    }
    try text.appendSlice(gpa, "kept_segments");
    for (kept) |candidate_index| {
        try text.appendSlice(gpa, try std.mem.print(&line_buffer, ",{d}", .{candidate_segments[candidate_index]}));
    }
    try text.append(gpa, '\n');
    try dir.writeFile(io, .{ .sub_path = dedup_table_name, .data = text.items });
}

/// One line per page: how many frames helped and what the fusion repaired.
fn writeFusionTable(
    io: Io,
    gpa: Allocator,
    dir: Io.Dir,
    segments: []const fastscan.timeline.Segment,
    plans: []const SpreadPlan,
    results: []const SpreadResult,
) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "spread,segment,first_reference,reference,reference_ink,page,curled,donor_frames,donors_used,glare,cover,outside,unrepaired,rejected,finger_painted,finger_left,outside_after\n");
    var line_buffer: [224]u8 = undefined;
    for (plans, results, 0..) |plan, result, spread_index| {
        // The reference that the timeline chose, before the glare of the frames was known.
        const first_reference = segments[plan.segment].reference;
        for (result.pages, result.reports, 0..) |maybe_page, report, page_index| {
            if (maybe_page == null) continue;
            try text.appendSlice(gpa, try std.mem.print(&line_buffer, "{d},{d},{d},{d},{d:.4},{d},{d},{d},{d},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4}\n", .{
                spread_index,
                plan.segment,
                first_reference,
                plan.references[page_index].frame,
                plan.references[page_index].ink,
                page_index,
                @intFromBool(report.curled),
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
    }
    try dir.writeFile(io, .{ .sub_path = fusion_table_name, .data = text.items });
}

/// Write the pages into a PDF file.
pub fn writePdf(io: Io, gpa: Allocator, path: []const u8, document: *const RenderedDocument, dpi: u16) !u64 {
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
    var writer = try fastscan.pdf.Writer.init(
        gpa,
        .{ .context = &file_writer.interface, .writeFn = Sink.write },
        .{ .producer = "fastest-scan " ++ fastscan.version },
    );
    defer writer.deinit();
    for (document.pages) |page| {
        try writer.addPage(.{
            .jpeg = page.jpeg,
            .width_px = page.width,
            .height_px = page.height,
            .color_space = if (page.gray) .gray else .rgb,
            .dpi = @floatFromInt(dpi),
        });
    }
    try writer.finish();
    try file_writer.interface.flush();
    return file_writer.logicalPos();
}

// endregion: render pass

// region: tests

const testing = std.testing;

test "ranges start at keyframes and cover all frames" {
    var frames: [10]ffmpeg.FrameEntry = undefined;
    for (&frames, 0..) |*frame, index| frame.* = .{ .pts = @intCast(index), .key = index % 3 == 0 };
    const info: ffmpeg.VideoInfo = .{
        .width = 64,
        .height = 36,
        .colorimetry = .{},
        .time_base_numerator = 1,
        .time_base_denominator = 30,
        .frames = &frames,
    };
    const ranges = try splitAtKeyframes(testing.allocator, &info, 0, frames.len, 4);
    defer testing.allocator.free(ranges);
    try testing.expectEqual(@as(usize, 2), ranges.len);
    try testing.expectEqual(FrameRange{ .first = 0, .count = 6 }, ranges[0]);
    try testing.expectEqual(FrameRange{ .first = 6, .count = 4 }, ranges[1]);
}

test "the analysis size keeps the aspect ratio and has even sides" {
    const landscape: ffmpeg.VideoInfo = .{ .width = 3840, .height = 2160, .colorimetry = .{}, .time_base_numerator = 1, .time_base_denominator = 30, .frames = &.{} };
    try testing.expectEqual(image.Size{ .width = 960, .height = 540 }, analysisSize(&landscape, 540));
    const portrait: ffmpeg.VideoInfo = .{ .width = 1080, .height = 1920, .colorimetry = .{}, .time_base_numerator = 1, .time_base_denominator = 30, .frames = &.{} };
    try testing.expectEqual(image.Size{ .width = 540, .height = 960 }, analysisSize(&portrait, 540));
    const small: ffmpeg.VideoInfo = .{ .width = 641, .height = 361, .colorimetry = .{}, .time_base_numerator = 1, .time_base_denominator = 30, .frames = &.{} };
    try testing.expectEqual(image.Size{ .width = 640, .height = 360 }, analysisSize(&small, 540));
}

// endregion: tests
