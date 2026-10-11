//! A page map for a page that curls, as the pages of an open book do.
//!
//! The page model is the boundary-based cylinder of Y. He, P. Pan, S. Xie, J. Sun,
//! and S. Naoi, "A book dewarping system by boundary-based 3D surface
//! reconstruction", ICDAR 2013:
//!
//! - The side edges of the page are straight. The top and the bottom edge are curves.
//! - The page is a cylinder: its vertical columns are parallel in space, so in the
//!   picture they all meet at the vanishing point of the two side edges.
//! - Each point of the bottom curve has a partner on the top curve, on the line to
//!   the vanishing point. The two points are the ends of one column of the page.
//! - A longer column is nearer to the camera, so the lengths of the columns give
//!   the shape of the page in space.
//!
//! The metric part differs from the paper. The paper has two short formulas for the
//! width and the depth of a column, with a constant for the ratio of the two. They
//! are exact only for a page in the middle of the picture. This code puts each
//! column into space with a pinhole camera (R. Hartley and A. Zisserman, "Multiple
//! View Geometry in Computer Vision", 2nd edition, 2004, chapter 6): all columns
//! have the same real length and the same direction, and that fixes the depth of
//! each one. The focal length of the camera is not known. The code takes the value
//! that gives the flat page the width that the page size of the document asks for.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");
const image = @import("image.zig");

const Point = geometry.Point;
const Line = geometry.Line;

// region: outline

/// The number of points that describe each curved edge.
pub const stations = 33;

/// The outline of one page in luma pixels of a frame. The left edge runs from
/// `top[0]` to `bottom[0]`, the right edge from the last top point to the last
/// bottom point; these two edges are straight.
pub const PageOutline = struct {
    /// The top edge from the left side to the right side.
    top: [stations]Point,
    /// The bottom edge from the left side to the right side.
    bottom: [stations]Point,

    /// The outline of a page with four straight edges.
    pub fn fromQuad(corners: geometry.Quad) PageOutline {
        var outline: PageOutline = undefined;
        for (0..stations) |index| {
            const t = @as(f32, @floatFromInt(index)) / (stations - 1);
            outline.top[index] = corners.tl.lerp(corners.tr, t);
            outline.bottom[index] = corners.bl.lerp(corners.br, t);
        }
        return outline;
    }

    /// The four corners of the outline.
    pub fn quad(self: *const PageOutline) geometry.Quad {
        return .{
            .tl = self.top[0],
            .tr = self.top[stations - 1],
            .br = self.bottom[stations - 1],
            .bl = self.bottom[0],
        };
    }

    /// The largest distance of an edge point from the straight line between the two
    /// corners of its edge, in pixels. 0 for a flat page.
    pub fn maxBend(self: *const PageOutline) f32 {
        var largest: f32 = 0;
        for ([_]*const [stations]Point{ &self.top, &self.bottom }) |edge| {
            const chord = Line.through(edge[0], edge[stations - 1]);
            for (edge) |p| largest = @max(largest, @abs(chord.signedDistance(p)));
        }
        return largest;
    }
};

/// A point of a curved edge at a position between its stations. `position` runs
/// from 0 to `stations - 1`.
fn edgePoint(edge: *const [stations]Point, position: f32) Point {
    const clamped = std.math.clamp(position, 0, stations - 1);
    const index: usize = @min(@as(usize, @intFromFloat(clamped)), stations - 2);
    return edge[index].lerp(edge[index + 1], clamped - @as(f32, @floatFromInt(index)));
}

// endregion: outline

// region: map

/// The columns of the model along the bottom edge. More columns than this are not
/// needed: the edges are smooth.
const model_columns = 257;
/// The search for the focal length covers this range, as multiples of the diagonal
/// of the frame. Phone cameras are near 0.6 to 1.0.
const min_focal_factor = 0.25;
const max_focal_factor = 4.0;
const focal_search_rounds = 40;
const parallel_epsilon = 1e-9;

const Vec3 = [3]f64;

fn dot3(a: Vec3, b: Vec3) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn scale3(a: Vec3, factor: f64) Vec3 {
    return .{ a[0] * factor, a[1] * factor, a[2] * factor };
}

fn sub3(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn add3(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn normalize3(a: Vec3) Vec3 {
    const length = @sqrt(dot3(a, a));
    return if (length > 0) scale3(a, 1.0 / length) else a;
}

/// The picture of the model columns: the two ends of each column, and where the
/// columns meet.
const ColumnModel = struct {
    tops: [model_columns]Point,
    bottoms: [model_columns]Point,
    vanishing: ?Point,
    /// True when the vanishing point lies on the side of the top edge.
    vanishing_above: bool,
    principal: Point,

    /// The direction in space from the top to the bottom of a column, for a focal length.
    fn down(self: *const ColumnModel, focal: f64) Vec3 {
        if (self.vanishing) |v| {
            // The direction toward the vanishing point has a positive depth part.
            const toward = normalize3(.{ v.x - self.principal.x, v.y - self.principal.y, focal });
            return if (self.vanishing_above) scale3(toward, -1) else toward;
        }
        // The columns are parallel in the picture: they are parallel to its plane.
        const direction = self.bottoms[0].sub(self.tops[0]).normalized();
        return .{ direction.x, direction.y, 0 };
    }

    /// The top end of a column in space, for a focal length. The unit is the real
    /// length of a column. The two rays through the ends of the column must be one
    /// column length apart along the column direction: a least squares solve gives
    /// the two depths.
    fn topInSpace(self: *const ColumnModel, column: usize, focal: f64, down_direction: Vec3) Vec3 {
        const top_ray: Vec3 = .{ self.tops[column].x - self.principal.x, self.tops[column].y - self.principal.y, focal };
        const bottom_ray: Vec3 = .{ self.bottoms[column].x - self.principal.x, self.bottoms[column].y - self.principal.y, focal };
        const tt = dot3(top_ray, top_ray);
        const bb = dot3(bottom_ray, bottom_ray);
        const tb = dot3(top_ray, bottom_ray);
        const determinant = tt * bb - tb * tb;
        if (@abs(determinant) < parallel_epsilon) return scale3(top_ray, 1.0 / @max(focal, 1));
        // Minimise |b * bottom_ray - t * top_ray - down|^2 for the two depths t and b.
        const right_t = -dot3(top_ray, down_direction);
        const right_b = dot3(bottom_ray, down_direction);
        const t = (right_t * bb + tb * right_b) / determinant;
        return scale3(top_ray, t);
    }

    /// The width of the page on the paper for a focal length, in column lengths: the
    /// sum of the steps between the columns, across the column direction.
    fn paperWidth(self: *const ColumnModel, focal: f64, positions: ?*[model_columns]f64) f64 {
        const down_direction = self.down(focal);
        var sum: f64 = 0;
        var before = self.topInSpace(0, focal, down_direction);
        if (positions) |out| out[0] = 0;
        for (1..model_columns) |column| {
            const here = self.topInSpace(column, focal, down_direction);
            const step = sub3(here, before);
            const across = sub3(step, scale3(down_direction, dot3(step, down_direction)));
            sum += @sqrt(dot3(across, across));
            if (positions) |out| out[column] = sum;
            before = here;
        }
        return sum;
    }
};

pub const CurvedMap = struct {
    /// One entry for each border between two output columns: `width + 1` entries.
    /// Each is the top end of that column in space, in column lengths.
    knots: [][3]f32,
    /// The direction in space from the top to the bottom of a column.
    down: [3]f32,
    focal: f32,
    principal: Point,
    width: u32,
    height: u32,

    /// Build the map from an output page of `size` pixels to the frame. `principal`
    /// is the principal point of the camera, normally the middle of the frame, and
    /// `frame_diagonal` is the diagonal of the frame in pixels. Returns null when the
    /// outline does not fit the model: a column misses the top edge, or the outline
    /// has no area.
    pub fn init(
        allocator: Allocator,
        outline: *const PageOutline,
        size: image.Size,
        principal: Point,
        frame_diagonal: f32,
    ) Allocator.Error!?CurvedMap {
        if (size.width == 0 or size.height == 0 or !(frame_diagonal > 0)) return null;

        const left_edge = Line.through(outline.bottom[0], outline.top[0]);
        const right_edge = Line.through(outline.bottom[stations - 1], outline.top[stations - 1]);
        const up = outline.top[0].sub(outline.bottom[0]);
        if (up.length() < 1) return null;
        var model: ColumnModel = .{
            .tops = undefined,
            .bottoms = undefined,
            .vanishing = left_edge.intersect(right_edge),
            .vanishing_above = false,
            .principal = principal,
        };
        if (model.vanishing) |v| model.vanishing_above = v.sub(outline.bottom[0]).dot(up) > 0;

        for (0..model_columns) |column| {
            const position = @as(f32, @floatFromInt(column)) * (stations - 1) / (model_columns - 1);
            const bottom = edgePoint(&outline.bottom, position);
            const top = if (column == 0)
                outline.top[0]
            else if (column == model_columns - 1)
                outline.top[stations - 1]
            else blk: {
                const toward = if (model.vanishing) |v| v else bottom.add(up);
                break :blk topPartner(&outline.top, bottom, toward) orelse return null;
            };
            if (!(top.distance(bottom) > 1)) return null;
            model.bottoms[column] = bottom;
            model.tops[column] = top;
        }

        // The focal length that gives the page the width of the output. The paper
        // width grows with the focal length for a page that turns away from the
        // camera, so a bisection finds it. For a page that faces the camera the
        // width does not depend on the focal length, and any value is correct.
        const aspect = @as(f64, @floatFromInt(size.width)) / @as(f64, @floatFromInt(size.height));
        var low: f64 = min_focal_factor * frame_diagonal;
        var high: f64 = max_focal_factor * frame_diagonal;
        const width_low = model.paperWidth(low, null);
        const width_high = model.paperWidth(high, null);
        var focal: f64 = default_focal_factor * frame_diagonal;
        if (width_low < aspect and width_high > aspect) {
            for (0..focal_search_rounds) |_| {
                const middle = 0.5 * (low + high);
                if (model.paperWidth(middle, null) < aspect) low = middle else high = middle;
            }
            focal = 0.5 * (low + high);
        } else if (width_low > aspect and width_high < aspect) {
            for (0..focal_search_rounds) |_| {
                const middle = 0.5 * (low + high);
                if (model.paperWidth(middle, null) > aspect) low = middle else high = middle;
            }
            focal = 0.5 * (low + high);
        }

        // The position of each column in the flat page, 0 to 1.
        var positions: [model_columns]f64 = undefined;
        const total = model.paperWidth(focal, &positions);
        if (!(total > 0)) return null;
        for (&positions) |*position| position.* /= total;

        const down_direction = model.down(focal);
        const knots = try allocator.alloc([3]f32, size.width + 1);
        errdefer allocator.free(knots);
        var column: usize = 0;
        var before = model.topInSpace(0, focal, down_direction);
        var after = model.topInSpace(1, focal, down_direction);
        for (knots, 0..) |*knot, index| {
            const u = @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(size.width));
            while (column + 2 < model_columns and positions[column + 1] < u) {
                column += 1;
                before = after;
                after = model.topInSpace(column + 1, focal, down_direction);
            }
            const span = positions[column + 1] - positions[column];
            const fraction = if (span > 0) std.math.clamp((u - positions[column]) / span, 0, 1) else 0;
            const top = add3(before, scale3(sub3(after, before), fraction));
            knot.* = .{ @floatCast(top[0]), @floatCast(top[1]), @floatCast(top[2]) };
        }
        return .{
            .knots = knots,
            .down = .{ @floatCast(down_direction[0]), @floatCast(down_direction[1]), @floatCast(down_direction[2]) },
            .focal = @floatCast(focal),
            .principal = principal,
            .width = size.width,
            .height = size.height,
        };
    }

    pub fn deinit(self: CurvedMap, allocator: Allocator) void {
        allocator.free(self.knots);
    }

    /// The position in the frame of the output pixel (x, y). Pixel centers are at
    /// integer coordinates. Positions a little outside the page continue the map.
    pub fn apply(self: *const CurvedMap, x: f32, y: f32) Point {
        const width: f32 = @floatFromInt(self.width);
        const along = std.math.clamp(x + 0.5, 0, width);
        const index: usize = @min(@as(usize, @intFromFloat(along)), self.width - 1);
        const fraction = along - @as(f32, @floatFromInt(index));
        const first = self.knots[index];
        const second = self.knots[index + 1];
        // The point of the paper in space: the top of the column, then down the column.
        const v = (y + 0.5) / @as(f32, @floatFromInt(self.height));
        const px = first[0] + (second[0] - first[0]) * fraction + v * self.down[0];
        const py = first[1] + (second[1] - first[1]) * fraction + v * self.down[1];
        const pz = first[2] + (second[2] - first[2]) * fraction + v * self.down[2];
        const scale = if (pz > min_depth) self.focal / pz else self.focal / min_depth;
        return .{ .x = self.principal.x + px * scale, .y = self.principal.y + py * scale };
    }
};

/// The focal length when the outline does not fix it, as a multiple of the frame diagonal.
const default_focal_factor = 0.65;
/// A point nearer to the camera than this, in column lengths, is not a page point.
const min_depth = 1e-3;

/// The point where the line from `bottom` toward `toward` cuts the top edge.
fn topPartner(top: *const [stations]Point, bottom: Point, toward: Point) ?Point {
    const column = Line.through(bottom, toward);
    var best: ?Point = null;
    var best_distance = std.math.inf(f32);
    for (0..stations - 1) |index| {
        const a = top[index];
        const b = top[index + 1];
        const side_a = column.signedDistance(a);
        const side_b = column.signedDistance(b);
        // The piece of the edge crosses the column line, or touches it.
        if ((side_a > 0 and side_b > 0) or (side_a < 0 and side_b < 0)) continue;
        const span = side_a - side_b;
        const fraction = if (@abs(span) > 1e-6) side_a / span else 0.5;
        const crossing = a.lerp(b, std.math.clamp(fraction, 0, 1));
        // A curved edge can cross the line two times: the crossing nearest to the
        // bottom point is the right one.
        const distance = crossing.distance(bottom);
        if (distance < best_distance) {
            best_distance = distance;
            best = crossing;
        }
    }
    return best;
}

// endregion: map

// region: tests

const testing = std.testing;

/// A camera that looks down at a desk: a pinhole with a focal length in pixels.
const TestCamera = struct {
    focal: f64,
    center: Point,
    /// The camera is this far above the desk, in page heights.
    distance: f64,
    /// The tilt of the camera about the x axis and the y axis, in radians.
    tilt_x: f64,
    tilt_y: f64,

    /// Project a point of the scene: x to the right, y down the page, z up from the desk.
    fn project(self: TestCamera, x: f64, y: f64, z: f64) Point {
        // Rotate about x, then about y, then move the scene away from the camera.
        const y1 = y * @cos(self.tilt_x) - z * @sin(self.tilt_x);
        const z1 = y * @sin(self.tilt_x) + z * @cos(self.tilt_x);
        const x2 = x * @cos(self.tilt_y) + z1 * @sin(self.tilt_y);
        const z2 = -x * @sin(self.tilt_y) + z1 * @cos(self.tilt_y);
        const depth = self.distance - z2;
        return Point.init(
            @floatCast(self.focal * x2 / depth + self.center.x),
            @floatCast(self.focal * y1 / depth + self.center.y),
        );
    }
};

/// A page that rises toward its right side like the page of an open book: the
/// height above the desk is a smooth function of the position along the paper.
const TestPage = struct {
    width: f64,
    height: f64,
    /// The largest slope of the paper.
    max_slope: f64,

    /// The position in space of the paper point at `s` along the width (0..1) and
    /// `v` along the height (0..1). The slope of the paper grows with `s`.
    fn point(self: TestPage, s: f64, v: f64) [3]f64 {
        // Integrate the profile with small steps: dx = cos(angle) ds, dz = sin(angle) ds.
        const steps = 400;
        var x: f64 = 0;
        var z: f64 = 0;
        const target = s * self.width;
        const step = self.width / steps;
        var travelled: f64 = 0;
        while (travelled < target) {
            const length = @min(step, target - travelled);
            const middle = (travelled + 0.5 * length) / self.width;
            const angle = std.math.atan(self.max_slope * middle * middle);
            x += @cos(angle) * length;
            z += @sin(angle) * length;
            travelled += length;
        }
        return .{ x - 0.5 * self.width, (v - 0.5) * self.height, z };
    }
};

fn testOutline(camera: TestCamera, page: TestPage) PageOutline {
    var outline: PageOutline = undefined;
    // The stations lie at equal steps of the picture, not of the paper, as a
    // detector gives them. Here: at equal steps of the bottom edge parameter.
    for (0..stations) |index| {
        const s = @as(f64, @floatFromInt(index)) / (stations - 1);
        const top = page.point(s, 0);
        const bottom = page.point(s, 1);
        outline.top[index] = camera.project(top[0], top[1], top[2]);
        outline.bottom[index] = camera.project(bottom[0], bottom[1], bottom[2]);
    }
    return outline;
}

fn expectMapMatches(camera: TestCamera, page: TestPage, tolerance: f32) !void {
    const outline = testOutline(camera, page);
    const size: image.Size = .{ .width = 700, .height = 1000 };
    const map = (try CurvedMap.init(testing.allocator, &outline, size, camera.center, test_diagonal)).?;
    defer map.deinit(testing.allocator);

    var worst: f32 = 0;
    for ([_]f64{ 0.02, 0.2, 0.4, 0.6, 0.8, 0.98 }) |s| {
        for ([_]f64{ 0.03, 0.3, 0.5, 0.7, 0.97 }) |v| {
            const in_space = page.point(s, v);
            const expected = camera.project(in_space[0], in_space[1], in_space[2]);
            const actual = map.apply(
                @floatCast(s * @as(f64, @floatFromInt(size.width)) - 0.5),
                @floatCast(v * @as(f64, @floatFromInt(size.height)) - 0.5),
            );
            worst = @max(worst, expected.distance(actual));
        }
    }
    try testing.expect(worst < tolerance);
}

/// The diagonal of a 3840 x 2160 frame.
const test_diagonal = 4406.0;

const test_camera: TestCamera = .{
    .focal = 2700,
    .center = Point.init(1920, 1080),
    .distance = 1.9,
    .tilt_x = 0.22,
    .tilt_y = -0.12,
};

test "a flat page under perspective maps as a plane" {
    // 0.7 wide, 1.0 high, like the output size of the test.
    try expectMapMatches(test_camera, .{ .width = 0.7, .height = 1.0, .max_slope = 0 }, 1.0);
}

test "a page that curls toward the spine maps to its paper positions" {
    // The paper rises with a slope up to 0.9 at its right side.
    try expectMapMatches(test_camera, .{ .width = 0.7, .height = 1.0, .max_slope = 0.9 }, 1.5);
}

test "the map of a curled page differs much from the plane through its corners" {
    const page: TestPage = .{ .width = 0.7, .height = 1.0, .max_slope = 0.9 };
    const outline = testOutline(test_camera, page);
    try testing.expect(outline.maxBend() > 20);

    const size: image.Size = .{ .width = 700, .height = 1000 };
    const map = (try CurvedMap.init(testing.allocator, &outline, size, test_camera.center, test_diagonal)).?;
    defer map.deinit(testing.allocator);
    const plane = geometry.Homography.fromQuads(geometry.Quad.rect(700, 1000), outline.quad()).?;
    // In the middle of the page the plane is far from the paper.
    const in_space = page.point(0.5, 0.5);
    const truth = test_camera.project(in_space[0], in_space[1], in_space[2]);
    const from_plane = plane.apply(Point.init(350, 500));
    const from_map = map.apply(349.5, 499.5);
    try testing.expect(truth.distance(from_plane) > 15);
    try testing.expect(truth.distance(from_map) < 1.5);
}

test "an outline from a quad has no bend and gives its corners back" {
    const corners: geometry.Quad = .{
        .tl = Point.init(100, 50),
        .tr = Point.init(800, 90),
        .br = Point.init(760, 1100),
        .bl = Point.init(60, 1000),
    };
    const outline = PageOutline.fromQuad(corners);
    try testing.expectApproxEqAbs(@as(f32, 0), outline.maxBend(), 1e-2);
    const back = outline.quad();
    try testing.expectApproxEqAbs(corners.br.x, back.br.x, 1e-3);
    try testing.expectApproxEqAbs(corners.tl.y, back.tl.y, 1e-3);
}

test "an outline with no area gives no map" {
    var outline: PageOutline = undefined;
    for (0..stations) |index| {
        outline.top[index] = Point.init(@floatFromInt(index), 5);
        outline.bottom[index] = Point.init(@floatFromInt(index), 5);
    }
    try testing.expect(try CurvedMap.init(testing.allocator, &outline, .{ .width = 10, .height = 10 }, Point.init(50, 50), 100) == null);
}

// endregion: tests
