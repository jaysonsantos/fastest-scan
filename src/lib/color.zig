//! Conversion from video YUV codes to RGB.
//!
//! The matrices and the code ranges are those of ITU-R Recommendations BT.709 (HD
//! video) and BT.601 (SD video and JPEG).
//!
//! The RGB values keep the transfer curve of the video (BT.709), which is close to
//! the sRGB curve. The pipeline treats them as sRGB.

const std = @import("std");
const image = @import("image.zig");

/// The luma weights of red and blue; green is the rest.
const Weights = struct {
    kr: f32,
    kb: f32,
};

const bt709_weights: Weights = .{ .kr = 0.2126, .kb = 0.0722 };
const bt601_weights: Weights = .{ .kr = 0.299, .kb = 0.114 };

const code = struct {
    const max = 255.0;
    const chroma_zero = 128.0;
    const limited_luma_black = 16.0;
    const limited_luma_span = 219.0;
    const limited_chroma_span = 224.0;
};

/// The constants that turn one YUV sample into RGB in the range 0..1.
pub const YuvToRgb = struct {
    luma_offset: f32,
    luma_scale: f32,
    /// The contribution of Cr to red, of Cb and Cr to green, and of Cb to blue, for
    /// chroma codes with 128 already subtracted.
    cr_to_r: f32,
    cb_to_g: f32,
    cr_to_g: f32,
    cb_to_b: f32,

    pub fn init(colorimetry: image.Colorimetry) YuvToRgb {
        const weights = switch (colorimetry.matrix) {
            .bt709 => bt709_weights,
            .bt601 => bt601_weights,
        };
        const kg = 1.0 - weights.kr - weights.kb;
        const luma_offset: f32 = switch (colorimetry.range) {
            .limited => code.limited_luma_black,
            .full => 0,
        };
        const luma_span: f32 = switch (colorimetry.range) {
            .limited => code.limited_luma_span,
            .full => code.max,
        };
        const chroma_span: f32 = switch (colorimetry.range) {
            .limited => code.limited_chroma_span,
            .full => code.max,
        };
        // Cb = (B - Y) / (2 * (1 - kb)) and Cr = (R - Y) / (2 * (1 - kr)), each in -0.5..0.5.
        const cr_to_r = 2.0 * (1.0 - weights.kr) / chroma_span;
        const cb_to_b = 2.0 * (1.0 - weights.kb) / chroma_span;
        return .{
            .luma_offset = luma_offset,
            .luma_scale = 1.0 / luma_span,
            .cr_to_r = cr_to_r,
            .cb_to_b = cb_to_b,
            .cb_to_g = -cb_to_b * weights.kb / kg,
            .cr_to_g = -cr_to_r * weights.kr / kg,
        };
    }

    /// `y`, `u`, and `v` are 8-bit codes, as floats so that the caller can pass
    /// interpolated samples. The result can leave 0..1 a little for out-of-gamut codes.
    pub fn convert(self: YuvToRgb, y: f32, u: f32, v: f32) [image.rgb_channels]f32 {
        const light = (y - self.luma_offset) * self.luma_scale;
        const cb = u - code.chroma_zero;
        const cr = v - code.chroma_zero;
        return .{
            light + self.cr_to_r * cr,
            light + self.cb_to_g * cb + self.cr_to_g * cr,
            light + self.cb_to_b * cb,
        };
    }

    /// The luma code as a value in 0..1.
    pub fn luma(self: YuvToRgb, y: f32) f32 {
        return (y - self.luma_offset) * self.luma_scale;
    }
};

/// Round a value in 0..1 to an 8-bit code.
pub fn toByte(value: f32) u8 {
    const scaled = value * code.max + 0.5;
    if (!(scaled > 0)) return 0;
    if (scaled >= code.max) return 255;
    return @intFromFloat(scaled);
}

/// The Rec. 709 luma of an RGB triple.
pub fn rgbLuma(rgb: [image.rgb_channels]f32) f32 {
    return bt709_weights.kr * rgb[0] + (1.0 - bt709_weights.kr - bt709_weights.kb) * rgb[1] + bt709_weights.kb * rgb[2];
}

// region: tests

const testing = std.testing;
const tolerance = 2e-3;

test "limited-range BT.709 black, white, and grey" {
    const converter = YuvToRgb.init(.{ .range = .limited, .matrix = .bt709 });
    const black = converter.convert(16, 128, 128);
    const white = converter.convert(235, 128, 128);
    for (black) |channel| try testing.expectApproxEqAbs(@as(f32, 0), channel, tolerance);
    for (white) |channel| try testing.expectApproxEqAbs(@as(f32, 1), channel, tolerance);
}

test "limited-range BT.709 primary red" {
    // Pure red in BT.709 limited range is Y=63, Cb=102, Cr=240.
    const converter = YuvToRgb.init(.{ .range = .limited, .matrix = .bt709 });
    const red = converter.convert(63, 102, 240);
    try testing.expectApproxEqAbs(@as(f32, 1), red[0], 1e-2);
    try testing.expectApproxEqAbs(@as(f32, 0), red[1], 1e-2);
    try testing.expectApproxEqAbs(@as(f32, 0), red[2], 1e-2);
}

test "full-range BT.601 matches the JPEG equations" {
    const converter = YuvToRgb.init(.{ .range = .full, .matrix = .bt601 });
    const rgb = converter.convert(100, 90, 200);
    try testing.expectApproxEqAbs((100.0 + 1.402 * 72.0) / 255.0, rgb[0], tolerance);
    try testing.expectApproxEqAbs((100.0 - 0.344136 * -38.0 - 0.714136 * 72.0) / 255.0, rgb[1], tolerance);
    try testing.expectApproxEqAbs((100.0 + 1.772 * -38.0) / 255.0, rgb[2], tolerance);
}

test "toByte clamps and rounds" {
    try testing.expectEqual(@as(u8, 0), toByte(-0.5));
    try testing.expectEqual(@as(u8, 255), toByte(1.7));
    try testing.expectEqual(@as(u8, 128), toByte(0.5));
    try testing.expectEqual(@as(u8, 0), toByte(std.math.nan(f32)));
}

// endregion: tests
