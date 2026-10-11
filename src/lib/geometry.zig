//! Points, lines, quadrilaterals, and plane projective transforms.

const std = @import("std");

// region: point

pub const Point = struct {
    x: f32,
    y: f32,

    pub const zero: Point = .{ .x = 0, .y = 0 };

    pub fn init(x: f32, y: f32) Point {
        return .{ .x = x, .y = y };
    }

    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Point, b: Point) Point {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(a: Point, factor: f32) Point {
        return .{ .x = a.x * factor, .y = a.y * factor };
    }

    pub fn dot(a: Point, b: Point) f32 {
        return a.x * b.x + a.y * b.y;
    }

    /// The z component of the 3D cross product. Positive when `b` is clockwise from `a`
    /// in image coordinates (y points down).
    pub fn cross(a: Point, b: Point) f32 {
        return a.x * b.y - a.y * b.x;
    }

    pub fn length(a: Point) f32 {
        return @sqrt(a.x * a.x + a.y * a.y);
    }

    pub fn distance(a: Point, b: Point) f32 {
        return a.sub(b).length();
    }

    /// The point at fraction `t` of the way from `a` to `b`.
    pub fn lerp(a: Point, b: Point, t: f32) Point {
        return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
    }

    pub fn normalized(a: Point) Point {
        const len = a.length();
        if (len == 0) return a;
        return a.scale(1.0 / len);
    }

    /// The vector turned by a quarter turn: (x, y) becomes (-y, x).
    pub fn perpendicular(a: Point) Point {
        return .{ .x = -a.y, .y = a.x };
    }
};

// endregion: point

// region: line

/// The line `a*x + b*y + c = 0`. The normal `(a, b)` has length 1.
pub const Line = struct {
    a: f32,
    b: f32,
    c: f32,

    /// The line through two different points. The normal points to the left of the
    /// direction `p -> q` on the screen (y down), that is, it is `(dy, -dx)`.
    pub fn through(p: Point, q: Point) Line {
        const along = q.sub(p).normalized();
        const a = along.y;
        const b = -along.x;
        return .{ .a = a, .b = b, .c = -(a * p.x + b * p.y) };
    }

    /// The line through the point `p` that is perpendicular to `normal_vector`.
    pub fn fromNormal(normal_vector: Point, p: Point) Line {
        const n = normal_vector.normalized();
        return .{ .a = n.x, .b = n.y, .c = -(n.x * p.x + n.y * p.y) };
    }

    pub fn signedDistance(self: Line, p: Point) f32 {
        return self.a * p.x + self.b * p.y + self.c;
    }

    pub fn normal(self: Line) Point {
        return .{ .x = self.a, .y = self.b };
    }

    pub fn direction(self: Line) Point {
        return .{ .x = -self.b, .y = self.a };
    }

    /// The intersection point, or null when the lines are parallel.
    pub fn intersect(self: Line, other: Line) ?Point {
        const determinant = self.a * other.b - other.a * self.b;
        if (@abs(determinant) < parallel_epsilon) return null;
        return .{
            .x = (self.b * other.c - other.b * self.c) / determinant,
            .y = (other.a * self.c - self.a * other.c) / determinant,
        };
    }

    /// The closest point of the line to `p`.
    pub fn project(self: Line, p: Point) Point {
        const d = self.signedDistance(p);
        return .{ .x = p.x - self.a * d, .y = p.y - self.b * d };
    }

    const parallel_epsilon = 1e-6;
};

/// A least squares line through weighted points (total least squares, so that a
/// vertical line is as good as a horizontal one). Returns null for fewer than two
/// points or when all the points are the same.
pub fn fitLine(points: []const Point, weights: ?[]const f32) ?Line {
    if (points.len < 2) return null;
    var sum_w: f64 = 0;
    var mean_x: f64 = 0;
    var mean_y: f64 = 0;
    for (points, 0..) |p, i| {
        const w: f64 = if (weights) |ws| ws[i] else 1;
        sum_w += w;
        mean_x += w * p.x;
        mean_y += w * p.y;
    }
    if (sum_w <= 0) return null;
    mean_x /= sum_w;
    mean_y /= sum_w;

    var sxx: f64 = 0;
    var sxy: f64 = 0;
    var syy: f64 = 0;
    for (points, 0..) |p, i| {
        const w: f64 = if (weights) |ws| ws[i] else 1;
        const dx = p.x - mean_x;
        const dy = p.y - mean_y;
        sxx += w * dx * dx;
        sxy += w * dx * dy;
        syy += w * dy * dy;
    }
    if (sxx + syy <= 0) return null;

    // The direction of the line is the eigenvector of the larger eigenvalue.
    const angle = 0.5 * std.math.atan2(2 * sxy, sxx - syy);
    const dir_x: f32 = @floatCast(@cos(angle));
    const dir_y: f32 = @floatCast(@sin(angle));
    const center = Point.init(@floatCast(mean_x), @floatCast(mean_y));
    return Line.through(center, center.add(.{ .x = dir_x, .y = dir_y }));
}

// endregion: line

// region: quad

/// A quadrilateral. The corners go clockwise on the screen, from the top left.
pub const Quad = struct {
    tl: Point,
    tr: Point,
    br: Point,
    bl: Point,

    pub fn corners(self: Quad) [4]Point {
        return .{ self.tl, self.tr, self.br, self.bl };
    }

    pub fn fromCorners(c: [4]Point) Quad {
        return .{ .tl = c[0], .tr = c[1], .br = c[2], .bl = c[3] };
    }

    /// The axis-aligned rectangle with a corner at the origin.
    pub fn rect(width: f32, height: f32) Quad {
        return .{
            .tl = .{ .x = 0, .y = 0 },
            .tr = .{ .x = width, .y = 0 },
            .br = .{ .x = width, .y = height },
            .bl = .{ .x = 0, .y = height },
        };
    }

    /// The area. It is positive for a clockwise quad on the screen.
    pub fn signedArea(self: Quad) f32 {
        const c = self.corners();
        var sum: f32 = 0;
        for (0..4) |i| {
            sum += c[i].cross(c[(i + 1) % 4]);
        }
        return sum * 0.5;
    }

    pub fn area(self: Quad) f32 {
        return @abs(self.signedArea());
    }

    pub fn isConvex(self: Quad) bool {
        const c = self.corners();
        var positive: u8 = 0;
        var negative: u8 = 0;
        for (0..4) |i| {
            const a = c[i];
            const b = c[(i + 1) % 4];
            const d = c[(i + 2) % 4];
            const turn = b.sub(a).cross(d.sub(b));
            if (turn > 0) positive += 1;
            if (turn < 0) negative += 1;
        }
        return positive == 0 or negative == 0;
    }

    pub fn center(self: Quad) Point {
        const c = self.corners();
        return Point.init(
            (c[0].x + c[1].x + c[2].x + c[3].x) * 0.25,
            (c[0].y + c[1].y + c[2].y + c[3].y) * 0.25,
        );
    }

    pub fn scaled(self: Quad, factor: f32) Quad {
        return .{
            .tl = self.tl.scale(factor),
            .tr = self.tr.scale(factor),
            .br = self.br.scale(factor),
            .bl = self.bl.scale(factor),
        };
    }

    /// The mean length of the top and the bottom side.
    pub fn meanWidth(self: Quad) f32 {
        return 0.5 * (self.tl.distance(self.tr) + self.bl.distance(self.br));
    }

    /// The mean length of the left and the right side.
    pub fn meanHeight(self: Quad) f32 {
        return 0.5 * (self.tl.distance(self.bl) + self.tr.distance(self.br));
    }

    /// The largest distance between the same corners of two quads.
    pub fn maxCornerDistance(self: Quad, other: Quad) f32 {
        const a = self.corners();
        const b = other.corners();
        var largest: f32 = 0;
        for (0..4) |i| largest = @max(largest, a[i].distance(b[i]));
        return largest;
    }

    pub fn contains(self: Quad, p: Point) bool {
        const c = self.corners();
        var positive = false;
        var negative = false;
        for (0..4) |i| {
            const side = c[(i + 1) % 4].sub(c[i]).cross(p.sub(c[i]));
            if (side > 0) positive = true;
            if (side < 0) negative = true;
        }
        return !(positive and negative);
    }
};

// endregion: quad

// region: homography

/// A plane projective transform, as a row-major 3x3 matrix.
pub const Homography = struct {
    m: [9]f64,

    pub const identity: Homography = .{ .m = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } };

    pub fn apply(self: Homography, p: Point) Point {
        const x: f64 = p.x;
        const y: f64 = p.y;
        const w = self.m[6] * x + self.m[7] * y + self.m[8];
        const inverse_w = if (w != 0) 1.0 / w else 0;
        return .{
            .x = @floatCast((self.m[0] * x + self.m[1] * y + self.m[2]) * inverse_w),
            .y = @floatCast((self.m[3] * x + self.m[4] * y + self.m[5]) * inverse_w),
        };
    }

    /// The transform that applies `b` first, then `a`.
    pub fn mul(a: Homography, b: Homography) Homography {
        var out: [9]f64 = undefined;
        for (0..3) |r| {
            for (0..3) |c| {
                var sum: f64 = 0;
                for (0..3) |k| sum += a.m[r * 3 + k] * b.m[k * 3 + c];
                out[r * 3 + c] = sum;
            }
        }
        return .{ .m = out };
    }

    pub fn translation(dx: f64, dy: f64) Homography {
        return .{ .m = .{ 1, 0, dx, 0, 1, dy, 0, 0, 1 } };
    }

    pub fn scaling(sx: f64, sy: f64) Homography {
        return .{ .m = .{ sx, 0, 0, 0, sy, 0, 0, 0, 1 } };
    }

    pub fn inverse(self: Homography) ?Homography {
        const m = self.m;
        const c00 = m[4] * m[8] - m[5] * m[7];
        const c01 = m[5] * m[6] - m[3] * m[8];
        const c02 = m[3] * m[7] - m[4] * m[6];
        const determinant = m[0] * c00 + m[1] * c01 + m[2] * c02;
        if (@abs(determinant) < singular_epsilon) return null;
        const d = 1.0 / determinant;
        return .{ .m = .{
            c00 * d,
            (m[2] * m[7] - m[1] * m[8]) * d,
            (m[1] * m[5] - m[2] * m[4]) * d,
            c01 * d,
            (m[0] * m[8] - m[2] * m[6]) * d,
            (m[2] * m[3] - m[0] * m[5]) * d,
            c02 * d,
            (m[1] * m[6] - m[0] * m[7]) * d,
            (m[0] * m[4] - m[1] * m[3]) * d,
        } };
    }

    /// The transform that moves the corners of `from` to the corners of `to`.
    pub fn fromQuads(from: Quad, to: Quad) ?Homography {
        const src = from.corners();
        const dst = to.corners();
        return fit(&src, &dst, null);
    }

    /// The least squares transform that moves each `src[i]` to `dst[i]`. It needs four
    /// or more point pairs, with no three points on one line.
    ///
    /// This is the direct linear transform with normalized points. Sources:
    /// R. Hartley, "In defense of the eight-point algorithm", IEEE Transactions on
    /// Pattern Analysis and Machine Intelligence 19(6), 1997, for the normalization;
    /// R. Hartley and A. Zisserman, "Multiple View Geometry in Computer Vision",
    /// 2nd edition, 2004, section 4.4, for the method.
    pub fn fit(src: []const Point, dst: []const Point, weights: ?[]const f32) ?Homography {
        std.debug.assert(src.len == dst.len);
        if (src.len < minimum_point_pairs) return null;

        // Hartley normalization: the solve is much more stable with the points near the origin.
        const src_norm = Normalization.of(src);
        const dst_norm = Normalization.of(dst);

        // Normal equations of the 2N x 8 system with h[8] = 1.
        var ata: [unknowns][unknowns]f64 = @splat(@splat(0));
        var atb: [unknowns]f64 = @splat(0);
        for (src, dst, 0..) |s_raw, d_raw, i| {
            const w: f64 = if (weights) |ws| ws[i] else 1;
            if (w <= 0) continue;
            const s = src_norm.apply(s_raw);
            const d = dst_norm.apply(d_raw);
            const row_x = [unknowns]f64{ s[0], s[1], 1, 0, 0, 0, -d[0] * s[0], -d[0] * s[1] };
            const row_y = [unknowns]f64{ 0, 0, 0, s[0], s[1], 1, -d[1] * s[0], -d[1] * s[1] };
            for (0..unknowns) |r| {
                for (0..unknowns) |c| {
                    ata[r][c] += w * (row_x[r] * row_x[c] + row_y[r] * row_y[c]);
                }
                atb[r] += w * (row_x[r] * d[0] + row_y[r] * d[1]);
            }
        }

        const h = solveLinear(unknowns, &ata, &atb) orelse return null;
        const normalized: Homography = .{ .m = .{ h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1 } };
        const dst_inverse = dst_norm.matrix().inverse() orelse return null;
        const result = dst_inverse.mul(normalized).mul(src_norm.matrix());
        if (@abs(result.m[8]) < singular_epsilon) return result;
        var scaled_m = result.m;
        for (&scaled_m) |*value| value.* /= result.m[8];
        return .{ .m = scaled_m };
    }

    const unknowns = 8;
    const minimum_point_pairs = 4;
    const singular_epsilon = 1e-12;

    const Normalization = struct {
        center_x: f64,
        center_y: f64,
        factor: f64,

        fn of(points: []const Point) Normalization {
            var cx: f64 = 0;
            var cy: f64 = 0;
            for (points) |p| {
                cx += p.x;
                cy += p.y;
            }
            const n: f64 = @floatFromInt(points.len);
            cx /= n;
            cy /= n;
            var mean_distance: f64 = 0;
            for (points) |p| {
                const dx = p.x - cx;
                const dy = p.y - cy;
                mean_distance += @sqrt(dx * dx + dy * dy);
            }
            mean_distance /= n;
            const factor = if (mean_distance > 0) std.math.sqrt2 / mean_distance else 1;
            return .{ .center_x = cx, .center_y = cy, .factor = factor };
        }

        fn apply(self: Normalization, p: Point) [2]f64 {
            return .{ (p.x - self.center_x) * self.factor, (p.y - self.center_y) * self.factor };
        }

        fn matrix(self: Normalization) Homography {
            return .{ .m = .{
                self.factor, 0,           -self.center_x * self.factor,
                0,           self.factor, -self.center_y * self.factor,
                0,           0,           1,
            } };
        }
    };
};

/// Solve `a * x = b` for a square system with Gaussian elimination and partial
/// pivoting. The function changes `a` and `b`. Returns null for a singular matrix.
pub fn solveLinear(comptime n: usize, a: *[n][n]f64, b: *[n]f64) ?[n]f64 {
    for (0..n) |col| {
        var pivot = col;
        var largest = @abs(a[col][col]);
        for (col + 1..n) |row| {
            if (@abs(a[row][col]) > largest) {
                largest = @abs(a[row][col]);
                pivot = row;
            }
        }
        if (largest < pivot_epsilon) return null;
        if (pivot != col) {
            std.mem.swap([n]f64, &a[pivot], &a[col]);
            std.mem.swap(f64, &b[pivot], &b[col]);
        }
        for (col + 1..n) |row| {
            const factor = a[row][col] / a[col][col];
            if (factor == 0) continue;
            for (col..n) |k| a[row][k] -= factor * a[col][k];
            b[row] -= factor * b[col];
        }
    }
    var x: [n]f64 = undefined;
    var row = n;
    while (row > 0) {
        row -= 1;
        var sum = b[row];
        for (row + 1..n) |k| sum -= a[row][k] * x[k];
        x[row] = sum / a[row][row];
    }
    return x;
}

const pivot_epsilon = 1e-14;

// endregion: homography

// region: aspect ratio

/// The width divided by the height of the real rectangle that the camera sees as
/// `quad`. Source: Z. Zhang and L.-W. He, "Whiteboard scanning and image
/// enhancement", Digital Signal Processing 17(2), 2007, section 3.
/// `principal` is the principal point of the camera, normally the image center.
/// Returns null when the view has too little perspective to recover the focal length;
/// then the side lengths of the quad are the best estimate.
pub fn rectangleAspect(quad: Quad, principal: Point) ?f32 {
    // The paper names the corners m1 (bottom left), m2 (bottom right), m3 (top left),
    // m4 (top right). m1 and m4 are diagonal, m2 is along the width.
    const m1 = homogeneous(quad.bl, principal);
    const m2 = homogeneous(quad.br, principal);
    const m3 = homogeneous(quad.tl, principal);
    const m4 = homogeneous(quad.tr, principal);

    const k2_denominator = dot3(cross3(m2, m4), m3);
    const k3_denominator = dot3(cross3(m3, m4), m2);
    if (@abs(k2_denominator) < aspect_epsilon or @abs(k3_denominator) < aspect_epsilon) return null;
    const k2 = dot3(cross3(m1, m4), m3) / k2_denominator;
    const k3 = dot3(cross3(m1, m4), m2) / k3_denominator;

    const n2 = [3]f64{ k2 * m2[0] - m1[0], k2 * m2[1] - m1[1], k2 * m2[2] - m1[2] };
    const n3 = [3]f64{ k3 * m3[0] - m1[0], k3 * m3[1] - m1[1], k3 * m3[2] - m1[2] };

    // With almost no perspective, n2z and n3z are near zero and the focal length is undefined.
    if (@abs(n2[2]) < min_perspective or @abs(n3[2]) < min_perspective) return null;
    const focal_squared = -(n2[0] * n3[0] + n2[1] * n3[1]) / (n2[2] * n3[2]);
    if (!(focal_squared > 0)) return null;

    const numerator = n2[0] * n2[0] + n2[1] * n2[1] + focal_squared * n2[2] * n2[2];
    const denominator = n3[0] * n3[0] + n3[1] * n3[1] + focal_squared * n3[2] * n3[2];
    if (!(denominator > 0) or !(numerator > 0)) return null;
    return @floatCast(@sqrt(numerator / denominator));
}

fn homogeneous(p: Point, principal: Point) [3]f64 {
    return .{ p.x - principal.x, p.y - principal.y, 1 };
}

fn cross3(a: [3]f64, b: [3]f64) [3]f64 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn dot3(a: [3]f64, b: [3]f64) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

const aspect_epsilon = 1e-9;
/// Below this value of the third component, the quad is too close to a parallelogram.
const min_perspective = 1e-4;

// endregion: aspect ratio

// region: tests

const testing = std.testing;
const tolerance = 1e-3;

test "line through two points and its distances" {
    const line = Line.through(Point.init(0, 0), Point.init(10, 0));
    try testing.expectApproxEqAbs(@as(f32, 0), line.signedDistance(Point.init(5, 0)), tolerance);
    try testing.expectApproxEqAbs(@as(f32, 3), @abs(line.signedDistance(Point.init(5, 3))), tolerance);
}

test "line intersection" {
    const horizontal = Line.through(Point.init(0, 2), Point.init(10, 2));
    const vertical = Line.through(Point.init(4, 0), Point.init(4, 10));
    const p = horizontal.intersect(vertical).?;
    try testing.expectApproxEqAbs(@as(f32, 4), p.x, tolerance);
    try testing.expectApproxEqAbs(@as(f32, 2), p.y, tolerance);
    try testing.expect(horizontal.intersect(horizontal) == null);
}

test "fitLine recovers a vertical line" {
    const points = [_]Point{ Point.init(3, 0), Point.init(3, 5), Point.init(3, 9) };
    const line = fitLine(&points, null).?;
    try testing.expectApproxEqAbs(@as(f32, 0), line.signedDistance(Point.init(3, 100)), tolerance);
    try testing.expectApproxEqAbs(@as(f32, 2), @abs(line.signedDistance(Point.init(5, 1))), tolerance);
}

test "homography maps quad corners" {
    const from: Quad = .{
        .tl = Point.init(120, 80),
        .tr = Point.init(900, 130),
        .br = Point.init(860, 700),
        .bl = Point.init(60, 640),
    };
    const to = Quad.rect(400, 300);
    const h = Homography.fromQuads(from, to).?;
    const src = from.corners();
    const dst = to.corners();
    for (src, dst) |s, d| {
        const mapped = h.apply(s);
        try testing.expectApproxEqAbs(d.x, mapped.x, 1e-2);
        try testing.expectApproxEqAbs(d.y, mapped.y, 1e-2);
    }
    const back = h.inverse().?;
    const round_trip = back.apply(h.apply(Point.init(400, 300)));
    try testing.expectApproxEqAbs(@as(f32, 400), round_trip.x, 1e-2);
    try testing.expectApproxEqAbs(@as(f32, 300), round_trip.y, 1e-2);
}

test "quad area and convexity" {
    const quad = Quad.rect(4, 3);
    try testing.expectApproxEqAbs(@as(f32, 12), quad.area(), tolerance);
    try testing.expect(quad.signedArea() > 0);
    try testing.expect(quad.isConvex());
    const bow_tie: Quad = .{
        .tl = Point.init(0, 0),
        .tr = Point.init(4, 3),
        .br = Point.init(4, 0),
        .bl = Point.init(0, 3),
    };
    try testing.expect(!bow_tie.isConvex());
    try testing.expect(quad.contains(Point.init(2, 1)));
    try testing.expect(!quad.contains(Point.init(5, 1)));
}

test "rectangleAspect recovers the ratio of a tilted rectangle" {
    // A 2:3 rectangle seen by a camera with focal length 1000, after a rotation about
    // the x and the y axis.
    const focal = 1000.0;
    const half_w = 1.0;
    const half_h = 1.5;
    const world = [4][3]f64{
        .{ -half_w, -half_h, 0 },
        .{ half_w, -half_h, 0 },
        .{ half_w, half_h, 0 },
        .{ -half_w, half_h, 0 },
    };
    const tilt_x = 0.5;
    const tilt_y = -0.35;
    var image: [4]Point = undefined;
    for (world, 0..) |p, i| {
        // Rotate about x, then about y, then move away from the camera.
        const y1 = p[1] * @cos(tilt_x) - p[2] * @sin(tilt_x);
        const z1 = p[1] * @sin(tilt_x) + p[2] * @cos(tilt_x);
        const x2 = p[0] * @cos(tilt_y) + z1 * @sin(tilt_y);
        const z2 = -p[0] * @sin(tilt_y) + z1 * @cos(tilt_y) + 6.0;
        image[i] = Point.init(@floatCast(focal * x2 / z2 + 640), @floatCast(focal * y1 / z2 + 360));
    }
    const aspect = rectangleAspect(Quad.fromCorners(image), Point.init(640, 360)).?;
    try testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), aspect, 5e-3);
}

// endregion: tests
