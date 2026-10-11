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
    const base_x: i32 = @intFromFloat(std.math.clamp(floor_x, coordinate_min, coordinate_max));
    const base_y: i32 = @intFromFloat(std.math.clamp(floor_y, coordinate_min, coordinate_max));
    const last_x: i32 = @intCast(plane.width - 1);
    const last_y: i32 = @intCast(plane.height - 1);

    var columns: [4]usize = undefined;
    for (&columns, 0..) |*column, tap| {
        column.* = @intCast(std.math.clamp(base_x - 1 + @as(i32, @intCast(tap)), 0, last_x));
    }
    var sum: f32 = 0;
    for (0..4) |tap| {
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

/// Warp a page out of a frame into an RGB image with values in 0..1. Positions
/// outside the frame take the nearest pixel of the frame; `outside`, when given,
/// gets `raster.mask_set` for each of those pixels and 0 for the others.
pub fn warpPage(allocator: Allocator, frame: image.FrameView, map: PageMap, size: image.Size, outside: ?image.Plane) Allocator.Error!image.RgbF32 {
    // The fast loop below is for a plane. A curved page takes the general loop.
    if (map.curved != null) return warpPageAligned(allocator, frame, map, .{}, size, outside);
    const out = try image.RgbF32.init(allocator, size.width, size.height);
    const max_x: f32 = @floatFromInt(frame.y.width - 1);
    const max_y: f32 = @floatFromInt(frame.y.height - 1);
    const converter = color.YuvToRgb.init(frame.colorimetry);
    const m = map.to_frame.m;
    for (0..size.height) |row| {
        const v: f64 = @floatFromInt(row);
        // The three sums of the homography change by a constant step along a row.
        var numerator_x = m[1] * v + m[2];
        var numerator_y = m[4] * v + m[5];
        var denominator = m[7] * v + m[8];
        const target = out.data[row * size.width * image.rgb_channels ..];
        for (0..size.width) |column| {
            const inverse = 1.0 / denominator;
            const x: f32 = @floatCast(numerator_x * inverse);
            const y: f32 = @floatCast(numerator_y * inverse);
            if (outside) |mask| {
                const is_outside = x < 0 or y < 0 or x > max_x or y > max_y;
                mask.data[row * size.width + column] = @intFromBool(is_outside);
            }
            const luma = sampleBicubic(frame.y, x, y);
            const chroma_x = x * chroma_siting.scale + chroma_siting.offset_x;
            const chroma_y = y * chroma_siting.scale + chroma_siting.offset_y;
            const rgb = converter.convert(luma, frame.u.sample(chroma_x, chroma_y), frame.v.sample(chroma_x, chroma_y));
            target[column * image.rgb_channels ..][0..image.rgb_channels].* = rgb;
            numerator_x += m[0];
            numerator_y += m[3];
            denominator += m[6];
        }
    }
    return out;
}

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
    const converter = color.YuvToRgb.init(frame.colorimetry);
    const max_x: f32 = @floatFromInt(frame.y.width - 1);
    const max_y: f32 = @floatFromInt(frame.y.height - 1);
    for (0..size.height) |row| {
        const target = out.data[row * size.width * image.rgb_channels ..];
        for (0..size.width) |column| {
            const in_page = alignment.apply(Point.init(@floatFromInt(column), @floatFromInt(row)));
            const p = map.apply(in_page.x, in_page.y);
            if (outside) |mask| {
                const is_outside = !(p.x >= 0 and p.y >= 0 and p.x <= max_x and p.y <= max_y);
                mask.data[row * size.width + column] = @intFromBool(is_outside);
            }
            const luma = sampleBicubic(frame.y, p.x, p.y);
            const chroma_x = p.x * chroma_siting.scale + chroma_siting.offset_x;
            const chroma_y = p.y * chroma_siting.scale + chroma_siting.offset_y;
            target[column * image.rgb_channels ..][0..image.rgb_channels].* =
                converter.convert(luma, frame.u.sample(chroma_x, chroma_y), frame.v.sample(chroma_x, chroma_y));
        }
    }
    return out;
}

/// Warp only the luma of a page, with bilinear sampling, into an 8-bit plane. Used
/// for small pictures of a page: comparison and registration.
pub fn warpLuma(allocator: Allocator, luma: PlaneView, map: PageMap, size: image.Size) Allocator.Error!image.Plane {
    const out = try image.Plane.init(allocator, size.width, size.height);
    for (0..size.height) |row| {
        const target = out.row(row);
        for (target, 0..) |*value, column| {
            const p = map.apply(@floatFromInt(column), @floatFromInt(row));
            value.* = @intFromFloat(std.math.clamp(luma.sample(p.x, p.y) + 0.5, 0, 255));
        }
    }
    return out;
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
    for (0..size.height) |row| {
        const target = out.row(row);
        for (target, 0..) |*value, column| {
            const in_page = alignment.apply(Point.init(@floatFromInt(column), @floatFromInt(row)));
            const p = map.apply(in_page.x, in_page.y);
            value.* = @intFromFloat(std.math.clamp(luma.sample(p.x, p.y) + 0.5, 0, 255));
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
