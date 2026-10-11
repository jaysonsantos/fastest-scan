//! Make a warped page look like a scan: even white paper, neutral colour, dark ink,
//! and sharp edges.
//!
//! Sources of the ideas:
//! - Z. Zhang and L.-W. He, "Whiteboard scanning and image enhancement", Digital
//!   Signal Processing 17(2), 2007, section 4: the colour of the paper in a small
//!   cell is the mean of its brightest quarter of pixels; a smooth surface through
//!   the cells gives the illumination; the image divided by it has white paper.
//! - ScanTailor (J. Artsimovich), `EstimateBackground`: a polynomial surface as the
//!   background, with dark cells rejected. No ScanTailor code is used.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");
const image = @import("image.zig");
const color = @import("color.zig");

const RgbF32 = image.RgbF32;
const channels = image.rgb_channels;

// region: options

pub const Options = struct {
    /// Divide the page by the estimated colour of its paper.
    flatten: bool = true,
    /// The side of a background cell, as a fraction of the page height.
    cell_fraction: f32 = 1.0 / 64.0,
    /// The paper colour of a cell is the mean of the pixels above this luma percentile.
    paper_percentile: f32 = 0.75,
    /// A cell is paper when its colour is within this distance below the fitted surface.
    paper_tolerance: f32 = 0.06,
    /// The limits of the correction factor of a pixel.
    min_gain: f32 = 0.7,
    max_gain: f32 = 2.5,
    /// After the division the paper is at 1.0. This value becomes pure white.
    white_point: f32 = 0.97,
    /// This luma percentile of the page becomes `black_target`.
    black_percentile: f32 = 0.01,
    black_target: f32 = 16.0 / 255.0,
    /// The black point is never above this value, so a blank page keeps its tone.
    max_black_point: f32 = 0.35,
    /// The strength of the unsharp mask. 0 turns it off.
    sharpen_amount: f32 = 0.8,
    /// Differences below this value are noise and get no sharpening.
    sharpen_threshold: f32 = 2.0 / 255.0,
};

// endregion: options

// region: background

const min_cell_px = 12;
const luma_bins = 48;
/// The histogram of a cell covers luma 0 to this value.
const luma_bin_range = 1.2;
/// The surface is a polynomial of this degree in x and y.
const surface_degree = 3;
const surface_terms = (surface_degree + 1) * (surface_degree + 2) / 2;
const fit_rounds = 5;
/// A cell this much brighter than the surface is a reflection, not paper.
const bright_tolerance = 0.12;

/// The estimated colour of the blank paper on a coarse grid.
const Background = struct {
    cells: []f32,
    grid_width: usize,
    grid_height: usize,
    cell_px: usize,

    fn deinit(self: Background, allocator: Allocator) void {
        allocator.free(self.cells);
    }

    fn at(self: Background, x: usize, y: usize) *[channels]f32 {
        return self.cells[(y * self.grid_width + x) * channels ..][0..channels];
    }

    /// The background colour at a pixel, bilinear between the cell centers.
    fn sample(self: Background, pixel_x: usize, pixel_y: usize) [channels]f32 {
        const cell: f32 = @floatFromInt(self.cell_px);
        const gx = std.math.clamp((@as(f32, @floatFromInt(pixel_x)) + 0.5) / cell - 0.5, 0, @as(f32, @floatFromInt(self.grid_width - 1)));
        const gy = std.math.clamp((@as(f32, @floatFromInt(pixel_y)) + 0.5) / cell - 0.5, 0, @as(f32, @floatFromInt(self.grid_height - 1)));
        const x0: usize = @intFromFloat(gx);
        const y0: usize = @intFromFloat(gy);
        const x1 = @min(x0 + 1, self.grid_width - 1);
        const y1 = @min(y0 + 1, self.grid_height - 1);
        const fx = gx - @as(f32, @floatFromInt(x0));
        const fy = gy - @as(f32, @floatFromInt(y0));
        var out: [channels]f32 = undefined;
        for (0..channels) |channel| {
            const top = self.at(x0, y0)[channel] * (1 - fx) + self.at(x1, y0)[channel] * fx;
            const bottom = self.at(x0, y1)[channel] * (1 - fx) + self.at(x1, y1)[channel] * fx;
            out[channel] = top * (1 - fy) + bottom * fy;
        }
        return out;
    }
};

/// The terms 1, x, y, x^2, xy, y^2, ... of the surface at a position in -1..1.
fn surfaceTerms(x: f64, y: f64) [surface_terms]f64 {
    var terms: [surface_terms]f64 = undefined;
    var index: usize = 0;
    for (0..surface_degree + 1) |total| {
        for (0..total + 1) |power_y| {
            const power_x = total - power_y;
            terms[index] = std.math.pow(f64, x, @floatFromInt(power_x)) * std.math.pow(f64, y, @floatFromInt(power_y));
            index += 1;
        }
    }
    return terms;
}

/// Estimate the paper colour of each cell, then replace the cells that are not
/// paper (pictures, dense text, fingers) by a smooth surface through the others.
fn estimateBackground(allocator: Allocator, page: RgbF32, options: Options) Allocator.Error!Background {
    const cell_px: usize = @max(min_cell_px, @as(usize, @intFromFloat(@as(f32, @floatFromInt(page.height)) * options.cell_fraction)));
    const grid_width = @max(1, (page.width + cell_px - 1) / cell_px);
    const grid_height = @max(1, (page.height + cell_px - 1) / cell_px);
    const background: Background = .{
        .cells = try allocator.alloc(f32, grid_width * grid_height * channels),
        .grid_width = grid_width,
        .grid_height = grid_height,
        .cell_px = cell_px,
    };
    errdefer background.deinit(allocator);

    // The colour of each cell: the mean of its brightest pixels.
    for (0..grid_height) |cell_y| {
        for (0..grid_width) |cell_x| {
            const x_start = cell_x * cell_px;
            const y_start = cell_y * cell_px;
            const x_end = @min(x_start + cell_px, page.width);
            const y_end = @min(y_start + cell_px, page.height);

            var bins: [luma_bins]u32 = @splat(0);
            var total: u32 = 0;
            for (y_start..y_end) |y| {
                for (x_start..x_end) |x| {
                    bins[lumaBin(color.rgbLuma(page.pixel(x, y).*))] += 1;
                    total += 1;
                }
            }
            // The lowest bin of the brightest part of the cell.
            const wanted: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(total)) * (1 - options.paper_percentile)));
            var cumulative: u32 = 0;
            var threshold_bin: usize = luma_bins - 1;
            while (true) {
                cumulative += bins[threshold_bin];
                if (cumulative >= wanted or threshold_bin == 0) break;
                threshold_bin -= 1;
            }

            var sum: [channels]f64 = @splat(0);
            var count: f64 = 0;
            for (y_start..y_end) |y| {
                for (x_start..x_end) |x| {
                    const pixel = page.pixel(x, y);
                    if (lumaBin(color.rgbLuma(pixel.*)) < threshold_bin) continue;
                    for (0..channels) |channel| sum[channel] += pixel[channel];
                    count += 1;
                }
            }
            const cell = background.at(cell_x, cell_y);
            for (0..channels) |channel| cell[channel] = @floatCast(sum[channel] / @max(count, 1));
        }
    }

    // A surface through the paper cells. Paper is the brightest thing on a page, so a
    // cell far below the surface is not paper and leaves the fit.
    const cell_count = grid_width * grid_height;
    const is_paper = try allocator.alloc(bool, cell_count);
    defer allocator.free(is_paper);
    @memset(is_paper, true);
    var coefficients: [channels][surface_terms]f64 = undefined;
    var have_surface = false;
    for (0..fit_rounds) |_| {
        var normal: [channels][surface_terms][surface_terms]f64 = @splat(@splat(@splat(0)));
        var right: [channels][surface_terms]f64 = @splat(@splat(0));
        var used: usize = 0;
        for (0..grid_height) |cell_y| {
            for (0..grid_width) |cell_x| {
                if (!is_paper[cell_y * grid_width + cell_x]) continue;
                const terms = surfaceTerms(normalized(cell_x, grid_width), normalized(cell_y, grid_height));
                const cell = background.at(cell_x, cell_y);
                for (0..channels) |channel| {
                    for (0..surface_terms) |row| {
                        for (0..surface_terms) |column| normal[channel][row][column] += terms[row] * terms[column];
                        right[channel][row] += terms[row] * cell[channel];
                    }
                }
                used += 1;
            }
        }
        if (used < 2 * surface_terms) break;
        var solved = true;
        for (0..channels) |channel| {
            coefficients[channel] = geometry.solveLinear(surface_terms, &normal[channel], &right[channel]) orelse {
                solved = false;
                break;
            };
        }
        if (!solved) break;
        have_surface = true;

        for (0..grid_height) |cell_y| {
            for (0..grid_width) |cell_x| {
                const terms = surfaceTerms(normalized(cell_x, grid_width), normalized(cell_y, grid_height));
                const cell = background.at(cell_x, cell_y);
                // The green channel is close to the luma and has the least noise.
                var predicted: f64 = 0;
                for (0..surface_terms) |term| predicted += coefficients[1][term] * terms[term];
                const difference = cell[1] - predicted;
                is_paper[cell_y * grid_width + cell_x] = difference > -options.paper_tolerance and difference < bright_tolerance;
            }
        }
    }

    // Cells that are not paper take the value of the surface.
    if (have_surface) {
        for (0..grid_height) |cell_y| {
            for (0..grid_width) |cell_x| {
                if (is_paper[cell_y * grid_width + cell_x]) continue;
                const terms = surfaceTerms(normalized(cell_x, grid_width), normalized(cell_y, grid_height));
                const cell = background.at(cell_x, cell_y);
                for (0..channels) |channel| {
                    var predicted: f64 = 0;
                    for (0..surface_terms) |term| predicted += coefficients[channel][term] * terms[term];
                    cell[channel] = @floatCast(@max(predicted, min_background));
                }
            }
        }
    }
    try smoothCells(allocator, background);
    return background;
}

/// The smallest background value. It keeps the division finite.
const min_background = 0.05;

fn lumaBin(luma: f32) usize {
    const scaled = luma / luma_bin_range * luma_bins;
    if (!(scaled > 0)) return 0;
    return @min(luma_bins - 1, @as(usize, @intFromFloat(scaled)));
}

/// The cell index as a coordinate in -1..1.
fn normalized(index: usize, count: usize) f64 {
    if (count < 2) return 0;
    return 2.0 * @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(count - 1)) - 1.0;
}

/// A 3x3 mean of the cells, so that the correction has no steps.
fn smoothCells(allocator: Allocator, background: Background) Allocator.Error!void {
    const copy = try allocator.dupe(f32, background.cells);
    defer allocator.free(copy);
    const width = background.grid_width;
    const height = background.grid_height;
    for (0..height) |y| {
        for (0..width) |x| {
            var sum: [channels]f32 = @splat(0);
            var count: f32 = 0;
            const y_from = y -| 1;
            const y_to = @min(y + 1, height - 1);
            const x_from = x -| 1;
            const x_to = @min(x + 1, width - 1);
            for (y_from..y_to + 1) |ny| {
                for (x_from..x_to + 1) |nx| {
                    for (0..channels) |channel| sum[channel] += copy[(ny * width + nx) * channels + channel];
                    count += 1;
                }
            }
            const cell = background.at(x, y);
            for (0..channels) |channel| cell[channel] = sum[channel] / count;
        }
    }
}

// endregion: background

// region: sharpen

/// A 5-tap Gaussian with sigma 1.
const blur_kernel = [_]f32{ 0.06136, 0.24477, 0.38774, 0.24477, 0.06136 };
const blur_radius = blur_kernel.len / 2;

/// Unsharp mask on the luma: add the difference between the luma and its blur to
/// the three channels.
fn sharpen(allocator: Allocator, page: RgbF32, options: Options) Allocator.Error!void {
    const width = page.width;
    const height = page.height;
    const luma = try allocator.alloc(f32, @as(usize, width) * height);
    defer allocator.free(luma);
    const horizontal = try allocator.alloc(f32, luma.len);
    defer allocator.free(horizontal);
    for (0..luma.len) |index| luma[index] = color.rgbLuma(page.data[index * channels ..][0..channels].*);

    for (0..height) |y| {
        const row = luma[y * width ..][0..width];
        for (0..width) |x| {
            var sum: f32 = 0;
            for (blur_kernel, 0..) |weight, tap| {
                const source = std.math.clamp(@as(isize, @intCast(x + tap)) - @as(isize, blur_radius), 0, @as(isize, @intCast(width - 1)));
                sum += weight * row[@intCast(source)];
            }
            horizontal[y * width + x] = sum;
        }
    }
    for (0..height) |y| {
        for (0..width) |x| {
            var blurred: f32 = 0;
            for (blur_kernel, 0..) |weight, tap| {
                const source = std.math.clamp(@as(isize, @intCast(y + tap)) - @as(isize, blur_radius), 0, @as(isize, @intCast(height - 1)));
                blurred += weight * horizontal[@as(usize, @intCast(source)) * width + x];
            }
            const detail = luma[y * width + x] - blurred;
            if (@abs(detail) < options.sharpen_threshold) continue;
            const pixel = page.pixel(x, y);
            for (0..channels) |channel| pixel[channel] += options.sharpen_amount * detail;
        }
    }
}

// endregion: sharpen

// region: levels

const level_bins = 256;

/// The luma at the given percentile of the page, for luma values in 0..1.
fn lumaPercentile(page: RgbF32, fraction: f32) f32 {
    var bins: [level_bins]u32 = @splat(0);
    const pixel_count = @as(usize, page.width) * page.height;
    for (0..pixel_count) |index| {
        const luma = color.rgbLuma(page.data[index * channels ..][0..channels].*);
        const bin: usize = @intFromFloat(std.math.clamp(luma, 0, 1) * (level_bins - 1));
        bins[bin] += 1;
    }
    const target: u32 = @intFromFloat(@as(f32, @floatFromInt(pixel_count)) * fraction);
    var cumulative: u32 = 0;
    for (bins, 0..) |count, bin| {
        cumulative += count;
        if (cumulative > target) return @as(f32, @floatFromInt(bin)) / (level_bins - 1);
    }
    return 1;
}

// endregion: levels

/// Divide a warped page by the estimated colour of its paper, in place. After this
/// step blank paper is at 1.0 in the three channels, in each frame. Pages of
/// different frames can then be compared and mixed.
pub fn flatten(allocator: Allocator, page: RgbF32, options: Options) Allocator.Error!void {
    if (page.width == 0 or page.height == 0 or !options.flatten) return;
    const background = try estimateBackground(allocator, page, options);
    defer background.deinit(allocator);
    for (0..page.height) |y| {
        for (0..page.width) |x| {
            const paper = background.sample(x, y);
            const pixel = page.pixel(x, y);
            for (0..channels) |channel| {
                const gain = std.math.clamp(1.0 / @max(paper[channel], min_background), options.min_gain, options.max_gain);
                pixel[channel] *= gain;
            }
        }
    }
}

/// Sharpen a flattened page and set its black and white levels, in place.
pub fn finish(allocator: Allocator, page: RgbF32, options: Options) Allocator.Error!void {
    if (page.width == 0 or page.height == 0) return;
    if (options.sharpen_amount > 0) try sharpen(allocator, page, options);

    // A linear map: the black point goes to `black_target`, the white point to 1.
    const black_point = @min(lumaPercentile(page, options.black_percentile), options.max_black_point);
    const span = @max(options.white_point - black_point, min_level_span);
    const slope = (1.0 - options.black_target) / span;
    for (page.data) |*value| value.* = options.black_target + (value.* - black_point) * slope;
}

/// Enhance a warped page in place: `flatten`, then `finish`. The values stay
/// floats; they can leave 0..1 a little, and the conversion to bytes clips them.
pub fn enhance(allocator: Allocator, page: RgbF32, options: Options) Allocator.Error!void {
    try flatten(allocator, page, options);
    try finish(allocator, page, options);
}

const min_level_span = 0.2;

/// Convert to 8-bit with rounding and clipping.
pub fn toRgb8(allocator: Allocator, page: RgbF32) Allocator.Error!image.Rgb8 {
    const out = try image.Rgb8.init(allocator, page.width, page.height);
    for (out.data, page.data) |*byte, value| byte.* = color.toByte(value);
    return out;
}

/// True when the page has no colour to keep: a grey JPEG is then smaller and as good.
pub fn isGray(page: image.Rgb8) bool {
    var chroma_sum: u64 = 0;
    var strong: u64 = 0;
    const pixel_count = @as(usize, page.width) * page.height;
    for (0..pixel_count) |index| {
        const pixel = page.data[index * channels ..][0..channels];
        const largest = @max(pixel[0], @max(pixel[1], pixel[2]));
        const smallest = @min(pixel[0], @min(pixel[1], pixel[2]));
        const spread = largest - smallest;
        chroma_sum += spread;
        if (spread > gray_strong_spread) strong += 1;
    }
    const mean_spread = @as(f32, @floatFromInt(chroma_sum)) / @as(f32, @floatFromInt(@max(pixel_count, 1)));
    const strong_fraction = @as(f32, @floatFromInt(strong)) / @as(f32, @floatFromInt(@max(pixel_count, 1)));
    return mean_spread < gray_max_mean_spread and strong_fraction < gray_max_strong_fraction;
}

/// The limits of the grey test, on the difference between the largest and the
/// smallest channel of a pixel, in 8-bit codes.
const gray_max_mean_spread = 4.0;
const gray_strong_spread = 24;
const gray_max_strong_fraction = 0.002;

// region: tests

const testing = std.testing;

/// A page with a brightness that falls from left to right, warm paper, and a dark block.
fn testPage(allocator: Allocator) !RgbF32 {
    const page = try RgbF32.init(allocator, 256, 320);
    for (0..page.height) |y| {
        for (0..page.width) |x| {
            const shade = 0.75 - 0.25 * @as(f32, @floatFromInt(x)) / 255.0;
            const in_block = x > 60 and x < 150 and y > 80 and y < 200;
            const ink: f32 = if (in_block) 0.2 else 1.0;
            page.pixel(x, y).* = .{ shade * ink, shade * 0.93 * ink, shade * 0.85 * ink };
        }
    }
    return page;
}

test "enhance makes the paper white and even" {
    const page = try testPage(testing.allocator);
    defer page.deinit(testing.allocator);
    try enhance(testing.allocator, page, .{ .sharpen_amount = 0 });

    // Paper at the bright side and at the dark side, away from the block.
    for ([_][2]usize{ .{ 20, 30 }, .{ 235, 30 }, .{ 235, 300 }, .{ 20, 300 } }) |position| {
        const pixel = page.pixel(position[0], position[1]);
        for (0..channels) |channel| try testing.expect(pixel[channel] > 0.98);
    }
    // The block stays dark and neutral.
    const ink = page.pixel(100, 140);
    try testing.expect(ink[0] < 0.3);
    try testing.expectApproxEqAbs(ink[0], ink[2], 0.03);
}

test "a blank page stays blank" {
    const page = try RgbF32.init(testing.allocator, 128, 160);
    defer page.deinit(testing.allocator);
    for (page.data) |*value| value.* = 0.6;
    try enhance(testing.allocator, page, .{});
    for (page.data) |value| try testing.expect(value > 0.98);
}

test "grey test" {
    const gray = try image.Rgb8.init(testing.allocator, 32, 32);
    defer gray.deinit(testing.allocator);
    @memset(gray.data, 200);
    try testing.expect(isGray(gray));
    // A red patch of 4 % of the page.
    for (0..6) |y| {
        for (0..7) |x| gray.pixel(x, y).* = .{ 220, 40, 40 };
    }
    try testing.expect(!isGray(gray));
}

// endregion: tests
