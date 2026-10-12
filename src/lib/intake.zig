//! The intake: bring a frame of a camera or a video decoder into the form that the
//! library works on, a packed planar YUV 4:2:0 frame in the upright view.
//!
//! A phone gives a frame with a row stride, with the two chroma channels in one
//! plane (NV12, NV21) or in two planes, and often on its side: the sensor is wide,
//! and the user holds the phone upright. The functions here copy such a frame,
//! make the small frame for the analysis, and turn a frame to the upright view.

const std = @import("std");
const image = @import("image.zig");

// region: source frame

/// The turn, clockwise, that brings a frame of the source to the upright view. This
/// is the meaning of the rotation of a video track and of a camera frame on Android.
pub const Rotation = enum(u8) {
    none = 0,
    quarter = 1,
    half = 2,
    three_quarters = 3,

    const degrees_per_quarter = 90;
    const quarters_per_turn = 4;

    /// The rotation for an angle in degrees. Null when the angle is no multiple of 90.
    pub fn fromDegrees(degrees: i32) ?Rotation {
        if (@rem(degrees, degrees_per_quarter) != 0) return null;
        const quarters = @mod(@divTrunc(degrees, degrees_per_quarter), quarters_per_turn);
        return @fromBackingInt(@intCast(@as(u8, @intCast(quarters))));
    }

    /// True when the rotation swaps the width and the height.
    pub fn swapsSides(self: Rotation) bool {
        return self == .quarter or self == .three_quarters;
    }

    /// The size of a frame of `size` after the rotation.
    pub fn apply(self: Rotation, size: image.Size) image.Size {
        if (self.swapsSides()) return .{ .width = size.height, .height = size.width };
        return size;
    }
};

/// A read-only YUV 4:2:0 frame as a camera or a decoder gives it.
pub const Source = struct {
    width: u32,
    height: u32,
    y: []const u8,
    /// The distance in bytes between two rows of the luma plane.
    y_stride: u32,
    u: []const u8,
    v: []const u8,
    /// The distance in bytes between two rows of a chroma plane.
    chroma_stride: u32,
    /// The distance in bytes between two samples of a chroma row: 1 for a plane of
    /// its own, 2 when the U and the V samples take turns in one plane.
    chroma_step: u32 = 1,

    /// A frame of the library as a source. The two chroma planes must have one stride.
    pub fn fromFrame(frame: image.FrameView) Source {
        std.debug.assert(frame.u.stride == frame.v.stride);
        return .{
            .width = frame.y.width,
            .height = frame.y.height,
            .y = frame.y.data,
            .y_stride = frame.y.stride,
            .u = frame.u.data,
            .v = frame.v.data,
            .chroma_stride = frame.u.stride,
        };
    }

    pub fn size(self: Source) image.Size {
        return .{ .width = self.width, .height = self.height };
    }

    /// The smallest number of bytes of the luma plane.
    pub fn lumaBytes(self: Source) usize {
        return planeBytes(self.width, self.height, self.y_stride, 1);
    }

    /// The smallest number of bytes of a chroma plane.
    pub fn chromaBytes(self: Source) usize {
        return planeBytes(image.chromaDimension(self.width), image.chromaDimension(self.height), self.chroma_stride, self.chroma_step);
    }

    /// True when the strides and the planes are large enough for the frame size.
    pub fn isValid(self: Source) bool {
        if (self.width == 0 or self.height == 0) return false;
        if (self.chroma_step == 0) return false;
        const chroma_width = image.chromaDimension(self.width);
        if (self.y_stride < self.width) return false;
        if (self.chroma_stride < (chroma_width - 1) * self.chroma_step + 1) return false;
        return self.y.len >= self.lumaBytes() and self.u.len >= self.chromaBytes() and self.v.len >= self.chromaBytes();
    }
};

/// The bytes from the first sample of a plane to its last sample.
fn planeBytes(width: u32, height: u32, stride: u32, step: u32) usize {
    if (width == 0 or height == 0) return 0;
    return @as(usize, stride) * (height - 1) + @as(usize, step) * (width - 1) + 1;
}

// endregion: source frame

// region: copy

/// Copy a frame of the source into a packed frame: the Y plane, then U, then V,
/// with no padding. `target` has `image.packedFrameSize` bytes.
pub fn copy(target: []u8, source: Source) void {
    const width: usize = source.width;
    const height: usize = source.height;
    const chroma_width: usize = image.chromaDimension(source.width);
    const chroma_height: usize = image.chromaDimension(source.height);
    std.debug.assert(target.len >= width * height + 2 * chroma_width * chroma_height);

    var offset: usize = 0;
    for (0..height) |row| {
        @memcpy(target[offset..][0..width], source.y[row * source.y_stride ..][0..width]);
        offset += width;
    }
    for ([_][]const u8{ source.u, source.v }) |plane| {
        for (0..chroma_height) |row| {
            const line = plane[row * source.chroma_stride ..];
            const out = target[offset..][0..chroma_width];
            if (source.chroma_step == 1) {
                @memcpy(out, line[0..chroma_width]);
            } else {
                for (out, 0..) |*value, column| value.* = line[column * source.chroma_step];
            }
            offset += chroma_width;
        }
    }
}

// endregion: copy

// region: shrink

/// The largest factor of `shrink`: the sum of the samples of one cell must fit the
/// 16 bits of a lane.
pub const max_shrink_factor = 16;

/// The factor that brings the short side of a frame to `short_side` pixels or a
/// little more. The analysis works on a frame with a short side of about 540 pixels.
pub fn shrinkFactor(size: image.Size, short_side: u32) u32 {
    const source_short = @min(size.width, size.height);
    return std.math.clamp(source_short / @max(short_side, 1), 1, max_shrink_factor);
}

/// The size of the frame that `shrink` makes. The two sides are even.
pub fn shrunkSize(size: image.Size, factor: u32) image.Size {
    const even_mask = ~@as(u32, 1);
    return .{ .width = (size.width / factor) & even_mask, .height = (size.height / factor) & even_mask };
}

/// Make a small packed frame: each sample is the mean of `factor` x `factor` samples
/// of the source (a box filter). `target` has `image.packedFrameSize` bytes for
/// `shrunkSize`. The columns and the rows of the source that fill no whole cell are
/// dropped.
pub fn shrink(target: []u8, source: Source, factor: u32) void {
    std.debug.assert(factor >= 1 and factor <= max_shrink_factor);
    const small = shrunkSize(source.size(), factor);
    const luma_bytes = small.pixels();
    const chroma_width = small.width / 2;
    const chroma_height = small.height / 2;
    const chroma_bytes = @as(usize, chroma_width) * chroma_height;
    std.debug.assert(target.len >= luma_bytes + 2 * chroma_bytes);

    boxReduce(target[0..luma_bytes], small.width, small.height, source.y, source.y_stride, 1, factor);
    boxReduce(target[luma_bytes..][0..chroma_bytes], chroma_width, chroma_height, source.u, source.chroma_stride, source.chroma_step, factor);
    boxReduce(target[luma_bytes + chroma_bytes ..][0..chroma_bytes], chroma_width, chroma_height, source.v, source.chroma_stride, source.chroma_step, factor);
}

const sum_lanes = 16;
/// The widest row of `boxReduce` that needs no memory from the caller.
const max_sum_columns = 8192;

/// Write the means of `factor` x `factor` cells of a plane into `target`. `step` is
/// the distance between two samples of a row of the source.
fn boxReduce(target: []u8, width: u32, height: u32, data: []const u8, stride: u32, step: u32, factor: u32) void {
    const columns: usize = @as(usize, width) * factor;
    std.debug.assert(columns <= max_sum_columns);
    var sums: [max_sum_columns]u16 = undefined;
    const cell_samples: u32 = factor * factor;
    const half = cell_samples / 2;

    for (0..height) |out_row| {
        @memset(sums[0..columns], 0);
        for (0..factor) |sub_row| {
            const line = data[(out_row * factor + sub_row) * stride ..];
            var column: usize = 0;
            if (step == 1) {
                // The sum of the rows of a cell, 16 columns at a time.
                while (column + sum_lanes <= columns) : (column += sum_lanes) {
                    const samples: @Vector(sum_lanes, u8) = line[column..][0..sum_lanes].*;
                    const before: @Vector(sum_lanes, u16) = sums[column..][0..sum_lanes].*;
                    sums[column..][0..sum_lanes].* = before + @as(@Vector(sum_lanes, u16), samples);
                }
            }
            while (column < columns) : (column += 1) sums[column] += line[column * step];
        }
        const out = target[out_row * width ..][0..width];
        for (out, 0..) |*value, out_column| {
            var sum: u32 = 0;
            for (sums[out_column * factor ..][0..factor]) |part| sum += part;
            value.* = @intCast((sum + half) / cell_samples);
        }
    }
}

// endregion: shrink

// region: rotate

/// Turn a frame to the upright view. `target` is a packed frame of the size
/// `rotation.apply` gives. With `Rotation.none` this is a copy.
pub fn rotate(target: []u8, frame: image.FrameView, rotation: Rotation) void {
    const size = rotation.apply(.{ .width = frame.width(), .height = frame.height() });
    const luma_bytes = size.pixels();
    const chroma_width = image.chromaDimension(size.width);
    const chroma_height = image.chromaDimension(size.height);
    const chroma_bytes = @as(usize, chroma_width) * chroma_height;
    std.debug.assert(target.len >= luma_bytes + 2 * chroma_bytes);

    rotatePlane(target[0..luma_bytes], size.width, size.height, frame.y, rotation);
    rotatePlane(target[luma_bytes..][0..chroma_bytes], chroma_width, chroma_height, frame.u, rotation);
    rotatePlane(target[luma_bytes + chroma_bytes ..][0..chroma_bytes], chroma_width, chroma_height, frame.v, rotation);
}

/// Turn one plane. `width` and `height` are the size of the target.
fn rotatePlane(target: []u8, width: u32, height: u32, plane: image.PlaneView, rotation: Rotation) void {
    const last_x: usize = plane.width - 1;
    const last_y: usize = plane.height - 1;
    for (0..height) |y| {
        const out = target[y * width ..][0..width];
        switch (rotation) {
            .none => @memcpy(out, plane.row(y)),
            // The left column of the source, from the bottom up, is the top row.
            .quarter => for (out, 0..) |*value, x| {
                value.* = plane.data[(last_y - x) * plane.stride + y];
            },
            .half => {
                const row = plane.row(last_y - y);
                for (out, 0..) |*value, x| value.* = row[last_x - x];
            },
            // The right column of the source, from the top down, is the top row.
            .three_quarters => for (out, 0..) |*value, x| {
                value.* = plane.data[x * plane.stride + (last_x - y)];
            },
        }
    }
}

// endregion: rotate

// region: tests

const testing = std.testing;

/// A frame of 8 x 4 pixels in the layout NV12: a luma plane with a stride of 10,
/// and one chroma plane with the U and the V samples in turn.
const TestNv12 = struct {
    luma: [4 * 10]u8,
    chroma: [2 * 10]u8,

    fn init() TestNv12 {
        var frame: TestNv12 = .{ .luma = @splat(255), .chroma = @splat(255) };
        for (0..4) |y| {
            for (0..8) |x| frame.luma[y * 10 + x] = @intCast(10 * y + x);
        }
        for (0..2) |y| {
            for (0..4) |x| {
                frame.chroma[y * 10 + 2 * x] = @intCast(100 + 10 * y + x);
                frame.chroma[y * 10 + 2 * x + 1] = @intCast(200 + 10 * y + x);
            }
        }
        return frame;
    }

    fn source(self: *const TestNv12) Source {
        return .{
            .width = 8,
            .height = 4,
            .y = &self.luma,
            .y_stride = 10,
            .u = self.chroma[0..],
            .v = self.chroma[1..],
            .chroma_stride = 10,
            .chroma_step = 2,
        };
    }
};

test "copy takes the samples out of the strides of the source" {
    const nv12 = TestNv12.init();
    try testing.expect(nv12.source().isValid());
    var buffer: [image.packedFrameSize(8, 4)]u8 = undefined;
    copy(&buffer, nv12.source());
    const frame = image.FrameView.fromPacked(&buffer, 8, 4, .{});
    try testing.expectEqual(@as(u8, 0), frame.y.at(0, 0));
    try testing.expectEqual(@as(u8, 37), frame.y.at(7, 3));
    try testing.expectEqual(@as(u8, 100), frame.u.at(0, 0));
    try testing.expectEqual(@as(u8, 113), frame.u.at(3, 1));
    try testing.expectEqual(@as(u8, 200), frame.v.at(0, 0));
    try testing.expectEqual(@as(u8, 213), frame.v.at(3, 1));
}

test "a source with a plane that is too short is not valid" {
    const nv12 = TestNv12.init();
    var source = nv12.source();
    source.y = source.y[0..37];
    try testing.expect(!source.isValid());
}

test "shrink takes the mean of each cell" {
    const nv12 = TestNv12.init();
    const size = shrunkSize(.{ .width = 8, .height = 4 }, 2);
    try testing.expectEqual(image.Size{ .width = 4, .height = 2 }, size);
    var buffer: [image.packedFrameSize(4, 2)]u8 = undefined;
    shrink(&buffer, nv12.source(), 2);
    const frame = image.FrameView.fromPacked(&buffer, 4, 2, .{});
    // The mean of 0, 1, 10, 11 is 5.5, and of 26, 27, 36, 37 is 31.5.
    try testing.expectEqual(@as(u8, 6), frame.y.at(0, 0));
    try testing.expectEqual(@as(u8, 32), frame.y.at(3, 1));
    // The mean of 100, 101, 110, 111, and of 202, 203, 212, 213.
    try testing.expectEqual(@as(u8, 106), frame.u.at(0, 0));
    try testing.expectEqual(@as(u8, 208), frame.v.at(1, 0));
}

test "shrink of a wide row gives the same means with and without vector code" {
    // 40 columns: two blocks of 16 columns for the vector code, and 8 more.
    var luma: [4 * 40]u8 = undefined;
    for (&luma, 0..) |*value, index| value.* = @intCast((index * 7) % 251);
    var chroma: [2 * 20]u8 = @splat(128);
    const source: Source = .{ .width = 40, .height = 4, .y = &luma, .y_stride = 40, .u = &chroma, .v = &chroma, .chroma_stride = 20 };
    var buffer: [image.packedFrameSize(10, 1)]u8 = undefined;
    // A factor of 4 leaves one row of 10 samples; the height 1 is odd, so it is 0.
    try testing.expectEqual(image.Size{ .width = 10, .height = 0 }, shrunkSize(source.size(), 4));
    boxReduce(buffer[0..10], 10, 1, &luma, 40, 1, 4);
    for (0..10) |cell| {
        var sum: u32 = 0;
        for (0..4) |y| {
            for (0..4) |x| sum += luma[y * 40 + cell * 4 + x];
        }
        try testing.expectEqual(@as(u8, @intCast((sum + 8) / 16)), buffer[cell]);
    }
}

test "the shrink factor brings the short side to the analysis size" {
    try testing.expectEqual(@as(u32, 4), shrinkFactor(.{ .width = 3840, .height = 2160 }, 540));
    try testing.expectEqual(@as(u32, 2), shrinkFactor(.{ .width = 1080, .height = 1920 }, 540));
    try testing.expectEqual(@as(u32, 1), shrinkFactor(.{ .width = 640, .height = 480 }, 540));
    try testing.expectEqual(image.Size{ .width = 960, .height = 540 }, shrunkSize(.{ .width = 3840, .height = 2160 }, 4));
}

test "rotations from degrees" {
    try testing.expectEqual(Rotation.none, Rotation.fromDegrees(0).?);
    try testing.expectEqual(Rotation.quarter, Rotation.fromDegrees(90).?);
    try testing.expectEqual(Rotation.three_quarters, Rotation.fromDegrees(-90).?);
    try testing.expectEqual(Rotation.half, Rotation.fromDegrees(540).?);
    try testing.expect(Rotation.fromDegrees(45) == null);
}

test "a quarter turn brings the left column to the top row" {
    // 4 x 2 luma: 0 1 2 3 / 10 11 12 13. Chroma 2 x 1.
    const data = [_]u8{ 0, 1, 2, 3, 10, 11, 12, 13, 50, 51, 60, 61 };
    const frame = image.FrameView.fromPacked(&data, 4, 2, .{});
    var buffer: [12]u8 = undefined;

    rotate(&buffer, frame, .quarter);
    const quarter = image.FrameView.fromPacked(&buffer, 2, 4, .{});
    try testing.expectEqualSlices(u8, &.{ 10, 0, 11, 1, 12, 2, 13, 3 }, quarter.y.data);
    try testing.expectEqualSlices(u8, &.{ 50, 51 }, quarter.u.data);
    try testing.expectEqualSlices(u8, &.{ 60, 61 }, quarter.v.data);

    rotate(&buffer, frame, .three_quarters);
    const back = image.FrameView.fromPacked(&buffer, 2, 4, .{});
    try testing.expectEqualSlices(u8, &.{ 3, 13, 2, 12, 1, 11, 0, 10 }, back.y.data);

    rotate(&buffer, frame, .half);
    const half = image.FrameView.fromPacked(&buffer, 4, 2, .{});
    try testing.expectEqualSlices(u8, &.{ 13, 12, 11, 10, 3, 2, 1, 0 }, half.y.data);
    try testing.expectEqualSlices(u8, &.{ 51, 50 }, half.u.data);

    rotate(&buffer, frame, .none);
    try testing.expectEqualSlices(u8, &data, &buffer);
}

// endregion: tests
