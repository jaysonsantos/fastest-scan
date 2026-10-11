//! Image containers: 8-bit planes, planar YUV 4:2:0 frames, interleaved RGB images,
//! and float planes. The functions here only move and read samples.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Size = struct {
    width: u32,
    height: u32,

    pub fn pixels(self: Size) usize {
        return @as(usize, self.width) * self.height;
    }
};

// region: 8-bit plane

/// A read-only view of one 8-bit channel. Rows are `stride` bytes apart.
pub const PlaneView = struct {
    data: []const u8,
    width: u32,
    height: u32,
    stride: u32,

    pub fn row(self: PlaneView, y: usize) []const u8 {
        const start = y * self.stride;
        return self.data[start .. start + self.width];
    }

    pub fn at(self: PlaneView, x: usize, y: usize) u8 {
        return self.data[y * self.stride + x];
    }

    /// The sample at a position outside the plane is the sample of the nearest edge.
    pub fn atClamped(self: PlaneView, x: i32, y: i32) u8 {
        const cx: usize = @intCast(std.math.clamp(x, 0, @as(i32, @intCast(self.width)) - 1));
        const cy: usize = @intCast(std.math.clamp(y, 0, @as(i32, @intCast(self.height)) - 1));
        return self.data[cy * self.stride + cx];
    }

    /// Bilinear sample. Sample centers are at integer coordinates.
    pub fn sample(self: PlaneView, x: f32, y: f32) f32 {
        const max_x: f32 = @floatFromInt(self.width - 1);
        const max_y: f32 = @floatFromInt(self.height - 1);
        const cx = std.math.clamp(x, 0, max_x);
        const cy = std.math.clamp(y, 0, max_y);
        const x0: usize = @intFromFloat(cx);
        const y0: usize = @intFromFloat(cy);
        const x1 = @min(x0 + 1, self.width - 1);
        const y1 = @min(y0 + 1, self.height - 1);
        const fx = cx - @as(f32, @floatFromInt(x0));
        const fy = cy - @as(f32, @floatFromInt(y0));
        const row0 = self.data[y0 * self.stride ..];
        const row1 = self.data[y1 * self.stride ..];
        const top = @as(f32, @floatFromInt(row0[x0])) * (1 - fx) + @as(f32, @floatFromInt(row0[x1])) * fx;
        const bottom = @as(f32, @floatFromInt(row1[x0])) * (1 - fx) + @as(f32, @floatFromInt(row1[x1])) * fx;
        return top * (1 - fy) + bottom * fy;
    }

    pub fn size(self: PlaneView) Size {
        return .{ .width = self.width, .height = self.height };
    }
};

/// One 8-bit channel that owns its samples. The stride equals the width.
pub const Plane = struct {
    data: []u8,
    width: u32,
    height: u32,

    pub fn init(allocator: Allocator, width: u32, height: u32) Allocator.Error!Plane {
        const data = try allocator.alloc(u8, @as(usize, width) * height);
        return .{ .data = data, .width = width, .height = height };
    }

    pub fn initFilled(allocator: Allocator, width: u32, height: u32, value: u8) Allocator.Error!Plane {
        const plane = try init(allocator, width, height);
        @memset(plane.data, value);
        return plane;
    }

    pub fn deinit(self: Plane, allocator: Allocator) void {
        allocator.free(self.data);
    }

    pub fn view(self: Plane) PlaneView {
        return .{ .data = self.data, .width = self.width, .height = self.height, .stride = self.width };
    }

    pub fn row(self: Plane, y: usize) []u8 {
        const start = y * self.width;
        return self.data[start .. start + self.width];
    }

    pub fn at(self: Plane, x: usize, y: usize) u8 {
        return self.data[y * self.width + x];
    }

    pub fn set(self: Plane, x: usize, y: usize, value: u8) void {
        self.data[y * self.width + x] = value;
    }

    pub fn size(self: Plane) Size {
        return .{ .width = self.width, .height = self.height };
    }
};

// endregion: 8-bit plane

// region: float plane

/// One channel of 32-bit floats that owns its samples.
pub const PlaneF32 = struct {
    data: []f32,
    width: u32,
    height: u32,

    pub fn init(allocator: Allocator, width: u32, height: u32) Allocator.Error!PlaneF32 {
        const data = try allocator.alloc(f32, @as(usize, width) * height);
        return .{ .data = data, .width = width, .height = height };
    }

    pub fn deinit(self: PlaneF32, allocator: Allocator) void {
        allocator.free(self.data);
    }

    pub fn row(self: PlaneF32, y: usize) []f32 {
        const start = y * self.width;
        return self.data[start .. start + self.width];
    }

    pub fn at(self: PlaneF32, x: usize, y: usize) f32 {
        return self.data[y * self.width + x];
    }

    pub fn atClamped(self: PlaneF32, x: i32, y: i32) f32 {
        const cx: usize = @intCast(std.math.clamp(x, 0, @as(i32, @intCast(self.width)) - 1));
        const cy: usize = @intCast(std.math.clamp(y, 0, @as(i32, @intCast(self.height)) - 1));
        return self.data[cy * self.width + cx];
    }

    /// Bilinear sample with the edge samples repeated outside the plane.
    pub fn sample(self: PlaneF32, x: f32, y: f32) f32 {
        const max_x: f32 = @floatFromInt(self.width - 1);
        const max_y: f32 = @floatFromInt(self.height - 1);
        const cx = std.math.clamp(x, 0, max_x);
        const cy = std.math.clamp(y, 0, max_y);
        const x0: usize = @intFromFloat(cx);
        const y0: usize = @intFromFloat(cy);
        const x1 = @min(x0 + 1, self.width - 1);
        const y1 = @min(y0 + 1, self.height - 1);
        const fx = cx - @as(f32, @floatFromInt(x0));
        const fy = cy - @as(f32, @floatFromInt(y0));
        const top = self.data[y0 * self.width + x0] * (1 - fx) + self.data[y0 * self.width + x1] * fx;
        const bottom = self.data[y1 * self.width + x0] * (1 - fx) + self.data[y1 * self.width + x1] * fx;
        return top * (1 - fy) + bottom * fy;
    }
};

// endregion: float plane

// region: YUV frame

/// How the 8-bit luma and chroma codes map to light.
pub const ColorRange = enum(u8) {
    /// Luma 16..235, chroma 16..240 ("TV" or "MPEG" range). Phone video uses it.
    limited = 0,
    /// Luma and chroma 0..255 ("PC" or "JPEG" range).
    full = 1,
};

pub const ColorMatrix = enum(u8) {
    /// HD video.
    bt709 = 0,
    /// SD video and JPEG.
    bt601 = 1,
};

pub const Colorimetry = struct {
    range: ColorRange = .limited,
    matrix: ColorMatrix = .bt709,
};

/// A read-only planar YUV 4:2:0 frame (I420): the chroma planes have half the width
/// and half the height of the luma plane.
pub const FrameView = struct {
    y: PlaneView,
    u: PlaneView,
    v: PlaneView,
    colorimetry: Colorimetry = .{},

    pub fn width(self: FrameView) u32 {
        return self.y.width;
    }

    pub fn height(self: FrameView) u32 {
        return self.y.height;
    }

    /// The view of a frame that lies in one buffer: the Y plane, then U, then V, with
    /// no padding. This is the `yuv420p` raw video layout of ffmpeg.
    pub fn fromPacked(data: []const u8, frame_width: u32, frame_height: u32, colorimetry: Colorimetry) FrameView {
        const luma_size = @as(usize, frame_width) * frame_height;
        const chroma_width = chromaDimension(frame_width);
        const chroma_height = chromaDimension(frame_height);
        const chroma_size = @as(usize, chroma_width) * chroma_height;
        std.debug.assert(data.len >= luma_size + 2 * chroma_size);
        return .{
            .y = .{ .data = data[0..luma_size], .width = frame_width, .height = frame_height, .stride = frame_width },
            .u = .{
                .data = data[luma_size .. luma_size + chroma_size],
                .width = chroma_width,
                .height = chroma_height,
                .stride = chroma_width,
            },
            .v = .{
                .data = data[luma_size + chroma_size .. luma_size + 2 * chroma_size],
                .width = chroma_width,
                .height = chroma_height,
                .stride = chroma_width,
            },
            .colorimetry = colorimetry,
        };
    }
};

/// The number of bytes of a packed I420 frame.
pub fn packedFrameSize(frame_width: u32, frame_height: u32) usize {
    const luma = @as(usize, frame_width) * frame_height;
    const chroma = @as(usize, chromaDimension(frame_width)) * chromaDimension(frame_height);
    return luma + 2 * chroma;
}

/// The size of a chroma plane along one axis, for a luma size of `luma`.
pub fn chromaDimension(luma: u32) u32 {
    return (luma + 1) / chroma_subsampling;
}

const chroma_subsampling = 2;

/// A YUV frame with full-resolution chroma (4:4:4) that owns its samples.
pub const Frame444 = struct {
    y: Plane,
    u: Plane,
    v: Plane,
    colorimetry: Colorimetry,

    pub fn init(allocator: Allocator, frame_width: u32, frame_height: u32, colorimetry: Colorimetry) Allocator.Error!Frame444 {
        const y = try Plane.init(allocator, frame_width, frame_height);
        errdefer y.deinit(allocator);
        const u = try Plane.init(allocator, frame_width, frame_height);
        errdefer u.deinit(allocator);
        const v = try Plane.init(allocator, frame_width, frame_height);
        return .{ .y = y, .u = u, .v = v, .colorimetry = colorimetry };
    }

    pub fn deinit(self: Frame444, allocator: Allocator) void {
        self.y.deinit(allocator);
        self.u.deinit(allocator);
        self.v.deinit(allocator);
    }

    pub fn width(self: Frame444) u32 {
        return self.y.width;
    }

    pub fn height(self: Frame444) u32 {
        return self.y.height;
    }
};

// endregion: YUV frame

// region: RGB image

pub const rgb_channels = 3;

/// An 8-bit sRGB image with interleaved channels that owns its samples.
pub const Rgb8 = struct {
    data: []u8,
    width: u32,
    height: u32,

    pub fn init(allocator: Allocator, width: u32, height: u32) Allocator.Error!Rgb8 {
        const data = try allocator.alloc(u8, @as(usize, width) * height * rgb_channels);
        return .{ .data = data, .width = width, .height = height };
    }

    pub fn deinit(self: Rgb8, allocator: Allocator) void {
        allocator.free(self.data);
    }

    pub fn row(self: Rgb8, y: usize) []u8 {
        const row_bytes = @as(usize, self.width) * rgb_channels;
        return self.data[y * row_bytes .. (y + 1) * row_bytes];
    }

    pub fn pixel(self: Rgb8, x: usize, y: usize) *[rgb_channels]u8 {
        const start = (y * self.width + x) * rgb_channels;
        return self.data[start..][0..rgb_channels];
    }

    pub fn size(self: Rgb8) Size {
        return .{ .width = self.width, .height = self.height };
    }
};

/// A float RGB image with interleaved channels. The values are in 0..1 for the
/// range black..white, but can leave that range during processing.
pub const RgbF32 = struct {
    data: []f32,
    width: u32,
    height: u32,

    pub fn init(allocator: Allocator, width: u32, height: u32) Allocator.Error!RgbF32 {
        const data = try allocator.alloc(f32, @as(usize, width) * height * rgb_channels);
        return .{ .data = data, .width = width, .height = height };
    }

    pub fn deinit(self: RgbF32, allocator: Allocator) void {
        allocator.free(self.data);
    }

    pub fn pixel(self: RgbF32, x: usize, y: usize) *[rgb_channels]f32 {
        const start = (y * self.width + x) * rgb_channels;
        return self.data[start..][0..rgb_channels];
    }

    pub fn size(self: RgbF32) Size {
        return .{ .width = self.width, .height = self.height };
    }
};

// endregion: RGB image

// region: tests

const testing = std.testing;

test "packed I420 layout" {
    const width = 6;
    const height = 4;
    try testing.expectEqual(@as(usize, 36), packedFrameSize(width, height));
    var buffer: [36]u8 = undefined;
    for (&buffer, 0..) |*b, i| b.* = @intCast(i);
    const frame = FrameView.fromPacked(&buffer, width, height, .{});
    try testing.expectEqual(@as(u8, 0), frame.y.at(0, 0));
    try testing.expectEqual(@as(u8, 23), frame.y.at(5, 3));
    try testing.expectEqual(@as(u8, 24), frame.u.at(0, 0));
    try testing.expectEqual(@as(u8, 30), frame.v.at(0, 0));
    try testing.expectEqual(@as(u32, 3), frame.u.width);
}

test "odd frame sizes round the chroma size up" {
    try testing.expectEqual(@as(u32, 3), chromaDimension(5));
    try testing.expectEqual(@as(usize, 5 * 3 + 2 * 3 * 2), packedFrameSize(5, 3));
}

test "bilinear sample between four pixels" {
    const data = [_]u8{ 0, 100, 200, 100 };
    const plane: PlaneView = .{ .data = &data, .width = 2, .height = 2, .stride = 2 };
    try testing.expectApproxEqAbs(@as(f32, 100), plane.sample(0.5, 0.5), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), plane.sample(-3, -3), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 100), plane.sample(9, 9), 1e-3);
}

// endregion: tests
