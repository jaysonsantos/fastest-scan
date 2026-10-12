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
const lines = @import("lines.zig");
const curl = @import("curl.zig");

const Point = geometry.Point;
const Line = geometry.Line;
const Quad = geometry.Quad;
const Plane = image.Plane;
const PlaneView = image.PlaneView;

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
    /// Look for the paper by its outline when the bright region is not like a sheet
    /// of paper: a book on a surface as bright as its pages (decision 0024).
    outline_search: bool = true,
    /// The bright region stays when it is this much like a sheet of paper, from 0
    /// to 1. See `paperLikeness`.
    good_likeness: f32 = 0.5,
    /// The region of the outline search must be this much like a sheet of paper.
    min_outline_likeness: f32 = 0.35,
    /// The region of the outline search must be better than the bright region by
    /// this much.
    likeness_margin: f32 = 0.15,
    /// This part of the outline of the region of the outline search must have
    /// another surface outside: a desk or a floor. A block of text on a page has
    /// its own paper around it. See `otherSurfacePart` (decision 0027).
    min_other_surface: f32 = 0.6,
    /// A pixel is a part of an outline when the luma changes by more than this
    /// many codes from one pixel to the next one, after a small blur.
    outline_step: f32 = 3.5,
    /// One code of chroma counts as this many codes of luma in that measure. Paper
    /// on a surface of the same brightness often differs in colour only.
    outline_chroma_gain: f32 = 3.0,
    /// When the outline search finds no paper, look for a page by its four
    /// straight edges: a desk with a texture, with things that touch the book, or
    /// a page with a weak part in its outline (decision 0026).
    line_search: bool = true,
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
    /// The size of the steps of the outline of `region`, in pixels of the half-size
    /// image. It is above 1 when the region comes from a smaller working image:
    /// an edge line then needs more room for its points.
    outline_step: f32 = 1,
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

    var region = (try raster.largestRegion(allocator, opened)) orelse {
        luma.deinit(allocator);
        score.deinit(allocator);
        return null;
    };
    errdefer region.deinit(allocator);
    const frame_area: f32 = @floatFromInt(@as(usize, score.width) * score.height);
    if (@as(f32, @floatFromInt(region.area)) < options.min_area_fraction * frame_area) {
        region.deinit(allocator);
        luma.deinit(allocator);
        score.deinit(allocator);
        return null;
    }

    // A bright region that lies on the frame border can be a wall or a desk, not
    // the paper. The outline search then looks for a book inside the frame.
    var outline_step: f32 = 1;
    if (options.outline_search and region.touches_border) {
        const likeness = try paperLikeness(allocator, region);
        if (likeness < options.good_likeness) {
            const planes: OutlinePlanes = .{ .luma = luma.view(), .u = frame.u, .v = frame.v, .width = width, .height = height };
            if (try stepField(allocator, planes, options)) |field| {
                defer field.deinit(allocator);
                var better = try betterRegion(allocator, try outlineRegion(allocator, field, planes, opened, options), likeness, options);
                if (better == null and options.line_search) {
                    const paper: PaperMask = .{ .bright = opened, .u = frame.u, .v = frame.v };
                    better = try betterRegion(allocator, try lineRegion(allocator, field, paper), likeness, options);
                }
                if (better) |found| {
                    region.deinit(allocator);
                    region = found.region;
                    outline_step = found.step;
                }
            }
        }
    }

    return .{
        .luma = luma,
        .score = score,
        .threshold = split.threshold,
        .separability = split.separability,
        .region = region,
        .outline_step = outline_step,
        .scale = Scene.half_scale,
    };
}

const min_scene_side = 32;

// endregion: paper mask

// region: outline search

// A book on a surface as bright as its pages: no threshold of the paper score
// separates the two. But the book has an outline: a step of brightness or of
// colour, or a thin shadow line. The search marks the pixels with such a step as
// walls and lets a flood run from the frame border over all other pixels. What
// the flood does not reach is the walls and all that they enclose: the book with
// its text, and thin lines such as the edge of a wall or a joint of the floor. An
// opening removes the thin lines. The largest region that stays holds the paper.
//
// The flood enters a page that runs out of the frame. So the bright region stays
// the first choice, and the search is for a book that lies inside the frame.
//
// A block of text on a page has a closed line of steps around it too, and so has
// a picture. When the flood is inside a page, such a block is all that the flood
// leaves. So the region of the search is the paper only when another surface
// lies around it: see `otherSurfacePart`.
//
// The idea to take, among several shapes of a frame, the shape most like a sheet
// of paper is from E. Carlinet and T. Géraud, the method of the LRDE in J.-C.
// Burie et al., "ICDAR2015 Competition on Smartphone Document Capture and OCR
// (SmartDoc)", ICDAR 2015. Their shapes come from the tree of shapes; the shapes
// here are the bright region and the region inside the outline. The gradient
// operator is that of I. Sobel and G. Feldman, "A 3x3 isotropic gradient operator
// for image processing", Stanford Artificial Intelligence Project, 1968.
// `prototypes/detect/` has the experiment behind this code.

/// The search works on planes with at most this width, in pixels. A wider plane
/// is made smaller first: the sizes below are in pixels of that working plane.
const outline_work_width = 512;
/// The opening removes lines up to two times this width.
const thin_line_half_width = 4;
/// The walls of an outline have this many pixels on each side of it: one from the
/// blur and the gradient, and one from the step that makes the walls thicker.
const wall_half_width = 2;
/// How much a part of the outline on the frame border lowers the likeness: with
/// one third of the outline on the border, the likeness is 0.
const border_likeness_weight = 3.0;
/// The sum of the weights of the 3x3 binomial blur, and of one side of the Sobel
/// operator.
const blur_weight_sum = 16.0;
const sobel_weight_sum = 8.0;
/// The outline of a region is cut into this many directions from the middle of
/// the region, each with its own check of the surface outside. The light changes
/// across a page, so the two sides of the outline are compared at one place.
const surface_sectors = 16;
/// The surface outside is what the flood reached within this many pixels of the
/// region.
const surface_reach = 4;
/// A direction needs this many flat pixels inside, and this many outside.
const min_surface_pixels = 4;
/// The surface outside is another surface when it is darker than the flat paper
/// inside by this many codes of luma. The same holds for a difference of
/// `min_surface_chroma` codes of chroma.
const min_darker_surface = 12.0;
/// The tangent of 22.5 degrees: the half of an octant.
const half_octant_slope = 0.41421356;

/// The planes of a frame for the outline search, all with one size.
const OutlinePlanes = struct {
    luma: PlaneView,
    u: PlaneView,
    v: PlaneView,
    /// The part of the planes in use: the three planes can differ by one pixel.
    width: u32,
    height: u32,
};

const OutlineRegion = struct {
    region: raster.Region,
    /// The size of the steps of the outline of the region, in pixels of the planes.
    step: f32,
};

/// The region of a search when it is more like a sheet of paper than the bright
/// region, which has the likeness `likeness`. Frees the region when it is not.
fn betterRegion(allocator: Allocator, candidate: ?OutlineRegion, likeness: f32, options: Options) Allocator.Error!?OutlineRegion {
    const found = candidate orelse return null;
    errdefer found.region.deinit(allocator);
    const found_likeness = try paperLikeness(allocator, found.region);
    if (found_likeness >= options.min_outline_likeness and found_likeness > likeness + options.likeness_margin) return found;
    found.region.deinit(allocator);
    return null;
}

/// The steps of a frame at the working size of the outline search and of the line
/// search.
const StepField = struct {
    width: u32,
    height: u32,
    /// One pixel of the field is `factor` x `factor` pixels of the planes.
    factor: u32,
    /// The strength of the step at each pixel, in codes for one pixel: the sum of
    /// the three planes.
    strength: []f32,
    /// The sums over the three planes of the products of the two parts of the
    /// gradient: across times across, across times down, and down times down.
    /// They give the direction of a step that more than one plane has: see
    /// `angle`.
    across_across: []f32,
    across_down: []f32,
    down_down: []f32,

    fn deinit(self: StepField, allocator: Allocator) void {
        allocator.free(self.strength);
        allocator.free(self.across_across);
        allocator.free(self.across_down);
        allocator.free(self.down_down);
    }

    /// The direction of the step of a pixel in whole degrees, 0 to 179: the
    /// direction in which the three planes together change most. This is the
    /// gradient of a multi-image of S. Di Zenzo, "A note on the gradient of a
    /// multi-image", Computer Vision, Graphics, and Image Processing 33, 1986.
    fn angle(self: StepField, index: usize) u8 {
        const twice = std.math.atan2(2 * self.across_down[index], self.across_across[index] - self.down_down[index]);
        const degrees = @mod(std.math.radiansToDegrees(0.5 * twice), lines.angle_count);
        return @intCast(@as(u32, @intFromFloat(@round(degrees))) % lines.angle_count);
    }
};

/// The steps of the three planes of a frame. Null for a frame that is too small.
fn stepField(allocator: Allocator, planes: OutlinePlanes, options: Options) Allocator.Error!?StepField {
    const factor: u32 = @max(1, (planes.width + outline_work_width - 1) / outline_work_width);
    const width: u32 = planes.width / factor;
    const height: u32 = planes.height / factor;
    if (width < min_scene_side or height < min_scene_side) return null;
    const pixel_count = @as(usize, width) * height;

    const strength = try allocator.alloc(f32, pixel_count);
    errdefer allocator.free(strength);
    const across_across = try allocator.alloc(f32, pixel_count);
    errdefer allocator.free(across_across);
    const across_down = try allocator.alloc(f32, pixel_count);
    errdefer allocator.free(across_down);
    const down_down = try allocator.alloc(f32, pixel_count);
    errdefer allocator.free(down_down);
    const field: StepField = .{
        .width = width,
        .height = height,
        .factor = factor,
        .strength = strength,
        .across_across = across_across,
        .across_down = across_down,
        .down_down = down_down,
    };
    @memset(strength, 0);
    @memset(across_across, 0);
    @memset(across_down, 0);
    @memset(down_down, 0);
    const sources = [_]struct { plane: PlaneView, gain: f32 }{
        .{ .plane = planes.luma, .gain = 1 },
        .{ .plane = planes.u, .gain = options.outline_chroma_gain },
        .{ .plane = planes.v, .gain = options.outline_chroma_gain },
    };
    for (sources) |source| {
        const small = try reducePlane(allocator, source.plane, width, height, factor);
        defer small.deinit(allocator);
        try addSteps(allocator, field, small, source.gain);
    }
    return field;
}

/// How much a region is like a sheet of paper that lies inside the frame, from 0
/// to 1: the product of three parts. The region fills its convex hull (a hand on
/// the paper takes a bite out of it). The hull fills the smallest rectangle
/// around it. The outline of the region does not lie on the frame border.
fn paperLikeness(allocator: Allocator, region: raster.Region) Allocator.Error!f32 {
    const boundary = try boundaryPoints(allocator, region);
    defer allocator.free(boundary);
    if (boundary.len < 3) return 0;
    const last_x: f32 = @floatFromInt(region.mask.width - 1);
    const last_y: f32 = @floatFromInt(region.mask.height - 1);
    var on_border: usize = 0;
    for (boundary) |p| {
        if (p.x == 0 or p.y == 0 or p.x == last_x or p.y == last_y) on_border += 1;
    }
    const border_fraction = @as(f32, @floatFromInt(on_border)) / @as(f32, @floatFromInt(boundary.len));
    const inside = @max(0, 1 - border_likeness_weight * border_fraction);
    if (inside == 0) return 0;

    const hull = try convexHull(allocator, boundary);
    defer allocator.free(hull);
    if (hull.len < 3) return 0;
    const hull_area = polygonArea(hull);
    const rectangle_area = smallestRectangleArea(hull);
    if (!(hull_area > 0) or !(rectangle_area > 0)) return 0;
    // The hull goes through pixel centers, so a solid region has a little more
    // area than its hull.
    const solidity = @min(1, @as(f32, @floatFromInt(region.area)) / hull_area);
    const rectangle_fill = @min(1, hull_area / rectangle_area);
    return solidity * rectangle_fill * inside;
}

/// The area of a convex polygon.
fn polygonArea(points: []const Point) f32 {
    var twice: f32 = 0;
    for (points, 0..) |a, index| {
        const b = points[(index + 1) % points.len];
        twice += a.cross(b);
    }
    return 0.5 * @abs(twice);
}

/// The area of the smallest rectangle around a convex hull. One side of that
/// rectangle lies on an edge of the hull: see `paperFrame`.
fn smallestRectangleArea(hull: []const Point) f32 {
    var best = std.math.inf(f32);
    for (hull, 0..) |a, index| {
        const edge = hull[(index + 1) % hull.len].sub(a);
        if (edge.length() < min_hull_edge) continue;
        const axis = edge.normalized();
        const normal = axis.perpendicular();
        var min_u = std.math.inf(f32);
        var max_u = -std.math.inf(f32);
        var min_v = std.math.inf(f32);
        var max_v = -std.math.inf(f32);
        for (hull) |p| {
            const along = p.dot(axis);
            const across = p.dot(normal);
            min_u = @min(min_u, along);
            max_u = @max(max_u, along);
            min_v = @min(min_v, across);
            max_v = @max(max_v, across);
        }
        best = @min(best, (max_u - min_u) * (max_v - min_v));
    }
    return if (std.math.isInf(best)) 0 else best;
}

/// The sum of the pixels of one surface.
const SurfaceSum = struct {
    count: u32 = 0,
    luma: u32 = 0,
    u: u32 = 0,
    v: u32 = 0,

    /// Add the pixel of the planes in the middle of the pixel (`x`, `y`) of a
    /// field with the factor `factor`.
    fn add(self: *SurfaceSum, planes: OutlinePlanes, factor: u32, x: usize, y: usize) void {
        const plane_x = @min(x * factor + factor / 2, planes.width - 1);
        const plane_y = @min(y * factor + factor / 2, planes.height - 1);
        self.count += 1;
        self.luma += planes.luma.at(plane_x, plane_y);
        self.u += planes.u.at(plane_x, plane_y);
        self.v += planes.v.at(plane_x, plane_y);
    }

    fn mean(self: SurfaceSum, sum: u32) f32 {
        return @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(self.count));
    }

    /// True when `outside` is another surface than `self`, the flat paper inside
    /// a region. A brighter surface with the colour of the paper is not: a block
    /// of text that is not sharp, and a box with a tint, are darker than the
    /// paper around them.
    fn differsFrom(self: SurfaceSum, outside: SurfaceSum) bool {
        const chroma = @abs(outside.mean(outside.u) - self.mean(self.u)) + @abs(outside.mean(outside.v) - self.mean(self.v));
        if (chroma >= min_surface_chroma) return true;
        return outside.mean(outside.luma) <= self.mean(self.luma) - min_darker_surface;
    }
};

/// One of `surface_sectors` directions of equal size, for a vector that is not zero.
fn surfaceSector(dx: f32, dy: f32) usize {
    const across = @abs(dx);
    const down = @abs(dy);
    // The octant, and then the half of the octant.
    var sector: usize = 0;
    if (dx < 0) sector |= 1;
    if (dy < 0) sector |= 2;
    if (down > across) sector |= 4;
    if (@min(across, down) > half_octant_slope * @max(across, down)) sector |= 8;
    return sector;
}

/// The part of the outline of a region that has another surface outside, from 0
/// to 1. A sheet of paper lies on another surface: a desk, or a floor. A block of
/// text on a page has its own paper around it.
///
/// The function compares flat places only: pixels with no step. Inside the
/// region they are free paper, such as a margin. Outside they are the surface
/// that the flood reached. Text is not flat, so it does not change the result.
/// A direction with too few flat pixels on one side is not a sign of another
/// surface.
///
/// `walls` and `reached` are the planes of the flood: a pixel that the flood
/// reached has no step. `planes` has the frame, at `factor` pixels for one pixel
/// of the region.
fn otherSurfacePart(
    allocator: Allocator,
    planes: OutlinePlanes,
    factor: u32,
    walls: Plane,
    reached: Plane,
    region: raster.Region,
) Allocator.Error!f32 {
    const mask = region.mask;
    const near = try repeatMorphology(allocator, mask, surface_reach, raster.dilate3);
    defer near.deinit(allocator);

    // The middle of the box around the region.
    const middle_x = 0.5 * @as(f32, @floatFromInt(region.min_x + region.max_x));
    const middle_y = 0.5 * @as(f32, @floatFromInt(region.min_y + region.max_y));
    var inside: [surface_sectors]SurfaceSum = @splat(.{});
    var outside: [surface_sectors]SurfaceSum = @splat(.{});
    var outline: [surface_sectors]u32 = @splat(0);
    const last_x = mask.width - 1;
    const last_y = mask.height - 1;
    for (region.min_y -| surface_reach..@min(region.max_y + surface_reach, last_y) + 1) |y| {
        const dy = @as(f32, @floatFromInt(y)) - middle_y;
        for (region.min_x -| surface_reach..@min(region.max_x + surface_reach, last_x) + 1) |x| {
            const in_region = mask.at(x, y) != 0;
            if (!in_region and near.at(x, y) == 0) continue;
            const sector = surfaceSector(@as(f32, @floatFromInt(x)) - middle_x, dy);
            if (!in_region) {
                if (reached.at(x, y) != 0) outside[sector].add(planes, factor, x, y);
                continue;
            }
            if (walls.at(x, y) == 0) inside[sector].add(planes, factor, x, y);
            const on_outline = x == 0 or y == 0 or x == last_x or y == last_y or
                mask.at(x - 1, y) == 0 or mask.at(x + 1, y) == 0 or
                mask.at(x, y - 1) == 0 or mask.at(x, y + 1) == 0;
            if (on_outline) outline[sector] += 1;
        }
    }

    var total: u32 = 0;
    var other: u32 = 0;
    for (inside, outside, outline) |paper, surface, length| {
        total += length;
        if (paper.count < min_surface_pixels or surface.count < min_surface_pixels) continue;
        if (paper.differsFrom(surface)) other += length;
    }
    if (total == 0) return 0;
    return @as(f32, @floatFromInt(other)) / @as(f32, @floatFromInt(total));
}

/// Find the paper as the largest region that a flood from the frame border does
/// not reach. `field` has the steps of the frame, and `planes` the frame.
/// `bright` is the paper mask of the frame: a hand on the book is inside the
/// outline of the book, and it is not bright. Returns null when the flood leaves
/// no region of the smallest size, or a region with its own paper around it.
fn outlineRegion(allocator: Allocator, field: StepField, planes: OutlinePlanes, bright: Plane, options: Options) Allocator.Error!?OutlineRegion {
    const factor = field.factor;
    const width = field.width;
    const height = field.height;
    const pixel_count = @as(usize, width) * height;

    const thin_walls = try Plane.init(allocator, width, height);
    defer thin_walls.deinit(allocator);
    for (thin_walls.data, field.strength) |*wall, value| wall.* = if (value > options.outline_step) raster.mask_set else 0;
    // Thicker walls close the small gaps of an outline.
    const walls = try raster.dilate3(allocator, thin_walls);
    defer walls.deinit(allocator);

    const reached = try raster.floodFromBorder(allocator, walls);
    defer reached.deinit(allocator);
    // What the flood does not reach: the walls and all that they enclose.
    const enclosed = try Plane.init(allocator, width, height);
    defer enclosed.deinit(allocator);
    for (enclosed.data, reached.data) |*value, flooded| value.* = if (flooded == 0) raster.mask_set else 0;
    const without_lines = try repeatMorphology(allocator, enclosed, thin_line_half_width, raster.erode3);
    defer without_lines.deinit(allocator);
    const solid = try repeatMorphology(allocator, without_lines, thin_line_half_width, raster.dilate3);
    defer solid.deinit(allocator);

    const blob = (try raster.largestRegion(allocator, solid)) orelse return null;
    defer blob.deinit(allocator);
    if (@as(f32, @floatFromInt(blob.area)) < options.min_area_fraction * @as(f32, @floatFromInt(pixel_count))) return null;
    // A block of text or a picture on a page, with its own paper around it.
    if (try otherSurfacePart(allocator, planes, factor, walls, reached, blob) < options.min_other_surface) return null;
    // The outline of the paper is in the middle of its walls.
    const tight = try repeatMorphology(allocator, blob.mask, wall_half_width, raster.erode3);
    defer tight.deinit(allocator);

    // Back at the size of the planes, with only the bright pixels.
    const mask = try Plane.initFilled(allocator, bright.width, bright.height, 0);
    defer mask.deinit(allocator);
    for (0..@min(bright.height, height * factor)) |y| {
        const tight_row = tight.row(y / factor);
        const bright_row = bright.row(y);
        const mask_row = mask.row(y);
        for (0..@min(bright.width, width * factor)) |x| {
            mask_row[x] = tight_row[x / factor] & bright_row[x];
        }
    }
    const region = (try raster.largestRegion(allocator, mask)) orelse return null;
    const frame_pixels: f32 = @floatFromInt(@as(usize, bright.width) * bright.height);
    if (@as(f32, @floatFromInt(region.area)) < options.min_area_fraction * frame_pixels) {
        region.deinit(allocator);
        return null;
    }
    return .{ .region = region, .step = @floatFromInt(factor) };
}

/// A plane of `width` x `height` pixels: each pixel is the mean of `factor` x
/// `factor` pixels of the source.
fn reducePlane(allocator: Allocator, source: PlaneView, width: u32, height: u32, factor: u32) Allocator.Error!Plane {
    const out = try Plane.init(allocator, width, height);
    const cell_pixels = factor * factor;
    for (0..height) |y| {
        const target = out.row(y);
        for (target, 0..) |*value, x| {
            var sum: u32 = 0;
            for (0..factor) |sub_y| {
                const row = source.data[(y * factor + sub_y) * source.stride ..];
                for (row[x * factor ..][0..factor]) |sample| sum += sample;
            }
            value.* = @intCast((sum + cell_pixels / 2) / cell_pixels);
        }
    }
    return out;
}

/// Add the steps of a plane to `field`: the Sobel gradient after a 3x3 binomial
/// blur, in codes for one pixel, times `gain`. The strength is the length of the
/// gradient. A pixel outside the plane has the value of the nearest pixel inside.
fn addSteps(allocator: Allocator, field: StepField, plane: Plane, gain: f32) Allocator.Error!void {
    const width: usize = plane.width;
    const height: usize = plane.height;
    // The blur as a sum of 16 weights, with no division.
    const blurred = try allocator.alloc(u16, width * height);
    defer allocator.free(blurred);
    for (0..height) |y| {
        const above = plane.row(y -| 1);
        const here = plane.row(y);
        const below = plane.row(@min(y + 1, height - 1));
        for (0..width) |x| {
            const left = x -| 1;
            const right = @min(x + 1, width - 1);
            blurred[y * width + x] =
                @as(u16, above[left]) + 2 * @as(u16, above[x]) + above[right] +
                2 * @as(u16, here[left]) + 4 * @as(u16, here[x]) + 2 * @as(u16, here[right]) +
                @as(u16, below[left]) + 2 * @as(u16, below[x]) + below[right];
        }
    }
    const scale = gain / (blur_weight_sum * sobel_weight_sum);
    for (0..height) |y| {
        const above = blurred[(y -| 1) * width ..][0..width];
        const here = blurred[y * width ..][0..width];
        const below = blurred[@min(y + 1, height - 1) * width ..][0..width];
        for (0..width) |x| {
            const left = x -| 1;
            const right = @min(x + 1, width - 1);
            const across: f32 = @floatFromInt(@as(i32, above[right]) + 2 * @as(i32, here[right]) + below[right] -
                @as(i32, above[left]) - 2 * @as(i32, here[left]) - below[left]);
            const down: f32 = @floatFromInt(@as(i32, below[left]) + 2 * @as(i32, below[x]) + below[right] -
                @as(i32, above[left]) - 2 * @as(i32, above[x]) - above[right]);
            const index = y * width + x;
            field.strength[index] += scale * @sqrt(across * across + down * down);
            field.across_across[index] += (scale * across) * (scale * across);
            field.across_down[index] += (scale * across) * (scale * down);
            field.down_down[index] += (scale * down) * (scale * down);
        }
    }
}

/// Apply a 3x3 morphology step `times` times. The result is a new plane, also for
/// zero times.
fn repeatMorphology(
    allocator: Allocator,
    mask: Plane,
    times: usize,
    comptime step: fn (Allocator, Plane) Allocator.Error!Plane,
) Allocator.Error!Plane {
    var current = try Plane.init(allocator, mask.width, mask.height);
    @memcpy(current.data, mask.data);
    errdefer current.deinit(allocator);
    for (0..times) |_| {
        const next = try step(allocator, current);
        current.deinit(allocator);
        current = next;
    }
    return current;
}

// endregion: outline search

// region: line search

// The outline search needs a closed outline around the book and a free desk
// around that outline. It fails on a desk with a texture, such as the grain of
// wood (the texture is walls), when a thing touches the book (the thing and the
// part of the desk that the two enclose stay with the book), and when one part
// of the page outline is weak (the flood enters the page there).
//
// The line search looks for the four straight edges of a page. It takes the
// straight lines of the frame (`lines.zig`), and then the four lines that make a
// quad with a page inside: each side of the quad has steps along most of its
// length, and most of the inside is bright. A gap in one side or a thing at one
// corner does not break it.
//
// The result is the page with the largest product of its area and the support of
// its four sides. The area alone is not enough: a quad with the edge of the desk
// as one side is larger than the page, but two of its sides then go on past the
// corners of the page, where they have no steps.
//
// Z. Zhang and L.-W. He, "Whiteboard scanning and image enhancement", Digital
// Signal Processing 17(2), 2007, find a whiteboard in this way: a Hough transform
// with the direction of the gradient, then two lines that go one way and two
// lines across them, and a check that each side of the quad has edges. The
// methods of the SmartDoc competition do the same for a document: J.-C. Burie et
// al., "ICDAR2015 Competition on Smartphone Document Capture and OCR
// (SmartDoc)", ICDAR 2015. `prototypes/detect/line_quads.py` has the experiment
// behind this code.
//
// The sizes below are in pixels of the step field.

/// The number of lines that can be a side of a page.
const line_count = 24;
const max_line_pairs = line_count * (line_count - 1) / 2;
/// A step of this strength is a part of a line, in codes for one pixel. The grain
/// of a desk is weaker, and the edge of a sheet of paper is stronger.
const line_step = 6.0;
/// The two opposite sides of a page differ by at most this many degrees: the
/// camera does not look straight down at the page.
const max_opposite_degrees = 30;
/// Two sides that meet at a corner differ by at least this many degrees.
const min_corner_degrees = 60;
/// A side of a page, and a line, is at least this part of the short side of the frame.
const min_side_fraction = 0.15;
/// The edge of a sheet of paper has steps along all its length. A line on a page,
/// such as the edge of a block of text or of a picture, or a line that is hidden
/// in part, has not. So `min_strong_sides` of the four sides of a page have steps
/// along `strong_side_support` of their length at least, and the last side along
/// `min_side_support`: a finger or a shadow can hide a part of one side. On the
/// benchmark video (a booklet on a dark desk, with a hand on it), this rule
/// removes each quad that is not a sheet.
const min_strong_sides = 3;
const strong_side_support = 0.9;
const min_side_support = 0.7;
/// A side with steps along this part of its length has full support in the score
/// of a page: the corners of a book are round, and the two ends of a side have
/// no steps.
const full_side_support = 0.9;
/// This part of the inside of a page is bright.
const min_bright_part = 0.8;
/// The search is for a sheet of paper on a bright surface. A block of text or a
/// picture on a page is a quad with lines too, and it is bright inside. But it has
/// its own paper on the two sides of each of its lines, and a sheet has another
/// surface around it: a desk, or a floor. The colour shows the difference. The
/// mean chroma of the bright pixels outside a side of a sheet differs from the
/// mean chroma inside by `min_surface_chroma` codes at least (U and V together),
/// at `surface_distance` pixels from the side. The brightness does not show it:
/// in a frame that is not sharp, a block of text is grey paper.
///
/// A sheet has another surface at `min_other_sides` of its four sides at least,
/// and its own paper at `max_same_sides` at most: the other page of an open book.
/// A side with a dark surface outside is neither: a dark thing lies there, or the
/// desk is dark, and then the bright region finds the sheet.
const surface_distance = 5.0;
const min_surface_chroma = 3.0;
const min_bright_outside = 0.5;
const min_other_sides = 2;
const max_same_sides = 1;
/// The two ends of a side are not a part of that measure: this part of the
/// length at each end.
const surface_end_fraction = 0.1;
/// The smallest page, as a part of the frame area. A smaller quad is more often
/// a block of text or a picture than a page.
const min_line_page_fraction = 0.08;
/// The second page of an open book has an area within this factor of the first
/// page, and the two pages have this part of the fold between them in common.
const max_page_area_ratio = 1.7;
const min_shared_fold = 0.7;
/// The normal of the fold of an open book is within this many degrees of the
/// direction from the left to the right: the fold goes from the top to the bottom.
const max_fold_degrees = 45;

/// A quad of four lines that is a page.
const PageQuad = struct {
    /// The corners go around the quad. The side `k` goes from the corner `k` to
    /// the next corner, and it lies on the line `sides[k]`.
    corners: [4]Point,
    sides: [4]u8,
    area: f32,
    /// The area times the support of the four sides.
    score: f32,
};

/// The paper of a frame: the mask of the bright pixels, and the two chroma planes
/// of the frame. The three planes have one size, but for one pixel at the right
/// and the lower border.
const PaperMask = struct {
    bright: Plane,
    u: PlaneView,
    v: PlaneView,
};

/// What lies outside one side of a quad.
const Surface = enum {
    /// Not bright: a dark desk, or a dark thing.
    dark,
    /// Bright, with the colour of the inside of the quad.
    same,
    /// Bright, with another colour.
    other,
};

const LineSearch = struct {
    found: lines.Lines,
    paper: PaperMask,
    /// The pixels of the paper planes for one pixel of the field, in each direction.
    factor: u32,
    width: f32,
    height: f32,

    /// The quad with two lines that go about one way (`first`) and two lines that
    /// go about across them (`second`), when it is a page with a score above
    /// `min_score`.
    fn page(self: LineSearch, first: [2]u8, second: [2]u8, min_score: f32) ?PageQuad {
        const items = self.found.items;
        for (first) |a| {
            for (second) |b| {
                if (lines.angleBetween(items[a].degrees, items[b].degrees) < min_corner_degrees) return null;
            }
        }
        // Around the quad: each corner is where two sides meet.
        const meeting = [4][2]u8{ .{ first[0], second[0] }, .{ second[0], first[1] }, .{ first[1], second[1] }, .{ second[1], first[0] } };
        const sides = [4]u8{ second[0], first[1], second[1], first[0] };
        var corners: [4]Point = undefined;
        for (meeting, &corners) |pair, *corner| {
            corner.* = items[pair[0]].asGeometry().intersect(items[pair[1]].asGeometry()) orelse return null;
            // The whole page is inside the frame.
            if (corner.x < 0 or corner.y < 0 or corner.x > self.width - 1 or corner.y > self.height - 1) return null;
        }
        const quad = Quad.fromCorners(corners);
        if (!quad.isConvex()) return null;
        const area = quad.area();
        if (area < min_line_page_fraction * self.width * self.height) return null;

        const min_side = min_side_fraction * @min(self.width, self.height);
        var strong_sides: u32 = 0;
        var score = area;
        for (sides, 0..) |line, k| {
            const from = corners[k];
            const to = corners[(k + 1) % corners.len];
            if (from.distance(to) < min_side) return null;
            const support = self.found.support(line, from, to);
            if (support < min_side_support) return null;
            strong_sides += @intFromBool(support >= strong_side_support);
            score *= @min(1, support / full_side_support);
        }
        if (strong_sides < min_strong_sides) return null;
        if (!(score > min_score)) return null;
        if (self.brightPart(corners) < min_bright_part) return null;
        var other_sides: u32 = 0;
        var same_sides: u32 = 0;
        const middle = quad.center();
        for (corners, 0..) |from, k| {
            switch (self.surfaceOutside(from, corners[(k + 1) % corners.len], middle)) {
                .other => other_sides += 1,
                .same => same_sides += 1,
                .dark => {},
            }
        }
        if (other_sides < min_other_sides or same_sides > max_same_sides) return null;
        return .{ .corners = corners, .sides = sides, .area = area, .score = score };
    }

    /// The surface outside the side from `from` to `to` of a quad with the middle
    /// `middle`.
    fn surfaceOutside(self: LineSearch, from: Point, to: Point, middle: Point) Surface {
        const side = Line.through(from, to);
        // The normal of the side that points away from the middle of the quad.
        const outward = if (side.signedDistance(middle) > 0) side.normal().scale(-1) else side.normal();
        const shift = outward.scale(surface_distance);
        const length = from.distance(to);
        var outside: ChromaSum = .{};
        var inside: ChromaSum = .{};
        var places: u32 = 0;
        var place = surface_end_fraction * length;
        while (place <= (1 - surface_end_fraction) * length) : (place += 1) {
            const on_side = from.lerp(to, place / length);
            places += 1;
            self.addChroma(&outside, on_side.add(shift));
            self.addChroma(&inside, on_side.sub(shift));
        }
        if (@as(f32, @floatFromInt(outside.count)) < min_bright_outside * @as(f32, @floatFromInt(places))) return .dark;
        if (inside.count == 0) return .other;
        const difference = @abs(outside.meanU() - inside.meanU()) + @abs(outside.meanV() - inside.meanV());
        return if (difference >= min_surface_chroma) .other else .same;
    }

    const ChromaSum = struct {
        u: u32 = 0,
        v: u32 = 0,
        count: u32 = 0,

        fn meanU(self: ChromaSum) f32 {
            return @as(f32, @floatFromInt(self.u)) / @as(f32, @floatFromInt(self.count));
        }

        fn meanV(self: ChromaSum) f32 {
            return @as(f32, @floatFromInt(self.v)) / @as(f32, @floatFromInt(self.count));
        }
    };

    /// Add the chroma at a point of the field to a sum, when the point is inside
    /// the frame and bright.
    fn addChroma(self: LineSearch, sum: *ChromaSum, point: Point) void {
        if (point.x < 0 or point.y < 0 or point.x > self.width - 1 or point.y > self.height - 1) return;
        const x: usize = @intFromFloat(@round(point.x));
        const y: usize = @intFromFloat(@round(point.y));
        if (!self.brightAt(x, y)) return;
        const mask_x = @min(x * self.factor + self.factor / 2, @min(self.paper.u.width, self.paper.v.width) - 1);
        const mask_y = @min(y * self.factor + self.factor / 2, @min(self.paper.u.height, self.paper.v.height) - 1);
        sum.u += self.paper.u.at(mask_x, mask_y);
        sum.v += self.paper.v.at(mask_x, mask_y);
        sum.count += 1;
    }

    /// True when the paper mask has the pixel in the middle of a pixel of the field.
    fn brightAt(self: LineSearch, x: usize, y: usize) bool {
        const mask_x = @min(x * self.factor + self.factor / 2, self.paper.bright.width - 1);
        const mask_y = @min(y * self.factor + self.factor / 2, self.paper.bright.height - 1);
        return self.paper.bright.at(mask_x, mask_y) != 0;
    }

    /// The part of the pixels inside a quad that the paper mask has.
    fn brightPart(self: LineSearch, corners: [4]Point) f32 {
        var inside: u32 = 0;
        var bright_count: u32 = 0;
        const rows: u32 = @intFromFloat(self.height);
        const columns: u32 = @intFromFloat(self.width);
        for (0..rows) |y| {
            const span = quadRow(corners, @floatFromInt(y), columns) orelse continue;
            for (span[0]..span[1] + 1) |x| {
                inside += 1;
                bright_count += @intFromBool(self.brightAt(x, y));
            }
        }
        if (inside == 0) return 0;
        return @as(f32, @floatFromInt(bright_count)) / @as(f32, @floatFromInt(inside));
    }

    /// The page on the other side of the fold of an open book, or null. The two
    /// pages of an open book do not lie in one plane, so their upper edges are
    /// two lines. The quad around the two pages has little support at its upper
    /// side then, and one page alone is the best quad.
    fn secondPage(self: LineSearch, first_page: PageQuad, pairs: []const [2]u8) ?PageQuad {
        const items = self.found.items;
        const middle = Quad.fromCorners(first_page.corners).center();
        var best: ?PageQuad = null;
        for (first_page.sides, 0..) |fold, k| {
            if (lines.angleBetween(items[fold].degrees, 0) > max_fold_degrees) continue;
            const fold_line = items[fold].asGeometry();
            const page_side = fold_line.signedDistance(middle);
            const along = items[fold].along();
            const page_from = first_page.corners[k].dot(along);
            const page_to = first_page.corners[(k + 1) % first_page.corners.len].dot(along);
            for (0..items.len) |outer_index| {
                const outer: u8 = @intCast(outer_index);
                if (outer == fold) continue;
                if (lines.angleBetween(items[outer].degrees, items[fold].degrees) > max_opposite_degrees) continue;
                for (pairs) |across| {
                    if (across[0] == fold or across[1] == fold or across[0] == outer or across[1] == outer) continue;
                    const candidate = self.page(.{ fold, outer }, across, if (best) |page_quad| page_quad.score else 0) orelse continue;
                    // On the other side of the fold, with about the size of the first page.
                    if (fold_line.signedDistance(Quad.fromCorners(candidate.corners).center()) * page_side >= 0) continue;
                    const ratio = candidate.area / first_page.area;
                    if (ratio > max_page_area_ratio or ratio < 1.0 / max_page_area_ratio) continue;
                    // The side of the candidate on the fold is its last side.
                    const from = candidate.corners[3].dot(along);
                    const to = candidate.corners[0].dot(along);
                    const common = @min(@max(page_from, page_to), @max(from, to)) - @max(@min(page_from, page_to), @min(from, to));
                    const longest = @max(@abs(page_to - page_from), @abs(to - from));
                    if (common < min_shared_fold * longest) continue;
                    best = candidate;
                }
            }
        }
        return best;
    }

    /// The corners of a quad of the field in pixels of the paper mask.
    fn inMask(self: LineSearch, corners: [4]Point) [4]Point {
        const factor: f32 = @floatFromInt(self.factor);
        var scaled: [4]Point = undefined;
        // The middle of a pixel of the field is the middle of its pixels of the mask.
        for (corners, &scaled) |corner, *out| out.* = .{ .x = (corner.x + 0.5) * factor - 0.5, .y = (corner.y + 0.5) * factor - 0.5 };
        return scaled;
    }
};

/// The pixels of the row `y` that lie inside a convex quad: the first and the
/// last column. Null when the row does not cross the quad inside the plane.
fn quadRow(corners: [4]Point, y: f32, columns: u32) ?[2]usize {
    var low = std.math.inf(f32);
    var high = -std.math.inf(f32);
    for (corners, 0..) |a, k| {
        const b = corners[(k + 1) % corners.len];
        // A side crosses the row when its two ends lie on the two sides of the row.
        if ((a.y <= y) == (b.y <= y)) continue;
        const x = a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y);
        low = @min(low, x);
        high = @max(high, x);
    }
    if (!(low <= high)) return null;
    const first = @ceil(@max(low, 0));
    const last = @floor(@min(high, @as(f32, @floatFromInt(columns)) - 1));
    if (!(first <= last)) return null;
    return .{ @intFromFloat(first), @intFromFloat(last) };
}

/// Set the pixels of a mask that lie inside a convex quad.
fn fillQuad(mask: Plane, corners: [4]Point) void {
    for (0..mask.height) |y| {
        const span = quadRow(corners, @floatFromInt(y), mask.width) orelse continue;
        @memset(mask.row(y)[span[0] .. span[1] + 1], raster.mask_set);
    }
}

/// Find a page by its four straight edges, and the second page of an open book
/// next to it. `field` has the steps of the frame, and `paper` its paper mask.
/// The region is the inside of the page: a hand on the page does not change it.
/// Returns null when no four lines make a page.
fn lineRegion(allocator: Allocator, field: StepField, paper: PaperMask) Allocator.Error!?OutlineRegion {
    const line_options: lines.Options = .{
        .max_lines = line_count,
        .support_strength = line_step,
        // A line has steps along a part of the short side of the frame at least.
        .min_votes = min_side_fraction * @as(f32, @floatFromInt(@min(field.width, field.height))) * line_step,
    };
    const angles = try allocator.alloc(u8, field.strength.len);
    defer allocator.free(angles);
    for (angles, field.strength, 0..) |*angle, strength, index| {
        // The line search does not read the direction of a step with no vote.
        angle.* = if (strength > line_options.min_vote_strength) field.angle(index) else 0;
    }
    const found = try lines.find(allocator, .{ .width = field.width, .height = field.height, .strength = field.strength, .angle = angles }, line_options);
    defer found.deinit(allocator);

    const search: LineSearch = .{
        .found = found,
        .paper = paper,
        .factor = field.factor,
        .width = @floatFromInt(field.width),
        .height = @floatFromInt(field.height),
    };
    // The pairs of lines that go about one way: the two opposite sides of a page.
    var pairs: [max_line_pairs][2]u8 = undefined;
    var pair_count: usize = 0;
    for (found.items, 0..) |a, first| {
        for (found.items[first + 1 ..], first + 1..) |b, second| {
            if (lines.angleBetween(a.degrees, b.degrees) > max_opposite_degrees) continue;
            pairs[pair_count] = .{ @intCast(first), @intCast(second) };
            pair_count += 1;
        }
    }
    var best: ?PageQuad = null;
    for (pairs[0..pair_count], 0..) |first, index| {
        for (pairs[index + 1 .. pair_count]) |second| {
            if (first[0] == second[0] or first[0] == second[1] or first[1] == second[0] or first[1] == second[1]) continue;
            best = search.page(first, second, if (best) |page_quad| page_quad.score else 0) orelse continue;
        }
    }
    const first_page = best orelse return null;

    const mask = try Plane.initFilled(allocator, paper.bright.width, paper.bright.height, 0);
    defer mask.deinit(allocator);
    fillQuad(mask, search.inMask(first_page.corners));
    if (search.secondPage(first_page, pairs[0..pair_count])) |second_page| fillQuad(mask, search.inMask(second_page.corners));
    const region = (try raster.largestRegion(allocator, mask)) orelse return null;
    return .{ .region = region, .step = @floatFromInt(field.factor) };
}

// endregion: line search

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
    // The outline of a region from a smaller working image has steps.
    const tolerance = options.edge_tolerance * scene.outline_step;
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
const alloc_check = @import("alloc_check.zig");

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

/// A frame of a bright room: a white wall on the left, a floor that is a little
/// darker, a thin dark line between the two, a dark hand that comes in from the
/// bottom border, and a book page on the floor. The page is as bright as the wall
/// and has the colour of cream. No brightness threshold separates the page from
/// the floor and the wall: the bright region of the frame is the wall, the floor,
/// and the page together.
const BrightRoom = struct {
    buffer: []u8,
    view: image.FrameView,
    /// The page in luma pixels of the frame.
    page: Quad,

    const wall_luma = 200;
    const floor_luma = 185;
    const line_luma = 150;
    const hand_luma = 60;
    const text_luma = 90;
    const neutral = 128;
    const cream_u = 120;
    const cream_v = 134;

    /// `scale` is 1 for a frame of 640 x 480 pixels.
    fn init(scale: u32) !BrightRoom {
        return initWithPaper(scale, cream_u, cream_v);
    }

    /// A room with a page that has the chroma `paper_u` and `paper_v`.
    fn initWithPaper(scale: u32, paper_u: u8, paper_v: u8) !BrightRoom {
        const width = 640 * scale;
        const height = 480 * scale;
        const buffer = try testing.allocator.alloc(u8, image.packedFrameSize(width, height));
        const luma_size = width * height;
        const chroma_width = width / 2;
        const chroma_size = chroma_width * (height / 2);
        const unit: f32 = @floatFromInt(scale);
        const page = Quad{
            .tl = Point.init(330 * unit, 110 * unit),
            .tr = Point.init(530 * unit, 110 * unit),
            .br = Point.init(530 * unit, 390 * unit),
            .bl = Point.init(330 * unit, 390 * unit),
        };
        const Paint = struct {
            /// The luma of a pixel, and true when the pixel is a part of the page.
            fn at(room_page: Quad, room_unit: f32, x: f32, y: f32) struct { u8, bool } {
                const fx = x / room_unit;
                const fy = y / room_unit;
                if (room_page.contains(Point.init(x, y))) {
                    // Lines of text: three rows of each twelve are dark, inside a margin.
                    const text = fx > 350 and fx < 510 and fy > 140 and fy < 360 and @mod(fy, 12) < 3;
                    return .{ if (text) text_luma else wall_luma, true };
                }
                if (fx > 560 and fy > 400) return .{ hand_luma, false };
                if (fx < 220) return .{ wall_luma, false };
                if (fx < 224) return .{ line_luma, false };
                return .{ floor_luma, false };
            }
        };
        for (0..height) |y| {
            for (0..width) |x| {
                buffer[y * width + x] = Paint.at(page, unit, @floatFromInt(x), @floatFromInt(y))[0];
            }
        }
        for (0..height / 2) |y| {
            for (0..chroma_width) |x| {
                const on_page = Paint.at(page, unit, @floatFromInt(2 * x), @floatFromInt(2 * y))[1];
                buffer[luma_size + y * chroma_width + x] = if (on_page) paper_u else neutral;
                buffer[luma_size + chroma_size + y * chroma_width + x] = if (on_page) paper_v else neutral;
            }
        }
        return .{
            .buffer = buffer,
            .view = image.FrameView.fromPacked(buffer, @intCast(width), @intCast(height), .{}),
            .page = page,
        };
    }

    fn deinit(self: BrightRoom) void {
        testing.allocator.free(self.buffer);
    }
};

test "a region inside the frame is more like a sheet of paper than a region on its border" {
    const mask = try Plane.initFilled(testing.allocator, 60, 40, 0);
    defer mask.deinit(testing.allocator);
    // A rectangle inside the frame.
    for (10..30) |y| {
        for (15..45) |x| mask.set(x, y, raster.mask_set);
    }
    const inside = (try raster.largestRegion(testing.allocator, mask)).?;
    defer inside.deinit(testing.allocator);
    try testing.expect(try paperLikeness(testing.allocator, inside) > 0.9);

    // The left half of the frame: three of its four sides are the frame border.
    @memset(mask.data, 0);
    for (0..40) |y| {
        for (0..30) |x| mask.set(x, y, raster.mask_set);
    }
    const on_border = (try raster.largestRegion(testing.allocator, mask)).?;
    defer on_border.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 0), try paperLikeness(testing.allocator, on_border));

    // A rectangle with a bite out of it, as a hand on the paper makes it.
    @memset(mask.data, 0);
    for (10..30) |y| {
        for (15..45) |x| {
            if (y >= 20 and x >= 25 and x < 40) continue;
            mask.set(x, y, raster.mask_set);
        }
    }
    const bitten = (try raster.largestRegion(testing.allocator, mask)).?;
    defer bitten.deinit(testing.allocator);
    const likeness = try paperLikeness(testing.allocator, bitten);
    try testing.expect(likeness > 0.6 and likeness < 0.85);
}

test "a book on a floor as bright as its page is found by its outline" {
    const room = try BrightRoom.init(1);
    defer room.deinit();

    // The bright region alone is the wall, the floor, and the page together.
    const bright = (try analyzeScene(testing.allocator, room.view, .{ .layout = .single, .outline_search = false })).?;
    defer bright.deinit(testing.allocator);
    try testing.expect(bright.region.touches_border);
    try testing.expect(bright.region.area > 3 * 200 * 280 / 4);

    const scene = (try analyzeScene(testing.allocator, room.view, .{ .layout = .single })).?;
    defer scene.deinit(testing.allocator);
    try testing.expect(!scene.region.touches_border);
    try testing.expectEqual(@as(f32, 1), scene.outline_step);
    const layout = (try detectLayout(testing.allocator, &scene, .{ .layout = .single })).?;
    try testing.expectEqual(LayoutKind.single, layout.kind);
    try testing.expect(!layout.clipped);
    const tolerance = 4.0;
    try expectPointNear(room.page.tl, layout.pages[0].tl, tolerance);
    try expectPointNear(room.page.tr, layout.pages[0].tr, tolerance);
    try expectPointNear(room.page.br, layout.pages[0].br, tolerance);
    try expectPointNear(room.page.bl, layout.pages[0].bl, tolerance);
}

test "the outline search works on a smaller image for a large frame" {
    // A frame of 1280 x 960 pixels: its half-size image is wider than the working size.
    const room = try BrightRoom.init(2);
    defer room.deinit();
    const scene = (try analyzeScene(testing.allocator, room.view, .{ .layout = .single })).?;
    defer scene.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 2), scene.outline_step);
    const layout = (try detectLayout(testing.allocator, &scene, .{ .layout = .single })).?;
    // The outline has steps of two pixels of the half-size image: four of the frame.
    const tolerance = 8.0;
    try expectPointNear(room.page.tl, layout.pages[0].tl, tolerance);
    try expectPointNear(room.page.br, layout.pages[0].br, tolerance);
}

test "the outline search frees its memory when an allocation fails" {
    const room = try BrightRoom.init(1);
    defer room.deinit();
    const Run = struct {
        fn run(allocator: Allocator, frame: image.FrameView) !void {
            const scene = (try analyzeScene(allocator, frame, .{ .layout = .single })) orelse return error.NoScene;
            defer scene.deinit(allocator);
            if (scene.region.touches_border) return error.OutlineNotUsed;
        }
    };
    try alloc_check.eachFailure(testing.allocator, Run.run, .{room.view});
}

test "a white book on a floor of the same colour is found when the floor is darker" {
    // The page and the floor differ in brightness only: 200 and 185.
    const room = try BrightRoom.initWithPaper(1, BrightRoom.neutral, BrightRoom.neutral);
    defer room.deinit();
    const scene = (try analyzeScene(testing.allocator, room.view, .{ .layout = .single })).?;
    defer scene.deinit(testing.allocator);
    try testing.expect(!scene.region.touches_border);
    const layout = (try detectLayout(testing.allocator, &scene, .{ .layout = .single })).?;
    const tolerance = 4.0;
    try expectPointNear(room.page.tl, layout.pages[0].tl, tolerance);
    try expectPointNear(room.page.br, layout.pages[0].br, tolerance);
}

/// A page that runs out of the frame at three sides, with a table on it: a frame
/// line, rows of text that are not sharp, and a band of free paper. The table has
/// a closed outline, and the flood from the frame border runs around it.
const TablePage = struct {
    const table_left = 90;
    const table_right = 230;
    const table_top = 50;
    const table_bottom = 170;
    const line_width = 4;
    const band_top = 100;
    const band_bottom = 124;
    const desk_top = 210;
    const text_luma = 160;
    const text_period = 8;

    fn luma(_: void, x: f32, y: f32) ?u8 {
        if (y >= desk_top) return null;
        if (x < table_left or x >= table_right or y < table_top or y >= table_bottom) return TestFrame.paper_luma;
        const on_line = x < table_left + line_width or x >= table_right - line_width or
            y < table_top + line_width or y >= table_bottom - line_width;
        if (on_line) return text_luma;
        if (y >= band_top and y < band_bottom) return TestFrame.paper_luma;
        return if (@mod(y, text_period) < text_period / 2) text_luma else TestFrame.paper_luma;
    }
};

test "a table on a page is not the paper: its own paper lies around it" {
    const frame = try TestFrame.init({}, TablePage.luma);
    defer frame.deinit();

    // With no check of the surface, the outline search takes the table for the paper.
    const loose = (try analyzeScene(testing.allocator, frame.view, .{ .min_other_surface = 0 })).?;
    defer loose.deinit(testing.allocator);
    try testing.expect(!loose.region.touches_border);
    try testing.expect(loose.region.min_x >= TablePage.table_left / 2 - 4 and loose.region.max_x <= TablePage.table_right / 2 + 4);

    // With the check, the bright region stays: the page, which runs out of the frame.
    const scene = (try analyzeScene(testing.allocator, frame.view, .{})).?;
    defer scene.deinit(testing.allocator);
    try testing.expect(scene.region.touches_border);
    try testing.expectEqual(@as(u32, 0), scene.region.min_x);
    try testing.expectEqual(@as(u32, 0), scene.region.min_y);
}

test "the directions around a region are 16 sectors of one size" {
    var seen: [surface_sectors]bool = @splat(false);
    for (0..surface_sectors) |index| {
        // The middle of each sector of 22.5 degrees.
        const angle = std.math.degreesToRadians((@as(f32, @floatFromInt(index)) + 0.5) * 360.0 / surface_sectors);
        const sector = surfaceSector(@cos(angle), @sin(angle));
        try testing.expect(sector < surface_sectors);
        try testing.expect(!seen[sector]);
        seen[sector] = true;
        // A point a little off the middle is in the same sector.
        const near = angle + std.math.degreesToRadians(8.0);
        try testing.expectEqual(sector, surfaceSector(@cos(near), @sin(near)));
    }
}

/// A frame of a white desk with one page or with the two pages of an open book.
/// The paper is a little brighter than the desk and has the colour of cream, and
/// a thin dark line goes around each page: the shadow of the sheet. Each outline
/// has a gap: a soft shadow lies there, in which the paper and the desk have one
/// brightness and one colour. A flood from the frame border gets into each page
/// through its gap, so the outline search finds no paper.
const WhiteDesk = struct {
    buffer: []u8,
    view: image.FrameView,

    const width = 640;
    const height = 480;
    const desk_luma = 185;
    const page_luma = 205;
    const outline_luma = 110;
    const thing_luma = 50;
    const text_luma = 90;
    const neutral = 128;
    /// The paper has the colour of cream.
    const paper_u = 121;
    const paper_v = 133;
    /// Half the width of the line around a page, in luma pixels of the frame, and
    /// half the width of the soft edge of that line.
    const outline_half_width = 2.5;
    const outline_soft_edge = 1.5;
    /// The soft shadow at a gap: the paper has the brightness of the desk within
    /// the first distance from the middle of the gap, and its own brightness from
    /// the second distance on, in luma pixels of the frame. The change between
    /// the two is too slow for a step.
    const shadow_core = 40.0;
    const shadow_end = 110.0;

    /// A side of a page with a gap: the part of the side from `gap_from` to
    /// `gap_to`, as fractions of its length, has no line.
    const Side = struct {
        from: Point,
        to: Point,
        gap_from: f32 = 0,
        gap_to: f32 = 0,

        fn hasGap(self: Side) bool {
            return self.gap_to > self.gap_from;
        }

        fn gapMiddle(self: Side) Point {
            return self.from.lerp(self.to, 0.5 * (self.gap_from + self.gap_to));
        }
    };

    /// One page with a tilt. The right side has a gap, a dark thing lies on a part
    /// of that side and goes out of the frame, and the page has a small block of
    /// text.
    const single_page: Quad = .{
        .tl = Point.init(300, 100),
        .tr = Point.init(480, 110),
        .br = Point.init(470, 380),
        .bl = Point.init(290, 370),
    };
    const single_sides = [_]Side{
        .{ .from = single_page.tl, .to = single_page.tr },
        .{ .from = single_page.tr, .to = single_page.br, .gap_from = 0.62, .gap_to = 0.75 },
        .{ .from = single_page.br, .to = single_page.bl },
        .{ .from = single_page.bl, .to = single_page.tl },
    };

    /// An open book. The two pages do not lie in one plane: their upper edges
    /// and their lower edges are two lines each, which meet at the fold. The
    /// outer side of each page has a gap.
    const fold_top = Point.init(310, 125);
    const fold_bottom = Point.init(310, 375);
    const left_page: Quad = .{ .tl = Point.init(150, 110), .tr = fold_top, .br = fold_bottom, .bl = Point.init(150, 390) };
    const right_page: Quad = .{ .tl = fold_top, .tr = Point.init(470, 110), .br = Point.init(470, 390), .bl = fold_bottom };
    const book_sides = [_]Side{
        .{ .from = left_page.tl, .to = left_page.tr },
        .{ .from = left_page.br, .to = left_page.bl },
        .{ .from = left_page.bl, .to = left_page.tl, .gap_from = 0.4, .gap_to = 0.65 },
        .{ .from = fold_top, .to = fold_bottom },
        .{ .from = right_page.tl, .to = right_page.tr },
        .{ .from = right_page.tr, .to = right_page.br, .gap_from = 0.4, .gap_to = 0.65 },
        .{ .from = right_page.br, .to = right_page.bl },
    };

    const Kind = enum { single, book };

    /// How much of the look of the paper is left at a point, from 0 in the middle
    /// of a soft shadow to 1 outside the shadows.
    fn paperPart(kind: Kind, point: Point) f32 {
        const sides: []const Side = if (kind == .single) &single_sides else &book_sides;
        var part: f32 = 1;
        for (sides) |side| {
            if (!side.hasGap()) continue;
            const distance = point.distance(side.gapMiddle());
            part = @min(part, std.math.clamp((distance - shadow_core) / (shadow_end - shadow_core), 0, 1));
        }
        return part;
    }

    fn luma(kind: Kind, x: f32, y: f32) u8 {
        const point = Point.init(x, y);
        const sides: []const Side = if (kind == .single) &single_sides else &book_sides;
        const paper_part = paperPart(kind, point);
        // How much of the pixel the line around a page covers: 0 to 1. The edge of
        // the line is soft, as a camera makes it: the direction of a step is then
        // the direction across the line, also for a line with a small slope.
        var line_part: f32 = 0;
        for (sides) |side| {
            const along = side.to.sub(side.from);
            const place = point.sub(side.from).dot(along) / along.dot(along);
            if (place < 0 or place > 1) continue;
            if (place > side.gap_from and place < side.gap_to) continue;
            const distance = @abs(Line.through(side.from, side.to).signedDistance(point));
            line_part = @max(line_part, std.math.clamp((outline_half_width + outline_soft_edge - distance) / (2 * outline_soft_edge), 0, 1));
        }
        var on_page = false;
        switch (kind) {
            .single => {
                if (onThing(x, y)) return thing_luma;
                if (x > 330 and x < 420 and y > 180 and y < 280 and @mod(y, 14) < 4) return text_luma;
                on_page = single_page.contains(point);
            },
            .book => {
                if (x > 560 and y > 420) return thing_luma;
                on_page = left_page.contains(point) or right_page.contains(point);
            },
        }
        const surface = if (on_page) desk_luma + paper_part * (page_luma - desk_luma) else desk_luma;
        return @intFromFloat(@round(surface + line_part * (outline_luma - surface)));
    }

    /// The dark thing of the frame with one page: it lies on the right side of
    /// the page, below the upper right corner, and goes out of the frame.
    fn onThing(x: f32, y: f32) bool {
        return x > 468 and y > 130 and y < 150;
    }

    fn onPaper(kind: Kind, x: f32, y: f32) bool {
        const point = Point.init(x, y);
        return switch (kind) {
            .single => single_page.contains(point) and !onThing(x, y),
            .book => left_page.contains(point) or right_page.contains(point),
        };
    }

    fn init(kind: Kind) !WhiteDesk {
        const buffer = try testing.allocator.alloc(u8, image.packedFrameSize(width, height));
        for (0..height) |y| {
            for (0..width) |x| buffer[y * width + x] = luma(kind, @floatFromInt(x), @floatFromInt(y));
        }
        const luma_size = width * height;
        const chroma_width = width / 2;
        const chroma_size = chroma_width * (height / 2);
        for (0..height / 2) |y| {
            for (0..chroma_width) |x| {
                const fx: f32 = @floatFromInt(2 * x);
                const fy: f32 = @floatFromInt(2 * y);
                // In a soft shadow, the paper has the colour of the desk too.
                const part = if (onPaper(kind, fx, fy)) paperPart(kind, Point.init(fx, fy)) else 0;
                buffer[luma_size + y * chroma_width + x] = @intFromFloat(@round(neutral + part * (paper_u - neutral)));
                buffer[luma_size + chroma_size + y * chroma_width + x] = @intFromFloat(@round(neutral + part * (paper_v - neutral)));
            }
        }
        return .{ .buffer = buffer, .view = image.FrameView.fromPacked(buffer, width, height, .{}) };
    }

    fn deinit(self: WhiteDesk) void {
        testing.allocator.free(self.buffer);
    }
};

test "a page on a desk as bright as the page is found by its four edges" {
    const desk = try WhiteDesk.init(.single);
    defer desk.deinit();

    // The outline search alone finds no paper: the flood gets into the page
    // through the soft shadow.
    const outline_only = (try analyzeScene(testing.allocator, desk.view, .{ .layout = .single, .line_search = false })).?;
    defer outline_only.deinit(testing.allocator);
    try testing.expect(outline_only.region.touches_border);

    const scene = (try analyzeScene(testing.allocator, desk.view, .{ .layout = .single })).?;
    defer scene.deinit(testing.allocator);
    try testing.expect(!scene.region.touches_border);
    const layout = (try detectLayout(testing.allocator, &scene, .{ .layout = .single })).?;
    try testing.expectEqual(LayoutKind.single, layout.kind);
    // The line around the page has a width of 5 pixels, and a line of the search
    // has a direction in whole degrees.
    const tolerance = 8.0;
    try expectPointNear(WhiteDesk.single_page.tl, layout.pages[0].tl, tolerance);
    try expectPointNear(WhiteDesk.single_page.tr, layout.pages[0].tr, tolerance);
    try expectPointNear(WhiteDesk.single_page.br, layout.pages[0].br, tolerance);
    try expectPointNear(WhiteDesk.single_page.bl, layout.pages[0].bl, tolerance);
}

test "the two pages of an open book are found when their upper edges are two lines" {
    const desk = try WhiteDesk.init(.book);
    defer desk.deinit();
    const scene = (try analyzeScene(testing.allocator, desk.view, .{})).?;
    defer scene.deinit(testing.allocator);
    try testing.expect(!scene.region.touches_border);
    // The region has the two pages, in pixels of the half-size image.
    const tolerance = 4;
    try testing.expect(scene.region.min_x <= 150 / 2 + tolerance);
    try testing.expect(scene.region.max_x >= 470 / 2 - tolerance);
    try testing.expect(scene.region.min_y <= 125 / 2 + tolerance);
    try testing.expect(scene.region.max_y >= 375 / 2 - tolerance);
    const layout = (try detectLayout(testing.allocator, &scene, .{})).?;
    try testing.expectEqual(LayoutKind.spread, layout.kind);
    try testing.expectApproxEqAbs(@as(f32, 310), layout.pages[0].tr.x, 8);
    try testing.expectApproxEqAbs(@as(f32, 310), layout.pages[1].tl.x, 8);
}

test "a row of a quad has the pixels between its two sides" {
    const quad = [4]Point{ Point.init(10, 5), Point.init(30, 5), Point.init(40, 25), Point.init(10, 25) };
    try testing.expectEqual(@as(?[2]usize, null), quadRow(quad, 2, 64));
    try testing.expectEqual(@as(?[2]usize, .{ 10, 35 }), quadRow(quad, 15, 64));
    // The plane ends before the quad does.
    try testing.expectEqual(@as(?[2]usize, .{ 10, 31 }), quadRow(quad, 15, 32));

    const mask = try Plane.initFilled(testing.allocator, 64, 32, 0);
    defer mask.deinit(testing.allocator);
    fillQuad(mask, quad);
    try testing.expectEqual(@as(u8, raster.mask_set), mask.at(20, 15));
    try testing.expectEqual(@as(u8, 0), mask.at(38, 15));
    try testing.expectEqual(@as(u8, 0), mask.at(20, 28));
}

test "the line search frees its memory when an allocation fails" {
    const desk = try WhiteDesk.init(.single);
    defer desk.deinit();
    const Run = struct {
        fn run(allocator: Allocator, frame: image.FrameView) !void {
            const scene = (try analyzeScene(allocator, frame, .{ .layout = .single })) orelse return error.NoScene;
            defer scene.deinit(allocator);
            if (scene.region.touches_border) return error.LinesNotUsed;
        }
    };
    try alloc_check.eachFailure(testing.allocator, Run.run, .{desk.view});
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
