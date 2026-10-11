//! Page detection on one frame: find the paper, its edges, and the fold of a
//! two-page spread.
//!
//! The detector works on a mask of paper pixels, see
//! `docs/decisions/0004-page-detection-by-paper-mask.md`. It runs at half the size of
//! the frame, which is the size of the chroma planes of a 4:2:0 frame.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");
const image = @import("image.zig");
const raster = @import("raster.zig");
const curl = @import("curl.zig");

const Point = geometry.Point;
const Line = geometry.Line;
const Quad = geometry.Quad;
const Plane = image.Plane;

// region: options and results

pub const LayoutMode = enum {
    /// Decide for each frame from the shape of the paper and the fold.
    auto,
    /// The paper is always one page.
    single,
    /// The paper is always two pages side by side.
    spread,
};

pub const Options = struct {
    layout: LayoutMode = .auto,
    /// How many codes one code of chroma distance from the scene white takes off the
    /// paper score. A larger value rejects coloured surfaces more strongly.
    chroma_weight: f32 = 1.5,
    /// The scene white is the mean chroma of the pixels above this luma percentile.
    white_percentile: f32 = 0.90,
    /// Otsu separability below which the frame has no clear paper region.
    min_separability: f32 = 0.45,
    /// The smallest paper region, as a fraction of the frame area.
    min_area_fraction: f32 = 0.04,
    /// Width divided by height above which the paper can be a spread.
    spread_min_aspect: f32 = 1.12,
    /// The fold must lie within this fraction of the paper width from the middle.
    gutter_search_fraction: f32 = 0.16,
    /// The largest slope (dx/dy) of the fold in the frame of the paper.
    gutter_max_slope: f32 = 0.10,
    /// The smallest fold response, in luma codes, for a spread in `auto` mode.
    gutter_min_response: f32 = 3.0,
    /// The distance, in pixels of the half-size image, within which an edge point
    /// supports a line.
    edge_tolerance: f32 = 1.5,
    /// Also fit a curve to the top and the bottom edge of each page, for pages that
    /// curl. The render pass turns this on; the analysis pass does not need it.
    outlines: bool = false,
    /// A curved edge can leave the straight line between its corners by this
    /// fraction of the page height.
    max_bend_fraction: f32 = 0.08,
    /// A curve needs this fraction of the edge points on it.
    min_curve_support: f32 = 0.45,
    /// A page is curled when an edge leaves the straight line between its corners
    /// by this fraction of the page height. Below it, the page is a plane: a small
    /// bend is not larger than the error of the edge points.
    min_bend_fraction: f32 = 0.006,
};

pub const LayoutKind = enum(u8) {
    single = 0,
    spread = 1,

    pub fn pageCount(self: LayoutKind) u8 {
        return switch (self) {
            .single => 1,
            .spread => 2,
        };
    }
};

pub const max_pages = 2;

/// The sides of a page that lie on the border of the frame. The real edge of the
/// paper is then out of view, and the quad ends at the border of the frame.
pub const ClippedEdges = packed struct(u8) {
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
    left: bool = false,
    _padding: u4 = 0,

    pub const none: ClippedEdges = .{};

    pub fn count(self: ClippedEdges) u8 {
        return @as(u8, @intFromBool(self.top)) + @intFromBool(self.right) + @intFromBool(self.bottom) + @intFromBool(self.left);
    }

    pub fn any(self: ClippedEdges) bool {
        return self.count() > 0;
    }
};

/// The pages of one frame. All coordinates are in luma pixels of the frame.
pub const Layout = struct {
    kind: LayoutKind,
    /// One quad for a single page. The left page then the right page for a spread.
    pages: [max_pages]Quad,
    /// For each page, the sides that end at the border of the frame.
    clipped_edges: [max_pages]ClippedEdges,
    /// For each page, the outline with curved top and bottom edges. Null when the
    /// two edges are straight, when a side of the page is out of view, or when
    /// `Options.outlines` is off. The corners of an outline are the corners of the quad.
    outlines: [max_pages]?curl.PageOutline,
    /// True when the paper touches the border of the frame at one or more pixels.
    clipped: bool,
    /// The fold response in luma codes. 0 for a single page.
    gutter_response: f32,
    /// The smallest fraction of edge points that support their line, over all edges.
    edge_support: f32,

    pub fn pageCount(self: Layout) u8 {
        return self.kind.pageCount();
    }
};

/// The half-size images of one frame. The observation step reads them after the
/// detection.
pub const Scene = struct {
    /// Luma at half the frame size.
    luma: Plane,
    /// The paper score at half the frame size: high for bright pixels with the
    /// colour of the scene white.
    score: Plane,
    /// Scores above this value are paper.
    threshold: u8,
    separability: f32,
    region: raster.Region,
    /// The factor from half-size coordinates to luma coordinates of the frame.
    scale: f32,

    pub fn deinit(self: Scene, allocator: Allocator) void {
        self.luma.deinit(allocator);
        self.score.deinit(allocator);
        self.region.deinit(allocator);
    }

    /// A point of the half-size image in luma coordinates of the frame. Pixel
    /// centers are at integer coordinates in the two systems.
    pub fn toFrame(self: Scene, p: Point) Point {
        return .{ .x = p.x * self.scale + half_pixel_shift, .y = p.y * self.scale + half_pixel_shift };
    }

    pub fn fromFrame(self: Scene, p: Point) Point {
        return .{ .x = (p.x - half_pixel_shift) / self.scale, .y = (p.y - half_pixel_shift) / self.scale };
    }

    pub fn quadFromFrame(self: Scene, quad: Quad) Quad {
        return .{
            .tl = self.fromFrame(quad.tl),
            .tr = self.fromFrame(quad.tr),
            .br = self.fromFrame(quad.br),
            .bl = self.fromFrame(quad.bl),
        };
    }

    const half_scale = 2.0;
    /// The center of half-size pixel 0 lies between luma pixels 0 and 1.
    const half_pixel_shift = 0.5;
};

// endregion: options and results

// region: paper mask

/// Build the half-size images and the paper region of a frame. Returns null when the
/// frame shows no clear paper region.
pub fn analyzeScene(allocator: Allocator, frame: image.FrameView, options: Options) Allocator.Error!?Scene {
    const luma = try raster.halve(allocator, frame.y);
    errdefer luma.deinit(allocator);
    const width = @min(luma.width, @min(frame.u.width, frame.v.width));
    const height = @min(luma.height, @min(frame.u.height, frame.v.height));
    if (width < min_scene_side or height < min_scene_side) {
        luma.deinit(allocator);
        return null;
    }

    // The scene white: the mean chroma of the brightest pixels.
    const luma_histogram = raster.histogram(luma.view());
    const white_luma = raster.percentile(&luma_histogram, options.white_percentile);
    var sum_u: u64 = 0;
    var sum_v: u64 = 0;
    var white_count: u64 = 0;
    for (0..height) |y| {
        const luma_row = luma.row(y);
        const u_row = frame.u.row(y);
        const v_row = frame.v.row(y);
        for (0..width) |x| {
            if (luma_row[x] < white_luma) continue;
            sum_u += u_row[x];
            sum_v += v_row[x];
            white_count += 1;
        }
    }
    const neutral_chroma = 128.0;
    const white_u: f32 = if (white_count > 0) @as(f32, @floatFromInt(sum_u)) / @as(f32, @floatFromInt(white_count)) else neutral_chroma;
    const white_v: f32 = if (white_count > 0) @as(f32, @floatFromInt(sum_v)) / @as(f32, @floatFromInt(white_count)) else neutral_chroma;

    const score = try Plane.init(allocator, luma.width, luma.height);
    errdefer score.deinit(allocator);
    @memset(score.data, 0);
    for (0..height) |y| {
        const luma_row = luma.row(y);
        const u_row = frame.u.row(y);
        const v_row = frame.v.row(y);
        const score_row = score.row(y);
        for (0..width) |x| {
            const chroma_distance = @abs(@as(f32, @floatFromInt(u_row[x])) - white_u) + @abs(@as(f32, @floatFromInt(v_row[x])) - white_v);
            const value = @as(f32, @floatFromInt(luma_row[x])) - options.chroma_weight * chroma_distance;
            score_row[x] = @intFromFloat(std.math.clamp(value, 0, 255));
        }
    }

    const score_histogram = raster.histogram(score.view());
    const split = raster.otsu(&score_histogram);
    if (split.separability < options.min_separability) {
        luma.deinit(allocator);
        score.deinit(allocator);
        return null;
    }

    const mask = try Plane.init(allocator, score.width, score.height);
    defer mask.deinit(allocator);
    for (mask.data, score.data) |*bit, value| bit.* = if (value > split.threshold) raster.mask_set else 0;
    // An opening removes specks and thin bridges between the paper and other bright things.
    const eroded = try raster.erode3(allocator, mask);
    defer eroded.deinit(allocator);
    const opened = try raster.dilate3(allocator, eroded);
    defer opened.deinit(allocator);

    const region = (try raster.largestRegion(allocator, opened)) orelse {
        luma.deinit(allocator);
        score.deinit(allocator);
        return null;
    };
    const frame_area: f32 = @floatFromInt(@as(usize, score.width) * score.height);
    if (@as(f32, @floatFromInt(region.area)) < options.min_area_fraction * frame_area) {
        region.deinit(allocator);
        luma.deinit(allocator);
        score.deinit(allocator);
        return null;
    }

    return .{
        .luma = luma,
        .score = score,
        .threshold = split.threshold,
        .separability = split.separability,
        .region = region,
        .scale = Scene.half_scale,
    };
}

const min_scene_side = 32;

// endregion: paper mask

// region: paper frame

/// A coordinate system that is turned with the paper: `x` runs along the top edge,
/// `y` runs down the side.
const PaperFrame = struct {
    origin: Point,
    axis_x: Point,
    axis_y: Point,

    fn toLocal(self: PaperFrame, p: Point) Point {
        const relative = p.sub(self.origin);
        return .{ .x = relative.dot(self.axis_x), .y = relative.dot(self.axis_y) };
    }

    fn toImage(self: PaperFrame, p: Point) Point {
        return self.origin.add(self.axis_x.scale(p.x)).add(self.axis_y.scale(p.y));
    }
};

/// The points of the region that have a neighbour outside the region.
fn boundaryPoints(allocator: Allocator, region: raster.Region) Allocator.Error![]Point {
    const mask = region.mask;
    var count: usize = 0;
    var pass: u8 = 0;
    var points: []Point = &.{};
    // Two passes: count, then fill.
    while (pass < 2) : (pass += 1) {
        if (pass == 1) points = try allocator.alloc(Point, count);
        var next: usize = 0;
        for (region.min_y..region.max_y + 1) |y| {
            for (region.min_x..region.max_x + 1) |x| {
                if (mask.at(x, y) == 0) continue;
                const on_border = x == 0 or y == 0 or x == mask.width - 1 or y == mask.height - 1;
                const is_boundary = on_border or
                    mask.at(x - 1, y) == 0 or mask.at(x + 1, y) == 0 or
                    mask.at(x, y - 1) == 0 or mask.at(x, y + 1) == 0;
                if (!is_boundary) continue;
                if (pass == 1) points[next] = Point.init(@floatFromInt(x), @floatFromInt(y));
                next += 1;
            }
        }
        count = next;
    }
    return points;
}

/// The convex hull, clockwise on the screen, with the monotone chain algorithm.
/// The function sorts `points` in place.
/// Source: A. M. Andrew, "Another efficient algorithm for convex hulls in two
/// dimensions", Information Processing Letters 9(5), 1979.
fn convexHull(allocator: Allocator, points: []Point) Allocator.Error![]Point {
    std.mem.sort(Point, points, {}, struct {
        fn lessThan(_: void, a: Point, b: Point) bool {
            return a.x < b.x or (a.x == b.x and a.y < b.y);
        }
    }.lessThan);
    const hull = try allocator.alloc(Point, 2 * points.len + 1);
    errdefer allocator.free(hull);
    var size: usize = 0;
    for (points) |p| {
        while (size >= 2 and hull[size - 1].sub(hull[size - 2]).cross(p.sub(hull[size - 1])) <= 0) size -= 1;
        hull[size] = p;
        size += 1;
    }
    const lower_size = size + 1;
    var index = points.len;
    while (index > 0) {
        index -= 1;
        const p = points[index];
        while (size >= lower_size and hull[size - 1].sub(hull[size - 2]).cross(p.sub(hull[size - 1])) <= 0) size -= 1;
        hull[size] = p;
        size += 1;
    }
    // The last point repeats the first.
    if (size > 1) size -= 1;
    return allocator.realloc(hull, size);
}

/// The frame of the rectangle with the smallest area around the hull. Its x axis is
/// the side of the rectangle that is closest to the x axis of the image.
///
/// One side of that rectangle lies on an edge of the hull, so the function tries
/// each hull edge. Source of the theorem: H. Freeman and R. Shapira, "Determining
/// the minimum-area encasing rectangle for an arbitrary closed curve",
/// Communications of the ACM 18(7), 1975.
fn paperFrame(hull: []const Point) PaperFrame {
    var best_area = std.math.inf(f32);
    var best_axis = Point.init(1, 0);
    for (hull, 0..) |a, i| {
        const b = hull[(i + 1) % hull.len];
        const edge = b.sub(a);
        if (edge.length() < min_hull_edge) continue;
        const axis = edge.normalized();
        const normal = axis.perpendicular();
        var min_u = std.math.inf(f32);
        var max_u = -std.math.inf(f32);
        var min_v = std.math.inf(f32);
        var max_v = -std.math.inf(f32);
        for (hull) |p| {
            const u = p.dot(axis);
            const v = p.dot(normal);
            min_u = @min(min_u, u);
            max_u = @max(max_u, u);
            min_v = @min(min_v, v);
            max_v = @max(max_v, v);
        }
        const area = (max_u - min_u) * (max_v - min_v);
        if (area < best_area) {
            best_area = area;
            best_axis = axis;
        }
    }
    // Of the two directions of the rectangle, take the one nearest to the image x axis.
    var axis_x = best_axis;
    if (@abs(axis_x.x) < @abs(axis_x.y)) axis_x = axis_x.perpendicular();
    if (axis_x.x < 0) axis_x = axis_x.scale(-1);
    const axis_y = axis_x.perpendicular();

    var center = Point.zero;
    for (hull) |p| center = center.add(p);
    center = center.scale(1.0 / @as(f32, @floatFromInt(hull.len)));
    return .{ .origin = center, .axis_x = axis_x, .axis_y = axis_y };
}

const min_hull_edge = 1e-3;

// endregion: paper frame

// region: edge fit

const EdgeFit = struct {
    line: Line,
    /// The fraction of the points within the tolerance of the line.
    support: f32,
};

/// Fit a line to the points of one paper edge. `outward` points away from the paper.
///
/// Things that cover the edge (fingers) move points to the inside of the paper,
/// never to the outside. So a good line has many points on it and no points beyond
/// it. The function tries lines through pairs of points and keeps the best one.
///
/// This is the hypothesise-and-verify scheme of RANSAC with fixed pairs in place
/// of random ones and a one-sided penalty. Source of RANSAC: M. A. Fischler and
/// R. C. Bolles, "Random sample consensus: a paradigm for model fitting with
/// applications to image analysis and automated cartography", Communications of
/// the ACM 24(6), 1981.
fn fitEdge(points: []const Point, outward: Point, tolerance: f32) ?EdgeFit {
    if (points.len < min_edge_points) return null;
    const sample_count = @min(points.len, edge_samples);
    var best_score = -std.math.inf(f32);
    var best_line: ?Line = null;

    for (0..sample_count) |i| {
        const a = points[i * (points.len - 1) / (sample_count - 1)];
        // A short pair gives an unstable direction.
        var j = i + sample_count / min_pair_gap_divisor;
        while (j < sample_count) : (j += 1) {
            const b = points[j * (points.len - 1) / (sample_count - 1)];
            if (a.distance(b) < min_pair_distance) continue;
            const line = orient(Line.through(a, b), outward);
            const score = scoreEdge(points, line, tolerance);
            if (score.value > best_score) {
                best_score = score.value;
                best_line = line;
            }
        }
    }
    var line = best_line orelse return null;

    // Least squares on the supporting points, two times.
    var scratch: [max_refine_points]Point = undefined;
    for (0..refine_rounds) |_| {
        var count: usize = 0;
        const stride = @max(1, points.len / max_refine_points + 1);
        var index: usize = 0;
        while (index < points.len) : (index += stride) {
            const p = points[index];
            if (@abs(line.signedDistance(p)) <= tolerance and count < max_refine_points) {
                scratch[count] = p;
                count += 1;
            }
        }
        if (count < min_edge_points) break;
        const refined = geometry.fitLine(scratch[0..count], null) orelse break;
        line = orient(refined, outward);
    }
    const final = scoreEdge(points, line, tolerance);
    return .{ .line = line, .support = final.inlier_fraction };
}

const EdgeScore = struct {
    value: f32,
    inlier_fraction: f32,
};

fn scoreEdge(points: []const Point, line: Line, tolerance: f32) EdgeScore {
    var inliers: f32 = 0;
    var beyond: f32 = 0;
    for (points) |p| {
        const distance = line.signedDistance(p);
        if (@abs(distance) <= tolerance) {
            inliers += 1;
        } else if (distance > tolerance) {
            beyond += 1;
        }
    }
    return .{
        .value = inliers - beyond_penalty * beyond,
        .inlier_fraction = inliers / @as(f32, @floatFromInt(points.len)),
    };
}

/// Turn the normal of the line to the side of `outward`.
fn orient(line: Line, outward: Point) Line {
    if (line.normal().dot(outward) >= 0) return line;
    return .{ .a = -line.a, .b = -line.b, .c = -line.c };
}

const min_edge_points = 6;
const edge_samples = 28;
/// A pair of sample points is at least `edge_samples / 4` samples apart.
const min_pair_gap_divisor = 4;
const min_pair_distance = 4.0;
/// A paper point beyond the line counts this much against the line.
const beyond_penalty = 3.0;
const refine_rounds = 2;
const max_refine_points = 512;

// endregion: edge fit

// region: side profiles

/// The outermost paper point for each column and each row of the paper frame.
const Profiles = struct {
    min: Point,
    max: Point,
    /// For each column: the smallest and the largest local y. NaN for an empty column.
    top: []f32,
    bottom: []f32,
    /// For each row: the smallest and the largest local x.
    left: []f32,
    right: []f32,

    fn init(allocator: Allocator, frame: PaperFrame, boundary: []const Point) Allocator.Error!Profiles {
        var min = Point.init(std.math.inf(f32), std.math.inf(f32));
        var max = Point.init(-std.math.inf(f32), -std.math.inf(f32));
        for (boundary) |p| {
            const local = frame.toLocal(p);
            min.x = @min(min.x, local.x);
            min.y = @min(min.y, local.y);
            max.x = @max(max.x, local.x);
            max.y = @max(max.y, local.y);
        }
        const columns: usize = @intFromFloat(@ceil(max.x - min.x) + 1);
        const rows: usize = @intFromFloat(@ceil(max.y - min.y) + 1);
        const top = try allocator.alloc(f32, columns);
        errdefer allocator.free(top);
        const bottom = try allocator.alloc(f32, columns);
        errdefer allocator.free(bottom);
        const left = try allocator.alloc(f32, rows);
        errdefer allocator.free(left);
        const right = try allocator.alloc(f32, rows);
        @memset(top, std.math.nan(f32));
        @memset(bottom, std.math.nan(f32));
        @memset(left, std.math.nan(f32));
        @memset(right, std.math.nan(f32));
        for (boundary) |p| {
            const local = frame.toLocal(p);
            const column: usize = @intFromFloat(@round(local.x - min.x));
            const row: usize = @intFromFloat(@round(local.y - min.y));
            if (!(top[column] <= local.y)) top[column] = local.y;
            if (!(bottom[column] >= local.y)) bottom[column] = local.y;
            if (!(left[row] <= local.x)) left[row] = local.x;
            if (!(right[row] >= local.x)) right[row] = local.x;
        }
        return .{ .min = min, .max = max, .top = top, .bottom = bottom, .left = left, .right = right };
    }

    fn deinit(self: Profiles, allocator: Allocator) void {
        allocator.free(self.top);
        allocator.free(self.bottom);
        allocator.free(self.left);
        allocator.free(self.right);
    }

    fn width(self: Profiles) f32 {
        return self.max.x - self.min.x;
    }

    fn height(self: Profiles) f32 {
        return self.max.y - self.min.y;
    }

    const Side = enum { top, bottom, left, right };

    /// The profile points of one side between two local coordinates along the side.
    /// The points are in local coordinates. Returns the number of points written.
    fn collect(self: Profiles, side: Side, from: f32, to: f32, out: []Point) usize {
        const values = switch (side) {
            .top => self.top,
            .bottom => self.bottom,
            .left => self.left,
            .right => self.right,
        };
        const along_min = switch (side) {
            .top, .bottom => self.min.x,
            .left, .right => self.min.y,
        };
        var count: usize = 0;
        for (values, 0..) |value, index| {
            if (std.math.isNan(value)) continue;
            const along = along_min + @as(f32, @floatFromInt(index));
            if (along < from or along > to) continue;
            if (count >= out.len) break;
            out[count] = switch (side) {
                .top, .bottom => Point.init(along, value),
                .left, .right => Point.init(value, along),
            };
            count += 1;
        }
        return count;
    }
};

// endregion: side profiles

// region: gutter

const Gutter = struct {
    /// The fold in local coordinates of the paper frame.
    line: Line,
    /// The local x of the fold at the middle height.
    center_x: f32,
    response: f32,
};

/// Find the fold of a spread: the line near the middle of the paper, almost along
/// the local y axis, where the brightness has a valley or a step on most of its length.
///
/// The page-split filter of ScanTailor (J. Artsimovich) also looks for a near-vertical
/// line near the middle of a spread. This function shares that idea only; the
/// response and the search are different, and no ScanTailor code is used.
fn findGutter(
    allocator: Allocator,
    scene: *const Scene,
    frame: PaperFrame,
    profiles: Profiles,
    options: Options,
) Allocator.Error!?Gutter {
    const paper_width = profiles.width();
    const paper_height = profiles.height();
    const center_x = 0.5 * (profiles.min.x + profiles.max.x);
    const center_y = 0.5 * (profiles.min.y + profiles.max.y);

    // The response compares the luma at this distance on each side of a position.
    const probe: usize = @intFromFloat(@max(min_gutter_probe, @round(gutter_probe_fraction * paper_width)));
    const probe_float: f32 = @floatFromInt(probe);
    const search = options.gutter_search_fraction * paper_width;
    const slope_reach = options.gutter_max_slope * paper_height * 0.5;
    const first_y = profiles.min.y + gutter_row_margin * paper_height;
    const last_y = profiles.max.y - gutter_row_margin * paper_height;
    const first_x = center_x - search - slope_reach - probe_float;
    const last_x = center_x + search + slope_reach + probe_float;

    const rows: usize = @intFromFloat(@max(0, @floor(last_y - first_y)) + 1);
    const columns: usize = @intFromFloat(@max(0, @floor(last_x - first_x)) + 1);
    if (rows < min_gutter_rows or columns < 2 * probe + 3) return null;

    // The luma of the search band, in the frame of the paper.
    const band = try allocator.alloc(f32, rows * columns);
    defer allocator.free(band);
    const luma = scene.luma.view();
    for (0..rows) |row| {
        const local_y = first_y + @as(f32, @floatFromInt(row));
        for (0..columns) |column| {
            const local_x = first_x + @as(f32, @floatFromInt(column));
            const p = frame.toImage(Point.init(local_x, local_y));
            band[row * columns + column] = luma.sample(p.x, p.y);
        }
    }

    // The response at each band position: a dark line between brighter sides, or a
    // step of brightness. Text gives a response in places; the fold gives it
    // everywhere. The response is stored in steps of 1 / `response_steps_per_code`.
    // The store is column after column: a candidate line is almost along a column,
    // so the search below reads memory in order.
    const response = try allocator.alloc(u8, rows * columns);
    defer allocator.free(response);
    @memset(response, 0);
    for (0..rows) |row| {
        const band_row = band[row * columns ..][0..columns];
        for (probe..columns - probe) |column| {
            const before = band_row[column - probe];
            const after = band_row[column + probe];
            const here = @min(band_row[column], @min(band_row[column - 1], band_row[column + 1]));
            const valley = 0.5 * (before + after) - here;
            const step = @abs(after - before);
            const value = @min(@max(valley, 0) + gutter_step_weight * step, gutter_response_cap);
            response[column * rows + row] = @intFromFloat(value * response_steps_per_code);
        }
    }

    var best: ?Gutter = null;
    var best_weighted: f32 = 0;
    const middle_row = 0.5 * @as(f32, @floatFromInt(rows - 1));
    // One slope step moves the ends of the line by one pixel.
    const slope_steps: i32 = @intFromFloat(@max(1, @ceil(slope_reach)));
    const percentile_rank: u32 = @intFromFloat(gutter_percentile * @as(f32, @floatFromInt(rows - 1)));
    var slope_index: i32 = -slope_steps;
    while (slope_index <= slope_steps) : (slope_index += 1) {
        const slope = options.gutter_max_slope * @as(f32, @floatFromInt(slope_index)) / @as(f32, @floatFromInt(slope_steps));
        var x_at_middle = center_x - search;
        while (x_at_middle <= center_x + search) : (x_at_middle += gutter_position_step) {
            var bins: raster.Histogram = @splat(0);
            for (0..rows) |row| {
                const x = x_at_middle + slope * (@as(f32, @floatFromInt(row)) - middle_row);
                const column_float = std.math.clamp(x - first_x, 0, @as(f32, @floatFromInt(columns - 1)));
                const column: usize = @intFromFloat(@round(column_float));
                bins[response[column * rows + row]] += 1;
            }
            // A low percentile: most of the length of the line must respond.
            var cumulative: u32 = 0;
            var code: usize = 0;
            while (code < raster.histogram_bins - 1) : (code += 1) {
                cumulative += bins[code];
                if (cumulative > percentile_rank) break;
            }
            const value = @as(f32, @floatFromInt(code)) / response_steps_per_code;
            const off_center = @abs(x_at_middle - center_x) / search;
            const weighted = value * (1.0 - gutter_center_bias * off_center);
            if (weighted > best_weighted) {
                best_weighted = weighted;
                const top_point = Point.init(x_at_middle + slope * (first_y - center_y), first_y);
                const bottom_point = Point.init(x_at_middle + slope * (last_y - center_y), last_y);
                best = .{
                    .line = Line.through(top_point, bottom_point),
                    .center_x = x_at_middle,
                    .response = value,
                };
            }
        }
    }
    return best;
}

/// The search ignores this fraction of the paper height at the top and at the bottom.
const gutter_row_margin = 0.06;
const min_gutter_rows = 16;
/// The probe distance of the fold response, as a fraction of the paper width.
const gutter_probe_fraction = 0.01;
const min_gutter_probe = 2.0;
const gutter_step_weight = 0.5;
/// The largest response, in luma codes. With `response_steps_per_code` it fits a byte.
const gutter_response_cap = 60.0;
const response_steps_per_code = 4.0;
const gutter_position_step = 1.0;
const gutter_percentile = 0.30;
/// How much a fold at the limit of the search range loses against one in the middle.
const gutter_center_bias = 0.35;

// endregion: gutter

// region: layout

/// The edges ignore this fraction of the side length next to each corner, where the
/// profile of one side runs into the next side.
const corner_margin = 0.07;
/// The top and bottom edges of a page stay this fraction of the paper width away
/// from the fold, where the paper curves.
const gutter_margin = 0.04;
const max_profile_points = 1024;
const min_page_side = 12.0;
const min_page_aspect = 0.25;
const max_page_aspect = 4.0;

/// Find the pages of the scene. Returns null when the paper has no four clear edges.
pub fn detectLayout(allocator: Allocator, scene: *const Scene, options: Options) Allocator.Error!?Layout {
    const boundary = try boundaryPoints(allocator, scene.region);
    defer allocator.free(boundary);
    if (boundary.len < 4 * min_edge_points) return null;

    const hull_input = try allocator.dupe(Point, boundary);
    defer allocator.free(hull_input);
    const hull = try convexHull(allocator, hull_input);
    defer allocator.free(hull);
    if (hull.len < 3) return null;

    const frame = paperFrame(hull);
    const profiles = try Profiles.init(allocator, frame, boundary);
    defer profiles.deinit(allocator);
    const paper_width = profiles.width();
    const paper_height = profiles.height();
    if (paper_width < min_page_side or paper_height < min_page_side) return null;

    var scratch: [max_profile_points]Point = undefined;
    const tolerance = options.edge_tolerance;
    const left_axis = Point.init(-1, 0);
    const right_axis = Point.init(1, 0);
    const up_axis = Point.init(0, -1);
    const down_axis = Point.init(0, 1);

    const side_from = profiles.min.y + corner_margin * paper_height;
    const side_to = profiles.max.y - corner_margin * paper_height;
    const left = fitEdge(scratch[0..profiles.collect(.left, side_from, side_to, &scratch)], left_axis, tolerance) orelse return null;
    const right = fitEdge(scratch[0..profiles.collect(.right, side_from, side_to, &scratch)], right_axis, tolerance) orelse return null;

    const aspect = paper_width / paper_height;
    var gutter: ?Gutter = null;
    const try_spread = switch (options.layout) {
        .auto => aspect >= options.spread_min_aspect,
        .single => false,
        .spread => true,
    };
    if (try_spread) {
        gutter = try findGutter(allocator, scene, frame, profiles, options);
        if (gutter) |found| {
            if (options.layout == .auto and found.response < options.gutter_min_response) gutter = null;
        }
        if (gutter == null and options.layout == .spread) {
            // The caller says it is a spread: split at the middle.
            const middle = 0.5 * (profiles.min.x + profiles.max.x);
            gutter = .{
                .line = Line.through(Point.init(middle, profiles.min.y), Point.init(middle, profiles.max.y)),
                .center_x = middle,
                .response = 0,
            };
        }
    }

    // The outlines in the frame of the paper, before the conversion below.
    var local_outlines: [max_pages]?curl.PageOutline = @splat(null);
    var layout: Layout = .{
        .kind = .single,
        .pages = undefined,
        .clipped_edges = @splat(ClippedEdges.none),
        .outlines = @splat(null),
        .clipped = scene.region.touches_border,
        .gutter_response = 0,
        .edge_support = @min(left.support, right.support),
    };

    if (gutter) |fold| {
        const near_fold = gutter_margin * paper_width;
        const outer_margin = corner_margin * paper_width;
        const top_left = fitEdge(
            scratch[0..profiles.collect(.top, profiles.min.x + outer_margin, fold.center_x - near_fold, &scratch)],
            up_axis,
            tolerance,
        ) orelse return null;
        const bottom_left = fitEdge(
            scratch[0..profiles.collect(.bottom, profiles.min.x + outer_margin, fold.center_x - near_fold, &scratch)],
            down_axis,
            tolerance,
        ) orelse return null;
        const top_right = fitEdge(
            scratch[0..profiles.collect(.top, fold.center_x + near_fold, profiles.max.x - outer_margin, &scratch)],
            up_axis,
            tolerance,
        ) orelse return null;
        const bottom_right = fitEdge(
            scratch[0..profiles.collect(.bottom, fold.center_x + near_fold, profiles.max.x - outer_margin, &scratch)],
            down_axis,
            tolerance,
        ) orelse return null;

        const left_page = quadFromLines(left.line, top_left.line, fold.line, bottom_left.line) orelse return null;
        const right_page = quadFromLines(fold.line, top_right.line, right.line, bottom_right.line) orelse return null;
        layout.kind = .spread;
        layout.pages = .{ left_page, right_page };
        if (options.outlines) {
            local_outlines[0] = pageOutline(&profiles, left.line, fold.line, top_left.line, left_page, options, &scratch);
            local_outlines[1] = pageOutline(&profiles, fold.line, right.line, top_right.line, right_page, options, &scratch);
        }
        layout.gutter_response = fold.response;
        layout.edge_support = @min(layout.edge_support, @min(@min(top_left.support, bottom_left.support), @min(top_right.support, bottom_right.support)));
    } else {
        const margin = corner_margin * paper_width;
        const top = fitEdge(
            scratch[0..profiles.collect(.top, profiles.min.x + margin, profiles.max.x - margin, &scratch)],
            up_axis,
            tolerance,
        ) orelse return null;
        const bottom = fitEdge(
            scratch[0..profiles.collect(.bottom, profiles.min.x + margin, profiles.max.x - margin, &scratch)],
            down_axis,
            tolerance,
        ) orelse return null;
        const page = quadFromLines(left.line, top.line, right.line, bottom.line) orelse return null;
        layout.pages = .{ page, page };
        if (options.outlines) {
            local_outlines[0] = pageOutline(&profiles, left.line, right.line, top.line, page, options, &scratch);
        }
        layout.edge_support = @min(layout.edge_support, @min(top.support, bottom.support));
    }

    // From the frame of the paper to luma coordinates of the video frame.
    for (layout.pages[0..layout.pageCount()], 0..) |*page, index| {
        if (!plausiblePage(page.*)) return null;
        const in_image: Quad = .{
            .tl = frame.toImage(page.tl),
            .tr = frame.toImage(page.tr),
            .br = frame.toImage(page.br),
            .bl = frame.toImage(page.bl),
        };
        layout.clipped_edges[index] = clippedEdges(in_image, scene.luma.width, scene.luma.height);
        page.* = .{
            .tl = scene.toFrame(in_image.tl),
            .tr = scene.toFrame(in_image.tr),
            .br = scene.toFrame(in_image.br),
            .bl = scene.toFrame(in_image.bl),
        };
        // A page with a side out of view has no outline: the quad is a guess there.
        if (local_outlines[index]) |local| {
            if (!layout.clipped_edges[index].any()) {
                var outline: curl.PageOutline = undefined;
                for (&outline.top, local.top) |*target, source| target.* = scene.toFrame(frame.toImage(source));
                for (&outline.bottom, local.bottom) |*target, source| target.* = scene.toFrame(frame.toImage(source));
                layout.outlines[index] = outline;
            }
        }
    }
    if (layout.kind == .single) {
        layout.pages[1] = layout.pages[0];
        layout.clipped_edges[1] = layout.clipped_edges[0];
        layout.outlines[1] = layout.outlines[0];
    }
    return layout;
}

// region: curved edges

/// A cubic through the points of one page edge, in the frame of the paper:
/// `y = c0 + c1·t + c2·t² + c3·t³` with `t = (x − center) / half_span`.
const EdgeCurve = struct {
    coefficients: [curve_terms]f64,
    center: f32,
    half_span: f32,

    fn at(self: EdgeCurve, x: f32) f32 {
        const t: f64 = (x - self.center) / self.half_span;
        var sum: f64 = 0;
        var power: f64 = 1;
        for (self.coefficients) |coefficient| {
            sum += coefficient * power;
            power *= t;
        }
        return @floatCast(sum);
    }

    /// The curve that is the straight line.
    fn fromLine(line: Line, from: f32, to: f32) EdgeCurve {
        const center = 0.5 * (from + to);
        const half_span = @max(0.5 * (to - from), 1);
        // y = -(a x + c) / b, with x = center + t * half_span.
        const slope: f64 = -line.a / line.b;
        const offset: f64 = -(line.a * center + line.c) / line.b;
        return .{ .coefficients = .{ offset, slope * half_span, 0, 0 }, .center = center, .half_span = half_span };
    }
};

const curve_terms = 4;
const curve_fit_rounds = 3;
/// A point supports the curve within this many edge tolerances.
const curve_tolerance_factor = 1.5;
/// The curve fit leaves this fraction of the page width out at each end, where the
/// profile of the edge runs into the next edge.
const curve_end_margin = 0.03;
/// A line that is this close to the direction of the profile axis has no single
/// crossing with a curve.
const min_line_slope = 0.3;

/// Fit a cubic to the profile points of one edge. The start is the straight line of
/// that edge: points far from it (a finger) never enter the fit. Returns null when
/// too few points support the curve, or when the curve leaves the line too far.
fn fitEdgeCurve(points: []const Point, line: Line, from: f32, to: f32, max_bend: f32, tolerance: f32, min_support: f32) ?EdgeCurve {
    if (points.len < 2 * curve_terms or !(to - from > 4) or @abs(line.b) < min_line_slope) return null;
    var curve = EdgeCurve.fromLine(line, from, to);
    var limit = max_bend;
    var supporters: usize = 0;
    for (0..curve_fit_rounds + 1) |round| {
        var normal: [curve_terms][curve_terms]f64 = @splat(@splat(0));
        var right: [curve_terms]f64 = @splat(0);
        supporters = 0;
        for (points) |p| {
            if (@abs(p.y - curve.at(p.x)) > limit) continue;
            supporters += 1;
            const t: f64 = (p.x - curve.center) / curve.half_span;
            var basis: [curve_terms]f64 = undefined;
            var power: f64 = 1;
            for (&basis) |*value| {
                value.* = power;
                power *= t;
            }
            for (0..curve_terms) |row| {
                for (0..curve_terms) |column| normal[row][column] += basis[row] * basis[column];
                right[row] += basis[row] * p.y;
            }
        }
        if (round == curve_fit_rounds) break;
        if (supporters < 2 * curve_terms) return null;
        curve.coefficients = geometry.solveLinear(curve_terms, &normal, &right) orelse return null;
        limit = curve_tolerance_factor * tolerance;
    }
    if (@as(f32, @floatFromInt(supporters)) < min_support * @as(f32, @floatFromInt(points.len))) return null;

    // The curve must stay near the straight line, also at the two ends.
    const steps = 16;
    for (0..steps + 1) |step| {
        const x = from + (to - from) * @as(f32, @floatFromInt(step)) / steps;
        const on_line = -(line.a * x + line.c) / line.b;
        if (@abs(curve.at(x) - on_line) > 1.5 * max_bend) return null;
    }
    return curve;
}

/// The x of the point where a side line (left edge, right edge, or fold) cuts a curve.
fn crossCurve(side: Line, curve: EdgeCurve, start: Point) f32 {
    if (@abs(side.a) < min_line_slope) return start.x;
    var x = start.x;
    for (0..6) |_| {
        const y = curve.at(x);
        x = -(side.b * y + side.c) / side.a;
    }
    return x;
}

/// The outline of one page with curved top and bottom edges, in the frame of the
/// paper. Returns null when the page is flat: the quad then says all there is.
///
/// The top edge gets its own curve. A hand often holds the bottom edge, so the
/// bottom edge gets no curve of its own. The two edges of a curled page are the
/// same curve in space, moved along the columns of the page. So the bottom edge is
/// a straight line plus the bend of the top edge, and the free bottom points only
/// have to fix that line.
fn pageOutline(
    profiles: *const Profiles,
    left: Line,
    right: Line,
    top: Line,
    quad: Quad,
    options: Options,
    scratch: *[max_profile_points]Point,
) ?curl.PageOutline {
    const page_width = quad.meanWidth();
    const page_height = quad.meanHeight();
    const max_bend = options.max_bend_fraction * page_height;
    const margin = curve_end_margin * page_width;

    const top_points = scratch[0..profiles.collect(.top, quad.tl.x + margin, quad.tr.x - margin, scratch)];
    const top_curve = fitEdgeCurve(top_points, top, quad.tl.x, quad.tr.x, max_bend, options.edge_tolerance, options.min_curve_support) orelse return null;
    const top_left_x = crossCurve(left, top_curve, quad.tl);
    const top_right_x = crossCurve(right, top_curve, quad.tr);
    if (!(top_right_x - top_left_x > min_page_side)) return null;

    // The bend of the top edge: its distance from the line between its two ends, at
    // a fraction `u` of the way along the edge.
    const Bend = struct {
        curve: EdgeCurve,
        from_x: f32,
        to_x: f32,

        fn at(self: @This(), u: f32) f32 {
            const clamped = std.math.clamp(u, 0, 1);
            const x = self.from_x + (self.to_x - self.from_x) * clamped;
            const chord = self.curve.at(self.from_x) * (1 - clamped) + self.curve.at(self.to_x) * clamped;
            return self.curve.at(x) - chord;
        }
    };
    const bend: Bend = .{ .curve = top_curve, .from_x = top_left_x, .to_x = top_right_x };

    // The bottom points with the bend taken away lie on a straight line. The fit of
    // that line ignores the points that a finger moved to the inside.
    const bottom_points = scratch[0..profiles.collect(.bottom, quad.bl.x + margin, quad.br.x - margin, scratch)];
    const bottom_span = @max(quad.br.x - quad.bl.x, 1);
    for (bottom_points) |*p| p.y -= bend.at((p.x - quad.bl.x) / bottom_span);
    const bottom = (fitEdge(bottom_points, Point.init(0, 1), options.edge_tolerance) orelse return null).line;
    const bottom_left = left.intersect(bottom) orelse return null;
    const bottom_right = right.intersect(bottom) orelse return null;
    if (!(bottom_right.x - bottom_left.x > min_page_side)) return null;

    var outline: curl.PageOutline = undefined;
    for (0..curl.stations) |index| {
        const t = @as(f32, @floatFromInt(index)) / (curl.stations - 1);
        const top_x = top_left_x + (top_right_x - top_left_x) * t;
        outline.top[index] = Point.init(top_x, top_curve.at(top_x));
        const on_line = bottom_left.lerp(bottom_right, t);
        outline.bottom[index] = Point.init(on_line.x, on_line.y + bend.at(t));
    }
    if (outline.maxBend() < @max(options.edge_tolerance, options.min_bend_fraction * page_height)) return null;
    return outline;
}

// endregion: curved edges

/// The sides of a quad that lie on the border of an image of the given size. The
/// quad is in pixels of that image.
fn clippedEdges(quad: Quad, width: u32, height: u32) ClippedEdges {
    const max_x = @as(f32, @floatFromInt(width)) - 1 - border_tolerance;
    const max_y = @as(f32, @floatFromInt(height)) - 1 - border_tolerance;
    const OnBorder = struct {
        fn both(a: Point, b: Point, limit_x: f32, limit_y: f32) bool {
            return (a.x <= border_tolerance and b.x <= border_tolerance) or
                (a.y <= border_tolerance and b.y <= border_tolerance) or
                (a.x >= limit_x and b.x >= limit_x) or
                (a.y >= limit_y and b.y >= limit_y);
        }
    };
    return .{
        .top = OnBorder.both(quad.tl, quad.tr, max_x, max_y),
        .right = OnBorder.both(quad.tr, quad.br, max_x, max_y),
        .bottom = OnBorder.both(quad.br, quad.bl, max_x, max_y),
        .left = OnBorder.both(quad.bl, quad.tl, max_x, max_y),
    };
}

/// Move a side of a quad that ends at the frame border to where the edge of the
/// paper must be, for a page with the given width divided by height.
///
/// The camera sees three edges of the page; the fourth is out of view. The two side
/// lines are still correct, so the hidden corners lie on them, at the page height
/// from the visible corners. The result ignores perspective and is a start value
/// for the registration with other frames.
pub fn completeQuad(quad: Quad, clipped: ClippedEdges, aspect: f32) Quad {
    var out = quad;
    if (aspect <= 0) return out;
    if (clipped.top and !clipped.bottom and !clipped.left and !clipped.right) {
        const page_height = quad.bl.distance(quad.br) / aspect;
        out.tl = quad.bl.add(quad.tl.sub(quad.bl).normalized().scale(page_height));
        out.tr = quad.br.add(quad.tr.sub(quad.br).normalized().scale(page_height));
    } else if (clipped.bottom and !clipped.top and !clipped.left and !clipped.right) {
        const page_height = quad.tl.distance(quad.tr) / aspect;
        out.bl = quad.tl.add(quad.bl.sub(quad.tl).normalized().scale(page_height));
        out.br = quad.tr.add(quad.br.sub(quad.tr).normalized().scale(page_height));
    } else if (clipped.left and !clipped.right and !clipped.top and !clipped.bottom) {
        const page_width = quad.tr.distance(quad.br) * aspect;
        out.tl = quad.tr.add(quad.tl.sub(quad.tr).normalized().scale(page_width));
        out.bl = quad.br.add(quad.bl.sub(quad.br).normalized().scale(page_width));
    } else if (clipped.right and !clipped.left and !clipped.top and !clipped.bottom) {
        const page_width = quad.tl.distance(quad.bl) * aspect;
        out.tr = quad.tl.add(quad.tr.sub(quad.tl).normalized().scale(page_width));
        out.br = quad.bl.add(quad.br.sub(quad.bl).normalized().scale(page_width));
    }
    return out;
}

/// A corner within this distance of the image border, in pixels of the half-size
/// image, lies on the border.
const border_tolerance = 2.5;

fn quadFromLines(left: Line, top: Line, right: Line, bottom: Line) ?Quad {
    return .{
        .tl = left.intersect(top) orelse return null,
        .tr = right.intersect(top) orelse return null,
        .br = right.intersect(bottom) orelse return null,
        .bl = left.intersect(bottom) orelse return null,
    };
}

fn plausiblePage(quad: Quad) bool {
    if (!quad.isConvex()) return false;
    // Clockwise on the screen from the top left, in the frame of the paper.
    if (quad.signedArea() <= 0) return false;
    const width = quad.meanWidth();
    const height = quad.meanHeight();
    if (width < min_page_side or height < min_page_side) return false;
    const aspect = width / height;
    return aspect >= min_page_aspect and aspect <= max_page_aspect;
}

// endregion: layout

// region: tests

const testing = std.testing;

/// A synthetic frame: a dark desk with a bright paper shape given by `inside`.
const TestFrame = struct {
    buffer: []u8,
    view: image.FrameView,

    const width = 320;
    const height = 240;
    const desk_luma = 70;
    const paper_luma = 200;
    const neutral = 128;
    const desk_v = 150;

    fn init(context: anytype, comptime inside: fn (@TypeOf(context), f32, f32) ?u8) !TestFrame {
        const buffer = try testing.allocator.alloc(u8, image.packedFrameSize(width, height));
        const luma_size = width * height;
        const chroma_size = (width / 2) * (height / 2);
        for (0..height) |y| {
            for (0..width) |x| {
                const value = inside(context, @floatFromInt(x), @floatFromInt(y));
                buffer[y * width + x] = value orelse desk_luma;
            }
        }
        for (0..height / 2) |y| {
            for (0..width / 2) |x| {
                const value = inside(context, @floatFromInt(2 * x), @floatFromInt(2 * y));
                buffer[luma_size + y * (width / 2) + x] = neutral;
                buffer[luma_size + chroma_size + y * (width / 2) + x] = if (value == null) desk_v else neutral;
            }
        }
        return .{ .buffer = buffer, .view = image.FrameView.fromPacked(buffer, width, height, .{}) };
    }

    fn deinit(self: TestFrame) void {
        testing.allocator.free(self.buffer);
    }
};

fn expectPointNear(expected: Point, actual: Point, tolerance: f32) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
}

test "a single tilted page gives its four corners" {
    const page: Quad = .{
        .tl = Point.init(90, 40),
        .tr = Point.init(215, 52),
        .br = Point.init(205, 205),
        .bl = Point.init(78, 190),
    };
    const frame = try TestFrame.init(page, struct {
        fn inside(quad: Quad, x: f32, y: f32) ?u8 {
            return if (quad.contains(Point.init(x, y))) TestFrame.paper_luma else null;
        }
    }.inside);
    defer frame.deinit();

    const scene = (try analyzeScene(testing.allocator, frame.view, .{})).?;
    defer scene.deinit(testing.allocator);
    const layout = (try detectLayout(testing.allocator, &scene, .{})).?;
    try testing.expectEqual(LayoutKind.single, layout.kind);
    try testing.expect(!layout.clipped);
    try testing.expect(!layout.clipped_edges[0].any());
    const tolerance = 3.0;
    try expectPointNear(page.tl, layout.pages[0].tl, tolerance);
    try expectPointNear(page.tr, layout.pages[0].tr, tolerance);
    try expectPointNear(page.br, layout.pages[0].br, tolerance);
    try expectPointNear(page.bl, layout.pages[0].bl, tolerance);
}

test "a spread with a dark fold gives two pages" {
    const Spread = struct {
        left: Quad,
        right: Quad,
        fold_top: Point,
        fold_bottom: Point,
    };
    const spread: Spread = .{
        .left = .{
            .tl = Point.init(40, 50),
            .tr = Point.init(160, 60),
            .br = Point.init(158, 200),
            .bl = Point.init(36, 188),
        },
        .right = .{
            .tl = Point.init(160, 60),
            .tr = Point.init(285, 48),
            .br = Point.init(290, 192),
            .bl = Point.init(158, 200),
        },
        .fold_top = Point.init(160, 60),
        .fold_bottom = Point.init(158, 200),
    };
    const frame = try TestFrame.init(spread, struct {
        fn inside(s: Spread, x: f32, y: f32) ?u8 {
            const p = Point.init(x, y);
            if (!s.left.contains(p) and !s.right.contains(p)) return null;
            // A dark line at the fold, and a left page that is a little darker.
            const fold = Line.through(s.fold_top, s.fold_bottom);
            if (@abs(fold.signedDistance(p)) < 1.5) return 120;
            return if (s.left.contains(p)) 180 else TestFrame.paper_luma;
        }
    }.inside);
    defer frame.deinit();

    const scene = (try analyzeScene(testing.allocator, frame.view, .{})).?;
    defer scene.deinit(testing.allocator);
    const layout = (try detectLayout(testing.allocator, &scene, .{})).?;
    try testing.expectEqual(LayoutKind.spread, layout.kind);
    try testing.expect(layout.gutter_response > 3);
    const tolerance = 4.0;
    try expectPointNear(spread.left.tl, layout.pages[0].tl, tolerance);
    try expectPointNear(spread.left.bl, layout.pages[0].bl, tolerance);
    try expectPointNear(spread.fold_top, layout.pages[0].tr, tolerance);
    try expectPointNear(spread.fold_bottom, layout.pages[1].bl, tolerance);
    try expectPointNear(spread.right.tr, layout.pages[1].tr, tolerance);
    try expectPointNear(spread.right.br, layout.pages[1].br, tolerance);
}

test "a notch in the bottom edge does not move the edge" {
    const page: Quad = .{
        .tl = Point.init(80, 30),
        .tr = Point.init(230, 30),
        .br = Point.init(230, 210),
        .bl = Point.init(80, 210),
    };
    const frame = try TestFrame.init(page, struct {
        fn inside(quad: Quad, x: f32, y: f32) ?u8 {
            if (!quad.contains(Point.init(x, y))) return null;
            // A finger: a dark notch from the bottom edge.
            if (x > 120 and x < 170 and y > 170) return null;
            return TestFrame.paper_luma;
        }
    }.inside);
    defer frame.deinit();

    const scene = (try analyzeScene(testing.allocator, frame.view, .{})).?;
    defer scene.deinit(testing.allocator);
    const layout = (try detectLayout(testing.allocator, &scene, .{ .layout = .single })).?;
    const tolerance = 3.0;
    try expectPointNear(page.bl, layout.pages[0].bl, tolerance);
    try expectPointNear(page.br, layout.pages[0].br, tolerance);
}

test "a page that runs out of the frame at the top has a clipped top edge" {
    const page: Quad = .{
        .tl = Point.init(90, -40),
        .tr = Point.init(230, -40),
        .br = Point.init(230, 170),
        .bl = Point.init(90, 170),
    };
    const frame = try TestFrame.init(page, struct {
        fn inside(quad: Quad, x: f32, y: f32) ?u8 {
            return if (quad.contains(Point.init(x, y))) TestFrame.paper_luma else null;
        }
    }.inside);
    defer frame.deinit();

    const scene = (try analyzeScene(testing.allocator, frame.view, .{})).?;
    defer scene.deinit(testing.allocator);
    const layout = (try detectLayout(testing.allocator, &scene, .{ .layout = .single })).?;
    try testing.expect(layout.clipped);
    try testing.expect(layout.clipped_edges[0].top);
    try testing.expect(!layout.clipped_edges[0].bottom);
    try testing.expect(!layout.clipped_edges[0].left);
    try testing.expectEqual(@as(u8, 1), layout.clipped_edges[0].count());
}

test "a curled page gives an outline that follows its two curved edges" {
    // The two edges sag by 12 pixels in the middle, as the edges of a page that
    // curls. A finger covers a part of the bottom edge.
    const Shape = struct {
        fn sag(x: f32) f32 {
            const t = (x - 160) / 80;
            return 12 * (1 - t * t);
        }
        fn inside(_: void, x: f32, y: f32) ?u8 {
            if (x < 80 or x > 240) return null;
            if (y < 40 + sag(x) or y > 190 + sag(x)) return null;
            if (x > 130 and x < 175 and y > 165) return null;
            return TestFrame.paper_luma;
        }
    };
    const frame = try TestFrame.init({}, Shape.inside);
    defer frame.deinit();

    const scene = (try analyzeScene(testing.allocator, frame.view, .{})).?;
    defer scene.deinit(testing.allocator);
    const flat = (try detectLayout(testing.allocator, &scene, .{ .layout = .single })).?;
    try testing.expect(flat.outlines[0] == null);

    const layout = (try detectLayout(testing.allocator, &scene, .{ .layout = .single, .outlines = true })).?;
    const outline = layout.outlines[0].?;
    try testing.expect(outline.maxBend() > 8);
    for (outline.top) |p| try testing.expectApproxEqAbs(40 + Shape.sag(p.x), p.y, 3.0);
    // The bottom edge follows the same bend, also under the finger.
    for (outline.bottom) |p| try testing.expectApproxEqAbs(190 + Shape.sag(p.x), p.y, 3.5);
    // The ends of the outline are the corners of the page.
    try testing.expectApproxEqAbs(@as(f32, 80), outline.top[0].x, 3.0);
    try testing.expectApproxEqAbs(@as(f32, 240), outline.bottom[curl.stations - 1].x, 3.0);
}

test "a flat page has no outline" {
    const page: Quad = .{
        .tl = Point.init(90, 40),
        .tr = Point.init(215, 52),
        .br = Point.init(205, 205),
        .bl = Point.init(78, 190),
    };
    const frame = try TestFrame.init(page, struct {
        fn inside(quad: Quad, x: f32, y: f32) ?u8 {
            return if (quad.contains(Point.init(x, y))) TestFrame.paper_luma else null;
        }
    }.inside);
    defer frame.deinit();
    const scene = (try analyzeScene(testing.allocator, frame.view, .{})).?;
    defer scene.deinit(testing.allocator);
    const layout = (try detectLayout(testing.allocator, &scene, .{ .outlines = true })).?;
    try testing.expect(layout.outlines[0] == null);
}

test "completeQuad restores a page that is cut at the top" {
    const full = Quad.rect(200, 300);
    var cut = full;
    cut.tl.y = 80;
    cut.tr.y = 80;
    const restored = completeQuad(cut, .{ .top = true }, 200.0 / 300.0);
    try expectPointNear(full.tl, restored.tl, 0.01);
    try expectPointNear(full.tr, restored.tr, 0.01);
    try expectPointNear(full.bl, restored.bl, 0.01);
    // Two cut sides give no answer: the quad stays.
    const unchanged = completeQuad(cut, .{ .top = true, .bottom = true }, 200.0 / 300.0);
    try expectPointNear(cut.tl, unchanged.tl, 0.01);
}

test "a frame without paper has no scene" {
    const frame = try TestFrame.init({}, struct {
        fn inside(_: void, _: f32, _: f32) ?u8 {
            return null;
        }
    }.inside);
    defer frame.deinit();
    try testing.expect(try analyzeScene(testing.allocator, frame.view, .{}) == null);
}

// endregion: tests
