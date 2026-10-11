//! Sampling of planes at positions between pixels, and the warp of a page out of a
//! video frame.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");
const image = @import("image.zig");
const color = @import("color.zig");
const register = @import("register.zig");
const curl = @import("curl.zig");

const Point = geometry.Point;
const Quad = geometry.Quad;
const Homography = geometry.Homography;
const PlaneView = image.PlaneView;

// region: bicubic sampling

/// The weights of the four samples around a position with fraction `t` past the
/// second sample, for the Catmull-Rom cubic. The weights sum to one. The curve goes
/// through the samples, so a sample at an integer position is unchanged.
///
/// Source: E. Catmull and R. Rom, "A class of local interpolating splines", in
/// Computer Aided Geometric Design, Academic Press, 1974.
pub fn catmullRomWeights(t: f32) [4]f32 {
    const t2 = t * t;
    const t3 = t2 * t;
    return .{
        -0.5 * t3 + t2 - 0.5 * t,
        1.5 * t3 - 2.5 * t2 + 1.0,
        -1.5 * t3 + 2.0 * t2 + 0.5 * t,
        0.5 * t3 - 0.5 * t2,
    };
}

/// Bicubic sample with the edge samples repeated outside the plane.
pub fn sampleBicubic(plane: PlaneView, x: f32, y: f32) f32 {
    const floor_x = @floor(x);
    const floor_y = @floor(y);
    const weights_x = catmullRomWeights(x - floor_x);
    const weights_y = catmullRomWeights(y - floor_y);

    // The common case: the 4 x 4 samples lie inside the plane. Four samples of a
    // row go through the arithmetic at a time.
    const inside = floor_x >= 1 and floor_y >= 1 and
        floor_x + 2 < @as(f32, @floatFromInt(plane.width)) and floor_y + 2 < @as(f32, @floatFromInt(plane.height));
    if (inside) {
        const first_x = @as(usize, @intFromFloat(floor_x)) - 1;
        const first_y = @as(usize, @intFromFloat(floor_y)) - 1;
        var offset = first_y * plane.stride + first_x;
        var columns: Taps = @splat(0);
        inline for (0..taps) |tap| {
            const samples: @Vector(taps, u8) = plane.data[offset..][0..taps].*;
            columns += @as(Taps, @floatFromInt(samples)) * @as(Taps, @splat(weights_y[tap]));
            offset += plane.stride;
        }
        return @reduce(.Add, columns * @as(Taps, weights_x));
    }

    const base_x: i32 = @intFromFloat(std.math.clamp(floor_x, coordinate_min, coordinate_max));
    const base_y: i32 = @intFromFloat(std.math.clamp(floor_y, coordinate_min, coordinate_max));
    const last_x: i32 = @intCast(plane.width - 1);
    const last_y: i32 = @intCast(plane.height - 1);

    var columns: [taps]usize = undefined;
    for (&columns, 0..) |*column, tap| {
        column.* = @intCast(std.math.clamp(base_x - 1 + @as(i32, @intCast(tap)), 0, last_x));
    }
    var sum: f32 = 0;
    for (0..taps) |tap| {
        const row_index: usize = @intCast(std.math.clamp(base_y - 1 + @as(i32, @intCast(tap)), 0, last_y));
        const row = plane.data[row_index * plane.stride ..];
        const row_sum = weights_x[0] * @as(f32, @floatFromInt(row[columns[0]])) +
            weights_x[1] * @as(f32, @floatFromInt(row[columns[1]])) +
            weights_x[2] * @as(f32, @floatFromInt(row[columns[2]])) +
            weights_x[3] * @as(f32, @floatFromInt(row[columns[3]]));
        sum += weights_y[tap] * row_sum;
    }
    return sum;
}

/// The number of samples of the cubic on one axis.
const taps = 4;
const Taps = @Vector(taps, f32);

/// Bilinear sample with the edge samples repeated outside the plane. Sample centers
/// are at integer coordinates. The same result as `PlaneView.sample`, with a short
/// way for a position inside the plane.
fn sampleBilinear(plane: PlaneView, x: f32, y: f32) f32 {
    const inside = x >= 0 and y >= 0 and
        x + 1 < @as(f32, @floatFromInt(plane.width)) and y + 1 < @as(f32, @floatFromInt(plane.height));
    if (!inside) return plane.sample(x, y);
    const x0: usize = @intFromFloat(x);
    const y0: usize = @intFromFloat(y);
    const fx = x - @as(f32, @floatFromInt(x0));
    const fy = y - @as(f32, @floatFromInt(y0));
    const top_row = plane.data[y0 * plane.stride + x0 ..][0..2];
    const bottom_row = plane.data[(y0 + 1) * plane.stride + x0 ..][0..2];
    const top = @as(f32, @floatFromInt(top_row[0])) * (1 - fx) + @as(f32, @floatFromInt(top_row[1])) * fx;
    const bottom = @as(f32, @floatFromInt(bottom_row[0])) * (1 - fx) + @as(f32, @floatFromInt(bottom_row[1])) * fx;
    return top * (1 - fy) + bottom * fy;
}

/// Coordinates are clamped to this range before the conversion to an integer.
const coordinate_min = -1.0e6;
const coordinate_max = 1.0e6;

// endregion: bicubic sampling

// region: page warp

/// Where the chroma samples of a 4:2:0 frame lie. Video codecs put a chroma sample
/// at the column of each second luma sample, and between two luma rows.
const chroma_siting = struct {
    const scale = 0.5;
    const offset_x = 0.0;
    const offset_y = -0.25;
};

/// A map from a pixel of the output page to a position in the luma plane of a frame.
pub const PageMap = struct {
    /// From output pixel centers to luma coordinates of the frame, for a flat page.
    to_frame: Homography,
    /// The map of a page that curls. When set, it takes the place of `to_frame`.
    /// The caller owns it and keeps it alive while the map is in use.
    curved: ?*const curl.CurvedMap = null,

    /// The map that puts the corners of `quad` (luma coordinates of the frame) on
    /// the corners of an output image of the given size.
    pub fn init(quad: Quad, size: image.Size) ?PageMap {
        // Output pixel (i, j) has its center at (i + 0.5, j + 0.5) of the page rectangle.
        const to_frame = Homography.fromQuads(
            Quad.rect(@floatFromInt(size.width), @floatFromInt(size.height)),
            quad,
        ) orelse return null;
        return .{ .to_frame = to_frame.mul(Homography.translation(half_pixel, half_pixel)) };
    }

    pub fn apply(self: PageMap, x: f32, y: f32) Point {
        if (self.curved) |map| return map.apply(x, y);
        return self.to_frame.apply(Point.init(x, y));
    }

    const half_pixel = 0.5;
};

/// Where the content of a page pixel of the reference frame lies in the page of
/// another frame: a plane transform, then a smooth field of small shifts.
pub const Alignment = struct {
    transform: Homography = Homography.identity,
    grid: ?register.ShiftGrid = null,

    pub fn apply(self: Alignment, p: Point) Point {
        const moved = self.transform.apply(p);
        if (self.grid) |grid| return moved.add(grid.sample(p));
        return moved;
    }
};

/// Gives the position in the frame of each output pixel of a warp: the output pixel
/// `p` shows the frame at `map(alignment(p))`. The pixels of a row come in rising
/// order, so the sums of a plane transform change by a constant step.
///
/// The sums are 64-bit: they hold the steps of a whole row without a visible
/// error. The division of each pixel is 32-bit: its error is far below a hundredth
/// of a pixel for a frame of some thousand pixels, and it is faster.
const Walk = struct {
    map: PageMap,
    alignment: Alignment,
    /// The transform whose sums the rows step through. With no shift grid it goes
    /// from the output pixel to the frame in one step. With a grid it is the
    /// transform of the alignment, and `to_frame` comes after the shift.
    stepped: [9]f64,
    /// For each output column: the tiles of the shift grid around it. Empty when
    /// the alignment has no grid.
    columns: []register.ShiftGrid.AxisWeight,
    /// The shifts of the grid at the current row, one per tile column.
    row_shifts: []Point,
    /// `map.to_frame` as 32-bit values, for the step after the shift.
    to_frame: [9]f32,

    fn init(allocator: Allocator, map: PageMap, alignment: Alignment, width: usize) Allocator.Error!Walk {
        var walk: Walk = .{
            .map = map,
            .alignment = alignment,
            .stepped = map.to_frame.mul(alignment.transform).m,
            .columns = &.{},
            .row_shifts = &.{},
            .to_frame = undefined,
        };
        for (&walk.to_frame, map.to_frame.m) |*narrow, value| narrow.* = @floatCast(value);
        const grid = alignment.grid orelse return walk;
        walk.stepped = alignment.transform.m;
        walk.columns = try allocator.alloc(register.ShiftGrid.AxisWeight, width);
        errdefer allocator.free(walk.columns);
        for (walk.columns, 0..) |*weight, column| weight.* = grid.axisWeight(@floatFromInt(column), grid.tiles_wide);
        walk.row_shifts = try allocator.alloc(Point, grid.tiles_wide);
        return walk;
    }

    fn deinit(self: Walk, allocator: Allocator) void {
        allocator.free(self.columns);
        allocator.free(self.row_shifts);
    }

    /// Start a row of output pixels.
    fn row(self: *Walk, y: usize) Row {
        const v: f64 = @floatFromInt(y);
        if (self.alignment.grid) |grid| {
            const weight = grid.axisWeight(@floatFromInt(y), grid.tiles_high);
            const top = grid.shifts[weight.first * grid.tiles_wide ..][0..grid.tiles_wide];
            const bottom = grid.shifts[weight.second * grid.tiles_wide ..][0..grid.tiles_wide];
            for (self.row_shifts, top, bottom) |*shift, above, below| shift.* = above.lerp(below, weight.fraction);
        }
        const m = self.stepped;
        return .{
            .walk = self,
            .y = @floatFromInt(y),
            .sum_x = m[1] * v + m[2],
            .sum_y = m[4] * v + m[5],
            .sum_w = m[7] * v + m[8],
        };
    }

    const Row = struct {
        walk: *const Walk,
        y: f32,
        /// The three sums of `Walk.stepped` at the next column.
        sum_x: f64,
        sum_y: f64,
        sum_w: f64,

        /// The position in the frame of the pixel at `column`. Call it one time for
        /// each column, from column 0 up.
        inline fn next(self: *Row, column: usize) Point {
            const walk = self.walk;
            if (walk.map.curved) |curved| {
                const in_page = walk.alignment.apply(Point.init(@floatFromInt(column), self.y));
                return curved.apply(in_page.x, in_page.y);
            }
            const w: f32 = @floatCast(self.sum_w);
            const inverse: f32 = if (w != 0) 1.0 / w else 0;
            var p: Point = .{
                .x = @as(f32, @floatCast(self.sum_x)) * inverse,
                .y = @as(f32, @floatCast(self.sum_y)) * inverse,
            };
            const m = walk.stepped;
            self.sum_x += m[0];
            self.sum_y += m[3];
            self.sum_w += m[6];
            if (walk.columns.len == 0) return p;

            const weight = walk.columns[column];
            p = p.add(walk.row_shifts[weight.first].lerp(walk.row_shifts[weight.second], weight.fraction));
            const f = walk.to_frame;
            const frame_w = f[6] * p.x + f[7] * p.y + f[8];
            const frame_inverse: f32 = if (frame_w != 0) 1.0 / frame_w else 0;
            return .{
                .x = (f[0] * p.x + f[1] * p.y + f[2]) * frame_inverse,
                .y = (f[3] * p.x + f[4] * p.y + f[5]) * frame_inverse,
            };
        }
    };
};

/// Warp a page out of a frame into an RGB image with values in 0..1. Positions
/// outside the frame take the nearest pixel of the frame; `outside`, when given,
/// gets `raster.mask_set` for each of those pixels and 0 for the others.
pub fn warpPage(allocator: Allocator, frame: image.FrameView, map: PageMap, size: image.Size, outside: ?image.Plane) Allocator.Error!image.RgbF32 {
    return warpPageAligned(allocator, frame, map, .{}, size, outside);
}

/// Warp a page out of a frame as `warpPage` does, but for a frame that is aligned to
/// a reference: the output pixel `p` shows the frame at `map(alignment(p))`.
pub fn warpPageAligned(
    allocator: Allocator,
    frame: image.FrameView,
    map: PageMap,
    alignment: Alignment,
    size: image.Size,
    outside: ?image.Plane,
) Allocator.Error!image.RgbF32 {
    const out = try image.RgbF32.init(allocator, size.width, size.height);
    errdefer out.deinit(allocator);
    var walk = try Walk.init(allocator, map, alignment, size.width);
    defer walk.deinit(allocator);
    const converter = color.YuvToRgb.init(frame.colorimetry);
    const max_x: f32 = @floatFromInt(frame.y.width - 1);
    const max_y: f32 = @floatFromInt(frame.y.height - 1);
    for (0..size.height) |row| {
        const target = out.data[row * size.width * image.rgb_channels ..];
        var positions = walk.row(row);
        for (0..size.width) |column| {
            const p = positions.next(column);
            if (outside) |mask| {
                const is_outside = !(p.x >= 0 and p.y >= 0 and p.x <= max_x and p.y <= max_y);
                mask.data[row * size.width + column] = @intFromBool(is_outside);
            }
            const luma = sampleBicubic(frame.y, p.x, p.y);
            const chroma_x = p.x * chroma_siting.scale + chroma_siting.offset_x;
            const chroma_y = p.y * chroma_siting.scale + chroma_siting.offset_y;
            target[column * image.rgb_channels ..][0..image.rgb_channels].* =
                converter.convert(luma, sampleBilinear(frame.u, chroma_x, chroma_y), sampleBilinear(frame.v, chroma_x, chroma_y));
        }
    }
    return out;
}

/// Warp only the luma of a page, with bilinear sampling, into an 8-bit plane. Used
/// for small pictures of a page: comparison and registration.
pub fn warpLuma(allocator: Allocator, luma: PlaneView, map: PageMap, size: image.Size) Allocator.Error!image.Plane {
    return warpLumaAligned(allocator, luma, map, .{}, size);
}

/// Warp the luma of a page as `warpLuma` does, for a frame that is aligned to a
/// reference: the output pixel `p` shows the frame at `map(alignment(p))`.
pub fn warpLumaAligned(
    allocator: Allocator,
    luma: PlaneView,
    map: PageMap,
    alignment: Alignment,
    size: image.Size,
) Allocator.Error!image.Plane {
    const out = try image.Plane.init(allocator, size.width, size.height);
    errdefer out.deinit(allocator);
    var walk = try Walk.init(allocator, map, alignment, size.width);
    defer walk.deinit(allocator);
    for (0..size.height) |row| {
        var positions = walk.row(row);
        for (out.row(row), 0..) |*value, column| {
            const p = positions.next(column);
            value.* = @intFromFloat(std.math.clamp(sampleBilinear(luma, p.x, p.y) + 0.5, 0, 255));
        }
    }
    return out;
}

// endregion: page warp

// region: tests

const testing = std.testing;

test "Catmull-Rom weights sum to one and keep the samples" {
    for ([_]f32{ 0, 0.25, 0.5, 0.9 }) |t| {
        const weights = catmullRomWeights(t);
        try testing.expectApproxEqAbs(@as(f32, 1), weights[0] + weights[1] + weights[2] + weights[3], 1e-5);
    }
    const at_sample = catmullRomWeights(0);
    try testing.expectApproxEqAbs(@as(f32, 1), at_sample[1], 1e-6);
}

test "bicubic sample of a linear ramp is exact" {
    var data: [8 * 8]u8 = undefined;
    for (0..8) |y| {
        for (0..8) |x| data[y * 8 + x] = @intCast(10 * x + 5 * y);
    }
    const plane: PlaneView = .{ .data = &data, .width = 8, .height = 8, .stride = 8 };
    try testing.expectApproxEqAbs(@as(f32, 10 * 3.5 + 5 * 2.25), sampleBicubic(plane, 3.5, 2.25), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 30), sampleBicubic(plane, 3, 0), 1e-3);
}

test "warp of an axis-aligned quad copies the pixels" {
    const width = 16;
    const height = 12;
    const buffer = try testing.allocator.alloc(u8, image.packedFrameSize(width, height));
    defer testing.allocator.free(buffer);
    @memset(buffer, 128);
    for (0..height) |y| {
        for (0..width) |x| buffer[y * width + x] = @intCast(16 + 10 * x + 3 * y);
    }
    const frame = image.FrameView.fromPacked(buffer, width, height, .{ .range = .full, .matrix = .bt709 });

    // The quad covers the luma pixels 4..11 by 2..9: its corners lie on pixel borders.
    const quad: Quad = .{
        .tl = Point.init(3.5, 1.5),
        .tr = Point.init(11.5, 1.5),
        .br = Point.init(11.5, 9.5),
        .bl = Point.init(3.5, 9.5),
    };
    const size: image.Size = .{ .width = 8, .height = 8 };
    const map = PageMap.init(quad, size).?;
    const outside = try image.Plane.init(testing.allocator, size.width, size.height);
    defer outside.deinit(testing.allocator);
    const page = try warpPage(testing.allocator, frame, map, size, outside);
    for (outside.data) |value| try testing.expectEqual(@as(u8, 0), value);
    defer page.deinit(testing.allocator);
    for (0..size.height) |y| {
        for (0..size.width) |x| {
            const expected = @as(f32, @floatFromInt(buffer[(y + 2) * width + (x + 4)])) / 255.0;
            try testing.expectApproxEqAbs(expected, page.pixel(x, y)[1], 2e-3);
        }
    }
}

// endregion: tests
