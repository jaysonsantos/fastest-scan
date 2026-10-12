//! Basic operations on 8-bit planes: scaling by two, histograms, Otsu's threshold,
//! 3x3 morphology, and the largest connected region of a mask.

const std = @import("std");
const Allocator = std.mem.Allocator;
const image = @import("image.zig");
const Plane = image.Plane;
const PlaneView = image.PlaneView;

pub const histogram_bins = 256;
pub const Histogram = [histogram_bins]u32;

// region: scaling

/// The plane at half the width and half the height. Each sample is the mean of 2x2
/// samples. An odd last row or column is dropped.
pub fn halve(allocator: Allocator, source: PlaneView) Allocator.Error!Plane {
    const width = source.width / 2;
    const height = source.height / 2;
    const out = try Plane.init(allocator, width, height);
    for (0..height) |y| {
        const top = source.data[(2 * y) * source.stride ..];
        const bottom = source.data[(2 * y + 1) * source.stride ..];
        const target = out.row(y);
        for (target, 0..) |*value, x| {
            const sum = @as(u32, top[2 * x]) + top[2 * x + 1] + bottom[2 * x] + bottom[2 * x + 1];
            value.* = @intCast((sum + 2) / 4);
        }
    }
    return out;
}

// endregion: scaling

// region: histogram

pub fn histogram(plane: PlaneView) Histogram {
    var bins: Histogram = @splat(0);
    for (0..plane.height) |y| {
        for (plane.row(y)) |value| bins[value] += 1;
    }
    return bins;
}

/// The smallest code `c` such that at least `fraction` of the samples are <= `c`.
pub fn percentile(bins: *const Histogram, fraction: f32) u8 {
    var total: u64 = 0;
    for (bins) |count| total += count;
    if (total == 0) return 0;
    const target: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(total)) * std.math.clamp(fraction, 0, 1)));
    var cumulative: u64 = 0;
    for (bins, 0..) |count, code| {
        cumulative += count;
        if (cumulative >= target) return @intCast(code);
    }
    return histogram_bins - 1;
}

pub const OtsuResult = struct {
    /// Samples above this code are in the bright class.
    threshold: u8,
    /// The variance between the two classes divided by the total variance, 0..1.
    /// A value near 1 means two clear groups of samples.
    separability: f32,
    /// The mean code of the dark and of the bright class.
    dark_mean: f32,
    bright_mean: f32,
};

/// Otsu's method: the threshold that makes the two classes most different.
/// Source: N. Otsu, "A threshold selection method from gray-level histograms",
/// IEEE Transactions on Systems, Man, and Cybernetics 9(1), 1979.
pub fn otsu(bins: *const Histogram) OtsuResult {
    var total: f64 = 0;
    var weighted_total: f64 = 0;
    for (bins, 0..) |count, code| {
        total += @floatFromInt(count);
        weighted_total += @as(f64, @floatFromInt(count)) * @as(f64, @floatFromInt(code));
    }
    if (total == 0) return .{ .threshold = 0, .separability = 0, .dark_mean = 0, .bright_mean = 0 };
    const mean = weighted_total / total;
    var total_variance: f64 = 0;
    for (bins, 0..) |count, code| {
        const delta = @as(f64, @floatFromInt(code)) - mean;
        total_variance += @as(f64, @floatFromInt(count)) * delta * delta;
    }

    var best: OtsuResult = .{ .threshold = 0, .separability = 0, .dark_mean = @floatCast(mean), .bright_mean = @floatCast(mean) };
    var best_between: f64 = 0;
    var dark_count: f64 = 0;
    var dark_sum: f64 = 0;
    for (bins[0 .. histogram_bins - 1], 0..) |count, code| {
        dark_count += @floatFromInt(count);
        dark_sum += @as(f64, @floatFromInt(count)) * @as(f64, @floatFromInt(code));
        const bright_count = total - dark_count;
        if (dark_count == 0 or bright_count == 0) continue;
        const dark_mean = dark_sum / dark_count;
        const bright_mean = (weighted_total - dark_sum) / bright_count;
        const difference = dark_mean - bright_mean;
        const between = dark_count * bright_count * difference * difference / total;
        if (between > best_between) {
            best_between = between;
            best = .{
                .threshold = @intCast(code),
                .separability = 0,
                .dark_mean = @floatCast(dark_mean),
                .bright_mean = @floatCast(bright_mean),
            };
        }
    }
    best.separability = if (total_variance > 0) @floatCast(best_between / total_variance) else 0;
    return best;
}

// endregion: histogram

// region: morphology

/// A mask holds `mask_set` for a pixel of the region and 0 for the rest.
pub const mask_set = 1;

/// Erode a mask with a 3x3 square: a pixel stays set only when its 8 neighbours are
/// set. Pixels on the border of the plane become clear.
pub fn erode3(allocator: Allocator, mask: Plane) Allocator.Error!Plane {
    const out = try Plane.initFilled(allocator, mask.width, mask.height, 0);
    if (mask.width < 3 or mask.height < 3) return out;
    for (1..mask.height - 1) |y| {
        const above = mask.row(y - 1);
        const here = mask.row(y);
        const below = mask.row(y + 1);
        const target = out.row(y);
        for (1..mask.width - 1) |x| {
            const all = above[x - 1] & above[x] & above[x + 1] &
                here[x - 1] & here[x] & here[x + 1] &
                below[x - 1] & below[x] & below[x + 1];
            target[x] = all;
        }
    }
    return out;
}

/// Dilate a mask with a 3x3 square: a pixel becomes set when one of its 8 neighbours
/// or the pixel is set.
pub fn dilate3(allocator: Allocator, mask: Plane) Allocator.Error!Plane {
    const out = try Plane.initFilled(allocator, mask.width, mask.height, 0);
    const width: i32 = @intCast(mask.width);
    const height: i32 = @intCast(mask.height);
    for (0..mask.height) |y| {
        const target = out.row(y);
        for (0..mask.width) |x| {
            var any: u8 = 0;
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                const ny = @as(i32, @intCast(y)) + dy;
                if (ny < 0 or ny >= height) continue;
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    const nx = @as(i32, @intCast(x)) + dx;
                    if (nx < 0 or nx >= width) continue;
                    any |= mask.at(@intCast(nx), @intCast(ny));
                }
            }
            target[x] = any;
        }
    }
    return out;
}

// endregion: morphology

// region: connected regions

/// The pixels that a flood from the border of the plane reaches. A pixel with a
/// value that is not 0 is a wall: the flood does not cross it. The flood moves
/// across the four sides of a pixel, not across its corners, so a wall with a
/// width of one pixel holds also when it runs at an angle.
///
/// The result has `mask_set` for each pixel that the flood reached.
pub fn floodFromBorder(allocator: Allocator, walls: Plane) Allocator.Error!Plane {
    const width: usize = walls.width;
    const height: usize = walls.height;
    const reached = try Plane.initFilled(allocator, walls.width, walls.height, 0);
    errdefer reached.deinit(allocator);
    if (width == 0 or height == 0) return reached;
    const stack = try allocator.alloc(u32, width * height);
    defer allocator.free(stack);
    var stack_len: usize = 0;

    const Flood = struct {
        fn enter(wall_data: []const u8, reached_data: []u8, items: []u32, len: *usize, index: usize) void {
            if (wall_data[index] != 0 or reached_data[index] != 0) return;
            reached_data[index] = mask_set;
            items[len.*] = @intCast(index);
            len.* += 1;
        }
    };
    for (0..width) |x| {
        Flood.enter(walls.data, reached.data, stack, &stack_len, x);
        Flood.enter(walls.data, reached.data, stack, &stack_len, (height - 1) * width + x);
    }
    for (0..height) |y| {
        Flood.enter(walls.data, reached.data, stack, &stack_len, y * width);
        Flood.enter(walls.data, reached.data, stack, &stack_len, y * width + width - 1);
    }
    while (stack_len > 0) {
        stack_len -= 1;
        const index: usize = stack[stack_len];
        const x = index % width;
        const y = index / width;
        if (x > 0) Flood.enter(walls.data, reached.data, stack, &stack_len, index - 1);
        if (x + 1 < width) Flood.enter(walls.data, reached.data, stack, &stack_len, index + 1);
        if (y > 0) Flood.enter(walls.data, reached.data, stack, &stack_len, index - width);
        if (y + 1 < height) Flood.enter(walls.data, reached.data, stack, &stack_len, index + width);
    }
    return reached;
}

pub const Region = struct {
    /// `mask_set` for each pixel of the region.
    mask: Plane,
    area: u32,
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,
    /// True when a pixel of the region lies on the border of the plane.
    touches_border: bool,

    pub fn deinit(self: Region, allocator: Allocator) void {
        self.mask.deinit(allocator);
    }
};

/// The largest group of set pixels that connect through their 8 neighbours, or null
/// for an empty mask.
pub fn largestRegion(allocator: Allocator, mask: Plane) Allocator.Error!?Region {
    const width = mask.width;
    const height = mask.height;
    const pixel_count = @as(usize, width) * height;
    const no_label = 0;

    const labels = try allocator.alloc(u32, pixel_count);
    defer allocator.free(labels);
    @memset(labels, no_label);
    const stack = try allocator.alloc(u32, pixel_count);
    defer allocator.free(stack);

    var best_label: u32 = no_label;
    var best_area: u32 = 0;
    var next_label: u32 = 1;
    for (0..pixel_count) |seed| {
        if (mask.data[seed] == 0 or labels[seed] != no_label) continue;
        const label = next_label;
        next_label += 1;
        var area: u32 = 0;
        var stack_len: usize = 1;
        stack[0] = @intCast(seed);
        labels[seed] = label;
        while (stack_len > 0) {
            stack_len -= 1;
            const index = stack[stack_len];
            area += 1;
            const x: i32 = @intCast(index % width);
            const y: i32 = @intCast(index / width);
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                const ny = y + dy;
                if (ny < 0 or ny >= height) continue;
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    const nx = x + dx;
                    if (nx < 0 or nx >= width) continue;
                    const neighbour = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));
                    if (mask.data[neighbour] == 0 or labels[neighbour] != no_label) continue;
                    labels[neighbour] = label;
                    stack[stack_len] = @intCast(neighbour);
                    stack_len += 1;
                }
            }
        }
        if (area > best_area) {
            best_area = area;
            best_label = label;
        }
    }
    if (best_label == no_label) return null;

    var region: Region = .{
        .mask = try Plane.initFilled(allocator, width, height, 0),
        .area = best_area,
        .min_x = width,
        .min_y = height,
        .max_x = 0,
        .max_y = 0,
        .touches_border = false,
    };
    for (0..height) |y| {
        for (0..width) |x| {
            if (labels[y * width + x] != best_label) continue;
            region.mask.set(x, y, mask_set);
            region.min_x = @min(region.min_x, @as(u32, @intCast(x)));
            region.max_x = @max(region.max_x, @as(u32, @intCast(x)));
            region.min_y = @min(region.min_y, @as(u32, @intCast(y)));
            region.max_y = @max(region.max_y, @as(u32, @intCast(y)));
        }
    }
    region.touches_border = region.min_x == 0 or region.min_y == 0 or
        region.max_x == width - 1 or region.max_y == height - 1;
    return region;
}

// endregion: connected regions

// region: tests

const testing = std.testing;

test "halve takes the mean of 2x2 samples" {
    const data = [_]u8{
        10, 20, 100, 100,
        30, 40, 100, 104,
    };
    const source: PlaneView = .{ .data = &data, .width = 4, .height = 2, .stride = 4 };
    const half = try halve(testing.allocator, source);
    defer half.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), half.width);
    try testing.expectEqual(@as(u32, 1), half.height);
    try testing.expectEqual(@as(u8, 25), half.at(0, 0));
    try testing.expectEqual(@as(u8, 101), half.at(1, 0));
}

test "otsu separates two groups" {
    var bins: Histogram = @splat(0);
    bins[40] = 500;
    bins[45] = 300;
    bins[200] = 400;
    bins[210] = 100;
    const result = otsu(&bins);
    try testing.expect(result.threshold >= 45 and result.threshold < 200);
    try testing.expect(result.separability > 0.95);
    try testing.expect(result.dark_mean < 50 and result.bright_mean > 195);
}

test "percentile of a histogram" {
    var bins: Histogram = @splat(0);
    bins[10] = 50;
    bins[20] = 40;
    bins[30] = 10;
    try testing.expectEqual(@as(u8, 10), percentile(&bins, 0.5));
    try testing.expectEqual(@as(u8, 20), percentile(&bins, 0.9));
    try testing.expectEqual(@as(u8, 30), percentile(&bins, 1.0));
}

test "erosion then dilation removes a single pixel and keeps a block" {
    const side = 9;
    const mask = try Plane.initFilled(testing.allocator, side, side, 0);
    defer mask.deinit(testing.allocator);
    mask.set(1, 1, mask_set);
    for (3..8) |y| {
        for (3..8) |x| mask.set(x, y, mask_set);
    }
    const eroded = try erode3(testing.allocator, mask);
    defer eroded.deinit(testing.allocator);
    const opened = try dilate3(testing.allocator, eroded);
    defer opened.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), opened.at(1, 1));
    try testing.expectEqual(@as(u8, mask_set), opened.at(3, 3));
    try testing.expectEqual(@as(u8, mask_set), opened.at(7, 7));
    try testing.expectEqual(@as(u8, 0), opened.at(8, 8));
}

test "largestRegion picks the bigger of two groups" {
    const mask = try Plane.initFilled(testing.allocator, 8, 4, 0);
    defer mask.deinit(testing.allocator);
    mask.set(0, 0, mask_set);
    mask.set(1, 1, mask_set);
    for (4..8) |x| {
        mask.set(x, 2, mask_set);
        mask.set(x, 3, mask_set);
    }
    const region = (try largestRegion(testing.allocator, mask)).?;
    defer region.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 8), region.area);
    try testing.expectEqual(@as(u32, 4), region.min_x);
    try testing.expectEqual(@as(u32, 2), region.min_y);
    try testing.expect(region.touches_border);
    try testing.expectEqual(@as(u8, 0), region.mask.at(0, 0));
}

test "a flood from the border stops at a closed wall and enters an open one" {
    const width = 9;
    const height = 7;
    const walls = try Plane.initFilled(testing.allocator, width, height, 0);
    defer walls.deinit(testing.allocator);
    // A closed box, with its inside at x 3..5 and y 2..4.
    for (2..7) |x| {
        walls.set(x, 1, mask_set);
        walls.set(x, 5, mask_set);
    }
    for (1..6) |y| {
        walls.set(2, y, mask_set);
        walls.set(6, y, mask_set);
    }
    const closed = try floodFromBorder(testing.allocator, walls);
    defer closed.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, mask_set), closed.at(0, 0));
    try testing.expectEqual(@as(u8, mask_set), closed.at(8, 3));
    try testing.expectEqual(@as(u8, 0), closed.at(4, 3));
    // A wall is not reached.
    try testing.expectEqual(@as(u8, 0), closed.at(2, 3));

    // One gap in the wall lets the flood in.
    walls.set(6, 3, 0);
    const open = try floodFromBorder(testing.allocator, walls);
    defer open.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, mask_set), open.at(4, 3));
}

test "a flood does not cross a wall at an angle" {
    const size = 8;
    const walls = try Plane.initFilled(testing.allocator, size, size, 0);
    defer walls.deinit(testing.allocator);
    // A wall of one pixel from corner to corner: the two sides touch only at corners.
    for (0..size) |index| walls.set(index, index, mask_set);
    // The frame border is a wall too, except one pixel on the left side.
    for (0..size) |index| {
        walls.set(index, 0, mask_set);
        walls.set(index, size - 1, mask_set);
        walls.set(0, index, mask_set);
        walls.set(size - 1, index, mask_set);
    }
    walls.set(0, 4, 0);
    const reached = try floodFromBorder(testing.allocator, walls);
    defer reached.deinit(testing.allocator);
    // Below the wall: reached. Above it: not reached.
    try testing.expectEqual(@as(u8, mask_set), reached.at(2, 5));
    try testing.expectEqual(@as(u8, 0), reached.at(5, 2));
}

test "largestRegion of an empty mask is null" {
    const mask = try Plane.initFilled(testing.allocator, 4, 4, 0);
    defer mask.deinit(testing.allocator);
    try testing.expect(try largestRegion(testing.allocator, mask) == null);
}

// endregion: tests
