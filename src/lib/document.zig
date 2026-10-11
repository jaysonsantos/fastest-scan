//! Decisions for the document as a whole: one page size for all pages.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");
const image = @import("image.zig");
const observe = @import("observe.zig");
const timeline = @import("timeline.zig");

const Point = geometry.Point;

pub const GeometryOptions = struct {
    /// Output pixels for each source pixel along the height of a page.
    scale: f32 = 1.0,
    /// The page height of the document is this percentile of the page heights in the
    /// video. A high value keeps the detail of the pages that were filmed from near.
    height_percentile: f32 = 0.75,
    /// The limits of the page height in pixels.
    min_height_px: u32 = 400,
    max_height_px: u32 = 6000,
    /// The limits of the width divided by the height of a page.
    min_aspect: f32 = 0.3,
    max_aspect: f32 = 3.0,
};

pub const PageGeometry = struct {
    /// The size of every page image of the document.
    size: image.Size,
    /// The width divided by the height of a page.
    aspect: f32,
};

/// Choose the size of the page images from the reference frames of all spreads.
///
/// All pages of a book have one size. The median over all pages is more exact than
/// the estimate from one page. `frame_scale` is the factor from the coordinates of
/// the observations to the coordinates of the full frames.
pub fn pageGeometry(
    allocator: Allocator,
    observations: []const observe.FrameObservation,
    segments: []const timeline.Segment,
    analysis_size: image.Size,
    frame_scale: f32,
    options: GeometryOptions,
) Allocator.Error!?PageGeometry {
    var aspects: std.ArrayList(f32) = .empty;
    defer aspects.deinit(allocator);
    var heights: std.ArrayList(f32) = .empty;
    defer heights.deinit(allocator);

    const principal = Point.init(
        0.5 * @as(f32, @floatFromInt(analysis_size.width)),
        0.5 * @as(f32, @floatFromInt(analysis_size.height)),
    );
    // Two rounds: pages with all edges in view first; if there are none, all pages.
    for ([_]bool{ true, false }) |complete_only| {
        for (segments) |segment| {
            const frame = &observations[segment.reference];
            for (frame.pageSlice()) |*page| {
                if (complete_only and page.clipped_edges.any()) continue;
                const side_aspect = page.quad.meanWidth() / @max(page.quad.meanHeight(), 1);
                // The perspective estimate is exact for a flat page. It fails for a view
                // from straight above, where the side lengths are exact.
                const aspect = geometry.rectangleAspect(page.quad, principal) orelse side_aspect;
                const plausible = aspect >= options.min_aspect and aspect <= options.max_aspect and
                    @abs(aspect - side_aspect) < max_aspect_disagreement * side_aspect;
                try aspects.append(allocator, if (plausible) aspect else side_aspect);
                try heights.append(allocator, page.quad.meanHeight() * frame_scale);
            }
        }
        if (aspects.items.len > 0) break;
    }
    if (aspects.items.len == 0) return null;

    const aspect = std.math.clamp(percentile(aspects.items, 0.5), options.min_aspect, options.max_aspect);
    const source_height = percentile(heights.items, options.height_percentile);
    const height_float = std.math.clamp(
        source_height * options.scale,
        @as(f32, @floatFromInt(options.min_height_px)),
        @as(f32, @floatFromInt(options.max_height_px)),
    );
    const height: u32 = @intFromFloat(@round(height_float));
    const width: u32 = @intFromFloat(@max(1, @round(height_float * aspect)));
    return .{ .size = .{ .width = width, .height = height }, .aspect = aspect };
}

/// The perspective estimate of the aspect is used only within this relative
/// distance of the ratio of the side lengths. A curved page gives a wild estimate.
const max_aspect_disagreement = 0.25;

/// The value at a fraction of the sorted values. The function sorts `values`.
fn percentile(values: []f32, fraction: f32) f32 {
    std.mem.sort(f32, values, {}, std.sort.asc(f32));
    const position = std.math.clamp(fraction, 0, 1) * @as(f32, @floatFromInt(values.len - 1));
    return values[@intFromFloat(@round(position))];
}

// region: tests

const testing = std.testing;
const detect = @import("detect.zig");

fn testFrame(width: f32, height: f32) observe.FrameObservation {
    var frame: observe.FrameObservation = .{
        .detected = true,
        .kind = .single,
        .clipped = false,
        .gutter_response = 0,
        .edge_support = 0.5,
        .pages = undefined,
    };
    for (&frame.pages) |*page| {
        page.quad = .{
            .tl = Point.init(100, 50),
            .tr = Point.init(100 + width, 50),
            .br = Point.init(100 + width, 50 + height),
            .bl = Point.init(100, 50 + height),
        };
        page.clipped_edges = .none;
        page.covered = observe.CellSet.empty;
        page.ink = @splat(200);
        page.paper_luma = 200;
    }
    return frame;
}

test "the page size is the median shape at the scale of the full frames" {
    const observations = [_]observe.FrameObservation{
        testFrame(200, 300),
        testFrame(210, 300),
        testFrame(100, 300),
    };
    var segments: [3]timeline.Segment = undefined;
    for (&segments, 0..) |*segment, index| {
        segment.* = .{ .kind = .single, .first_frame = @intCast(index), .last_frame = @intCast(index), .reference = @intCast(index), .stable_frames = 1, .score = 0, .weak = false };
    }
    const result = (try pageGeometry(testing.allocator, &observations, &segments, .{ .width = 960, .height = 540 }, 4, .{})).?;
    try testing.expectEqual(@as(u32, 1200), result.size.height);
    try testing.expectEqual(@as(u32, 800), result.size.width);
}

test "no spreads give no page size" {
    try testing.expect(try pageGeometry(testing.allocator, &.{}, &.{}, .{ .width = 960, .height = 540 }, 4, .{}) == null);
}

// endregion: tests
