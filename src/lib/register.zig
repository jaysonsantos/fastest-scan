//! Registration: find where each part of one picture of a page lies in another
//! picture of the same page.
//!
//! The two pictures are warped to the same rectangle first, so they agree up to a
//! small error: the page corners are not exact, and paper bends. The function
//! measures that error on a grid of tiles, from a small copy of the pictures up to
//! the full size, and then fits one plane transform to the tiles.
//!
//! Sources:
//! - S. W. Hasinoff, D. Sharlet, R. Geiss, A. Adams, J. T. Barron, F. Kainz, J. Chen,
//!   and M. Levoy, "Burst photography for high dynamic range and low-light imaging
//!   on mobile cameras", ACM Transactions on Graphics 35(6), 2016: tile alignment on
//!   a pyramid, with the result of a coarse level as the start of the next level and
//!   the neighbour tiles as extra start candidates.
//! - A. Monod, J. Delon, and T. Veit, "An analysis and implementation of the HDR+
//!   burst denoising method", Image Processing On Line 11, 2021: the details of that
//!   alignment.
//! The tile score here is the zero-mean normalized cross-correlation, which ignores
//! a change of exposure between the pictures. HDR+ uses L1 and L2 distances.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");
const image = @import("image.zig");
const raster = @import("raster.zig");

const Point = geometry.Point;
const Homography = geometry.Homography;
const Plane = image.Plane;
const PlaneView = image.PlaneView;

// region: options and results

pub const Options = struct {
    /// The side of a tile in pixels, at each level of the pyramid.
    tile: u32 = 32,
    /// The largest number of pyramid levels. Each level has half the size of the
    /// level below it. The function uses fewer levels for a small picture.
    max_levels: u8 = 5,
    /// The search distance around the start position, in pixels of the level: at
    /// the smallest level, at the levels between, and at the full size.
    coarse_radius: u8 = 6,
    middle_radius: u8 = 2,
    fine_radius: u8 = 1,
    /// A tile needs this standard deviation of its luma codes to give a position.
    /// Blank paper has no structure to find.
    min_texture: f32 = 6.0,
    /// A tile match below this correlation is not used for the transform.
    min_correlation: f32 = 0.5,
    /// A tile supports the transform when it lies within this distance of it, in pixels.
    inlier_distance: f32 = 1.5,
};

pub const TileMatch = struct {
    /// The center of the tile in the reference picture.
    center: Point,
    /// The content of the tile lies at `center + shift` in the other picture.
    shift: Point,
    /// The correlation at the best position, -1 to 1.
    correlation: f32,
    /// True when the tile has enough structure in the reference picture.
    textured: bool,
    /// True when the tile is textured, matches well, and agrees with the transform.
    inlier: bool,
};

pub const Registration = struct {
    tile: u32,
    tiles_wide: u32,
    tiles_high: u32,
    /// One match per tile of the full-size level, row after row.
    matches: []TileMatch,
    /// From a position in the reference picture to the same content in the other
    /// picture. The identity when the fit had too few tiles.
    transform: Homography,
    /// True when the transform comes from a fit and not from the fallback.
    fitted: bool,
    textured_tiles: u32,
    /// The textured tiles whose content lies inside the other picture, by the
    /// transform. Only these tiles can match.
    comparable_tiles: u32,
    inlier_tiles: u32,
    /// The root mean square distance of the inlier tiles from the transform, in pixels.
    residual: f32,

    pub fn deinit(self: Registration, allocator: Allocator) void {
        allocator.free(self.matches);
    }

    /// The fraction of the textured tiles that the transform explains. Two pictures
    /// of the same page give a high value; two different pages give a low value
    /// even when their layout is the same, because the text differs.
    pub fn matchedFraction(self: Registration) f32 {
        if (self.comparable_tiles == 0) return 0;
        return @as(f32, @floatFromInt(self.inlier_tiles)) / @as(f32, @floatFromInt(self.comparable_tiles));
    }
};

/// A smooth field of small shifts on the tile grid: what the tiles moved after the
/// plane transform. It holds the bend of the paper between two frames.
pub const ShiftGrid = struct {
    tile: u32,
    tiles_wide: u32,
    tiles_high: u32,
    /// One shift per tile, row after row, for the center of the tile.
    shifts: []Point,

    pub fn deinit(self: ShiftGrid, allocator: Allocator) void {
        allocator.free(self.shifts);
    }

    /// The shift at a position of the reference picture, bilinear between the tile centers.
    pub fn sample(self: ShiftGrid, p: Point) Point {
        const tile: f32 = @floatFromInt(self.tile);
        const half = 0.5 * (tile - 1);
        const gx = std.math.clamp((p.x - half) / tile, 0, @as(f32, @floatFromInt(self.tiles_wide - 1)));
        const gy = std.math.clamp((p.y - half) / tile, 0, @as(f32, @floatFromInt(self.tiles_high - 1)));
        const x0: usize = @intFromFloat(gx);
        const y0: usize = @intFromFloat(gy);
        const x1 = @min(x0 + 1, self.tiles_wide - 1);
        const y1 = @min(y0 + 1, self.tiles_high - 1);
        const fx = gx - @as(f32, @floatFromInt(x0));
        const fy = gy - @as(f32, @floatFromInt(y0));
        const top = self.shifts[y0 * self.tiles_wide + x0].lerp(self.shifts[y0 * self.tiles_wide + x1], fx);
        const bottom = self.shifts[y1 * self.tiles_wide + x0].lerp(self.shifts[y1 * self.tiles_wide + x1], fx);
        return top.lerp(bottom, fy);
    }
};

// endregion: options and results

// region: tile statistics

const TileStats = struct {
    sum: u32,
    sum_squares: u64,
    count: u32,

    fn variance(self: TileStats) f32 {
        const n: f64 = @floatFromInt(self.count);
        const mean = @as(f64, @floatFromInt(self.sum)) / n;
        return @floatCast(@max(0, @as(f64, @floatFromInt(self.sum_squares)) / n - mean * mean));
    }
};

fn tileStats(plane: PlaneView, x: usize, y: usize, side: usize) TileStats {
    var sum: u32 = 0;
    var sum_squares: u64 = 0;
    for (0..side) |row| {
        const pixels = plane.data[(y + row) * plane.stride + x ..][0..side];
        for (pixels) |value| {
            sum += value;
            sum_squares += @as(u32, value) * value;
        }
    }
    return .{ .sum = sum, .sum_squares = sum_squares, .count = @intCast(side * side) };
}

/// The zero-mean normalized cross-correlation of a reference tile at (rx, ry) with
/// the tile of the other picture at (ox, oy). Returns null when the other tile is
/// partly outside its picture or one tile is flat.
fn correlate(
    reference: PlaneView,
    reference_stats: TileStats,
    rx: usize,
    ry: usize,
    other: PlaneView,
    ox: i32,
    oy: i32,
    side: usize,
) ?f32 {
    if (ox < 0 or oy < 0) return null;
    const other_x: usize = @intCast(ox);
    const other_y: usize = @intCast(oy);
    if (other_x + side > other.width or other_y + side > other.height) return null;

    var sum_other: u32 = 0;
    var sum_other_squares: u64 = 0;
    var sum_product: u64 = 0;
    for (0..side) |row| {
        const a = reference.data[(ry + row) * reference.stride + rx ..][0..side];
        const b = other.data[(other_y + row) * other.stride + other_x ..][0..side];
        for (a, b) |value_a, value_b| {
            sum_other += value_b;
            sum_other_squares += @as(u32, value_b) * value_b;
            sum_product += @as(u32, value_a) * value_b;
        }
    }
    const n: f64 = @floatFromInt(side * side);
    const mean_a = @as(f64, @floatFromInt(reference_stats.sum)) / n;
    const mean_b = @as(f64, @floatFromInt(sum_other)) / n;
    const variance_a = @as(f64, @floatFromInt(reference_stats.sum_squares)) / n - mean_a * mean_a;
    const variance_b = @as(f64, @floatFromInt(sum_other_squares)) / n - mean_b * mean_b;
    if (variance_a < flat_variance or variance_b < flat_variance) return null;
    const covariance = @as(f64, @floatFromInt(sum_product)) / n - mean_a * mean_b;
    return @floatCast(covariance / @sqrt(variance_a * variance_b));
}

/// A tile with a luma variance below this value has no structure at all.
const flat_variance = 1.0;

// endregion: tile statistics

// region: pyramid search

/// The shift of each tile of one pyramid level, in pixels of that level.
const LevelShifts = struct {
    tiles_wide: usize,
    tiles_high: usize,
    shift_x: []i32,
    shift_y: []i32,
    correlation: []f32,

    fn init(allocator: Allocator, tiles_wide: usize, tiles_high: usize) Allocator.Error!LevelShifts {
        const count = tiles_wide * tiles_high;
        const shift_x = try allocator.alloc(i32, count);
        errdefer allocator.free(shift_x);
        const shift_y = try allocator.alloc(i32, count);
        errdefer allocator.free(shift_y);
        const correlation = try allocator.alloc(f32, count);
        @memset(shift_x, 0);
        @memset(shift_y, 0);
        @memset(correlation, -1);
        return .{ .tiles_wide = tiles_wide, .tiles_high = tiles_high, .shift_x = shift_x, .shift_y = shift_y, .correlation = correlation };
    }

    fn deinit(self: LevelShifts, allocator: Allocator) void {
        allocator.free(self.shift_x);
        allocator.free(self.shift_y);
        allocator.free(self.correlation);
    }
};

const Candidate = struct { x: i32, y: i32 };

/// The start positions for a tile: twice the shift of its parent tile at the level
/// above, and of the two parents next to that one on the side where the tile lies.
fn startCandidates(parent: ?*const LevelShifts, tile_x: usize, tile_y: usize, out: *[max_candidates]Candidate) usize {
    out[0] = .{ .x = 0, .y = 0 };
    const coarse = parent orelse return 1;
    if (coarse.tiles_wide == 0 or coarse.tiles_high == 0) return 1;
    const px = @min(tile_x / 2, coarse.tiles_wide - 1);
    const py = @min(tile_y / 2, coarse.tiles_high - 1);
    var count: usize = 0;
    const Add = struct {
        fn one(shifts: *const LevelShifts, x: usize, y: usize, list: *[max_candidates]Candidate, len: *usize) void {
            const index = y * shifts.tiles_wide + x;
            const candidate: Candidate = .{ .x = 2 * shifts.shift_x[index], .y = 2 * shifts.shift_y[index] };
            for (list[0..len.*]) |existing| {
                if (existing.x == candidate.x and existing.y == candidate.y) return;
            }
            list[len.*] = candidate;
            len.* += 1;
        }
    };
    Add.one(coarse, px, py, out, &count);
    const neighbour_x: ?usize = if (tile_x % 2 == 1) (if (px + 1 < coarse.tiles_wide) px + 1 else null) else (if (px > 0) px - 1 else null);
    const neighbour_y: ?usize = if (tile_y % 2 == 1) (if (py + 1 < coarse.tiles_high) py + 1 else null) else (if (py > 0) py - 1 else null);
    if (neighbour_x) |nx| Add.one(coarse, nx, py, out, &count);
    if (neighbour_y) |ny| Add.one(coarse, px, ny, out, &count);
    return count;
}

const max_candidates = 3;

fn searchLevel(
    allocator: Allocator,
    reference: PlaneView,
    other: PlaneView,
    parent: ?*const LevelShifts,
    tile: usize,
    radius: i32,
) Allocator.Error!LevelShifts {
    const tiles_wide = reference.width / tile;
    const tiles_high = reference.height / tile;
    const shifts = try LevelShifts.init(allocator, tiles_wide, tiles_high);
    for (0..tiles_high) |tile_y| {
        for (0..tiles_wide) |tile_x| {
            const index = tile_y * tiles_wide + tile_x;
            const rx = tile_x * tile;
            const ry = tile_y * tile;
            const stats = tileStats(reference, rx, ry, tile);

            var candidates: [max_candidates]Candidate = undefined;
            const candidate_count = startCandidates(parent, tile_x, tile_y, &candidates);
            // The tile keeps the shift of its parent when it has no structure.
            shifts.shift_x[index] = candidates[0].x;
            shifts.shift_y[index] = candidates[0].y;
            if (stats.variance() < flat_variance) continue;

            var best: f32 = -2;
            for (candidates[0..candidate_count]) |start| {
                var dy: i32 = -radius;
                while (dy <= radius) : (dy += 1) {
                    var dx: i32 = -radius;
                    while (dx <= radius) : (dx += 1) {
                        const shift_x = start.x + dx;
                        const shift_y = start.y + dy;
                        const value = correlate(
                            reference,
                            stats,
                            rx,
                            ry,
                            other,
                            @as(i32, @intCast(rx)) + shift_x,
                            @as(i32, @intCast(ry)) + shift_y,
                            tile,
                        ) orelse continue;
                        if (value > best) {
                            best = value;
                            shifts.shift_x[index] = shift_x;
                            shifts.shift_y[index] = shift_y;
                        }
                    }
                }
            }
            shifts.correlation[index] = best;
        }
    }
    return shifts;
}

/// The position of the top of a parabola through three values at -1, 0, and 1.
/// The result is between -0.5 and 0.5.
fn parabolaPeak(before: f32, at: f32, after: f32) f32 {
    const curvature = before - 2 * at + after;
    if (!(curvature < -parabola_epsilon)) return 0;
    return std.math.clamp(0.5 * (before - after) / curvature, -0.5, 0.5);
}

const parabola_epsilon = 1e-6;

// endregion: pyramid search

// region: register

/// Register `other` to `reference`. The two planes must have the same size, and the
/// same content must lie at almost the same place in the two.
pub fn register(allocator: Allocator, reference: PlaneView, other: PlaneView, options: Options) Allocator.Error!Registration {
    std.debug.assert(reference.width == other.width and reference.height == other.height);
    const tile: usize = options.tile;

    // The pyramids. Level 0 is the full size. The smallest level keeps two tiles or
    // more along each side.
    var reference_levels: [max_pyramid_levels]PlaneView = undefined;
    var other_levels: [max_pyramid_levels]PlaneView = undefined;
    var owned: [2 * max_pyramid_levels]?Plane = @splat(null);
    defer for (owned) |maybe_plane| if (maybe_plane) |plane| plane.deinit(allocator);
    reference_levels[0] = reference;
    other_levels[0] = other;
    var level_count: usize = 1;
    const wanted_levels = @min(@as(usize, options.max_levels), max_pyramid_levels);
    while (level_count < wanted_levels) : (level_count += 1) {
        const previous = reference_levels[level_count - 1];
        if (previous.width / 2 < 2 * tile or previous.height / 2 < 2 * tile) break;
        const reference_half = try raster.halve(allocator, previous);
        owned[2 * level_count] = reference_half;
        const other_half = try raster.halve(allocator, other_levels[level_count - 1]);
        owned[2 * level_count + 1] = other_half;
        reference_levels[level_count] = reference_half.view();
        other_levels[level_count] = other_half.view();
    }

    // From the smallest level to the full size.
    var parent: ?LevelShifts = null;
    defer if (parent) |shifts| shifts.deinit(allocator);
    var level = level_count;
    while (level > 0) {
        level -= 1;
        const radius: i32 = if (level == level_count - 1 and level_count > 1)
            options.coarse_radius
        else if (level == 0)
            options.fine_radius
        else
            options.middle_radius;
        // With one level only, the full size gets the wide search.
        const effective_radius = if (level_count == 1) @as(i32, options.coarse_radius) else radius;
        const shifts = try searchLevel(
            allocator,
            reference_levels[level],
            other_levels[level],
            if (parent) |*coarse| coarse else null,
            tile,
            effective_radius,
        );
        if (parent) |coarse| coarse.deinit(allocator);
        parent = shifts;
    }
    const finest = parent.?;

    // The matches of the full size, with a position between pixels.
    const tiles_wide = finest.tiles_wide;
    const tiles_high = finest.tiles_high;
    const matches = try allocator.alloc(TileMatch, tiles_wide * tiles_high);
    errdefer allocator.free(matches);
    var textured_tiles: u32 = 0;
    const min_variance = options.min_texture * options.min_texture;
    for (0..tiles_high) |tile_y| {
        for (0..tiles_wide) |tile_x| {
            const index = tile_y * tiles_wide + tile_x;
            const rx = tile_x * tile;
            const ry = tile_y * tile;
            const stats = tileStats(reference, rx, ry, tile);
            const textured = stats.variance() >= min_variance;
            if (textured) textured_tiles += 1;
            var shift = Point.init(@floatFromInt(finest.shift_x[index]), @floatFromInt(finest.shift_y[index]));
            const correlation = finest.correlation[index];
            if (textured and correlation >= options.min_correlation) {
                const ox = @as(i32, @intCast(rx)) + finest.shift_x[index];
                const oy = @as(i32, @intCast(ry)) + finest.shift_y[index];
                const left = correlate(reference, stats, rx, ry, other, ox - 1, oy, tile);
                const right = correlate(reference, stats, rx, ry, other, ox + 1, oy, tile);
                const up = correlate(reference, stats, rx, ry, other, ox, oy - 1, tile);
                const down = correlate(reference, stats, rx, ry, other, ox, oy + 1, tile);
                if (left != null and right != null) shift.x += parabolaPeak(left.?, correlation, right.?);
                if (up != null and down != null) shift.y += parabolaPeak(up.?, correlation, down.?);
            }
            const half: f32 = 0.5 * @as(f32, @floatFromInt(tile - 1));
            matches[index] = .{
                .center = Point.init(@as(f32, @floatFromInt(rx)) + half, @as(f32, @floatFromInt(ry)) + half),
                .shift = shift,
                .correlation = correlation,
                .textured = textured,
                .inlier = false,
            };
        }
    }

    var result: Registration = .{
        .tile = options.tile,
        .tiles_wide = @intCast(tiles_wide),
        .tiles_high = @intCast(tiles_high),
        .matches = matches,
        .transform = Homography.identity,
        .fitted = false,
        .textured_tiles = textured_tiles,
        .comparable_tiles = textured_tiles,
        .inlier_tiles = 0,
        .residual = 0,
    };
    try fitTransform(allocator, &result, options, reference.width, reference.height);
    return result;
}

const max_pyramid_levels = 8;

/// Fit one plane transform to the tile matches. Tiles far from the transform lose
/// their vote, and the fit runs again, a few times.
fn fitTransform(allocator: Allocator, result: *Registration, options: Options, width: u32, height: u32) Allocator.Error!void {
    const count = result.matches.len;
    const sources = try allocator.alloc(Point, count);
    defer allocator.free(sources);
    const targets = try allocator.alloc(Point, count);
    defer allocator.free(targets);
    const weights = try allocator.alloc(f32, count);
    defer allocator.free(weights);

    var usable: usize = 0;
    for (result.matches, 0..) |match, index| {
        sources[index] = match.center;
        targets[index] = match.center.add(match.shift);
        const good = match.textured and match.correlation >= options.min_correlation;
        weights[index] = if (good) 1 else 0;
        if (good) usable += 1;
    }
    if (usable < min_fit_tiles) return;

    var transform = Homography.identity;
    var fitted = false;
    var tolerance: f32 = first_fit_tolerance;
    for (0..fit_rounds) |_| {
        const candidate = Homography.fit(sources, targets, weights) orelse break;
        transform = candidate;
        fitted = true;
        var remaining: usize = 0;
        for (result.matches, 0..) |match, index| {
            const good = match.textured and match.correlation >= options.min_correlation;
            const distance = transform.apply(sources[index]).distance(targets[index]);
            const keep = good and distance <= tolerance;
            weights[index] = if (keep) 1 else 0;
            if (keep) remaining += 1;
        }
        if (remaining < min_fit_tiles) break;
        tolerance = @max(options.inlier_distance, tolerance * fit_tolerance_decay);
    }
    if (!fitted) return;

    var inliers: u32 = 0;
    var comparable: u32 = 0;
    var squared: f64 = 0;
    const half_tile = 0.5 * @as(f32, @floatFromInt(result.tile));
    const max_x = @as(f32, @floatFromInt(width)) - 1 - half_tile;
    const max_y = @as(f32, @floatFromInt(height)) - 1 - half_tile;
    for (result.matches, 0..) |*match, index| {
        const good = match.textured and match.correlation >= options.min_correlation;
        const predicted = transform.apply(sources[index]);
        const distance = predicted.distance(targets[index]);
        match.inlier = good and distance <= options.inlier_distance;
        if (match.inlier) {
            inliers += 1;
            squared += distance * distance;
        }
        // A tile at the border can have its content outside the other picture.
        const inside = predicted.x >= half_tile and predicted.y >= half_tile and predicted.x <= max_x and predicted.y <= max_y;
        if (match.textured and (inside or match.inlier)) comparable += 1;
    }
    result.transform = transform;
    result.fitted = true;
    result.comparable_tiles = comparable;
    result.inlier_tiles = inliers;
    result.residual = if (inliers > 0) @floatCast(@sqrt(squared / @as(f64, @floatFromInt(inliers)))) else 0;
}

/// A plane transform has 8 unknowns: 4 tiles fix it, more tiles make it safe.
const min_fit_tiles = 12;
const fit_rounds = 6;
/// The first rounds allow far tiles, then the limit falls to the inlier distance.
const first_fit_tolerance = 12.0;
const fit_tolerance_decay = 0.5;

// endregion: register

// region: residual grid

/// The shifts that remain after the plane transform, as a smooth grid. The tiles
/// that support the transform give their own value; the other tiles take the mean
/// of their neighbours. Returns null when the registration has no fitted transform.
pub fn residualGrid(allocator: Allocator, registration: *const Registration) Allocator.Error!?ShiftGrid {
    if (!registration.fitted or registration.inlier_tiles == 0) return null;
    const wide: usize = registration.tiles_wide;
    const high: usize = registration.tiles_high;
    const count = wide * high;
    const shifts = try allocator.alloc(Point, count);
    errdefer allocator.free(shifts);
    const known = try allocator.alloc(bool, count);
    defer allocator.free(known);
    const scratch = try allocator.alloc(Point, count);
    defer allocator.free(scratch);

    // Only a tile with a strong match gives its own value. A tile at the border of
    // the page matches on a part of its content and can be a pixel off.
    var known_count: usize = 0;
    for (registration.matches, 0..) |match, index| {
        known[index] = match.inlier and match.correlation >= grid_min_correlation;
        if (known[index]) known_count += 1;
        shifts[index] = if (known[index])
            match.center.add(match.shift).sub(registration.transform.apply(match.center))
        else
            Point.zero;
    }
    if (known_count == 0) {
        allocator.free(shifts);
        return null;
    }

    // Fill the tiles without a value from their neighbours, ring after ring.
    var remaining = count - known_count;
    var round: usize = 0;
    while (remaining > 0 and round < max_fill_rounds) : (round += 1) {
        @memcpy(scratch, shifts);
        var filled_now: usize = 0;
        for (0..high) |y| {
            for (0..wide) |x| {
                const index = y * wide + x;
                if (known[index]) continue;
                var sum = Point.zero;
                var neighbours: f32 = 0;
                const y_from = y -| 1;
                const y_to = @min(y + 1, high - 1);
                const x_from = x -| 1;
                const x_to = @min(x + 1, wide - 1);
                for (y_from..y_to + 1) |ny| {
                    for (x_from..x_to + 1) |nx| {
                        const neighbour = ny * wide + nx;
                        if (!known[neighbour]) continue;
                        sum = sum.add(scratch[neighbour]);
                        neighbours += 1;
                    }
                }
                if (neighbours == 0) continue;
                shifts[index] = sum.scale(1.0 / neighbours);
                filled_now += 1;
            }
        }
        if (filled_now == 0) break;
        // The new values count as known from the next round on.
        for (0..count) |index| {
            if (!known[index] and (shifts[index].x != scratch[index].x or shifts[index].y != scratch[index].y or filled_now == remaining)) {
                known[index] = true;
            }
        }
        remaining -= @min(remaining, filled_now);
    }

    // A 3x3 median removes a single wrong tile.
    @memcpy(scratch, shifts);
    for (0..high) |y| {
        for (0..wide) |x| {
            var values_x: [9]f32 = undefined;
            var values_y: [9]f32 = undefined;
            var neighbours: usize = 0;
            const y_from = y -| 1;
            const y_to = @min(y + 1, high - 1);
            const x_from = x -| 1;
            const x_to = @min(x + 1, wide - 1);
            for (y_from..y_to + 1) |ny| {
                for (x_from..x_to + 1) |nx| {
                    values_x[neighbours] = scratch[ny * wide + nx].x;
                    values_y[neighbours] = scratch[ny * wide + nx].y;
                    neighbours += 1;
                }
            }
            std.mem.sort(f32, values_x[0..neighbours], {}, std.sort.asc(f32));
            std.mem.sort(f32, values_y[0..neighbours], {}, std.sort.asc(f32));
            shifts[y * wide + x] = Point.init(values_x[neighbours / 2], values_y[neighbours / 2]);
        }
    }

    // Then 3x3 means: the bend of paper is smooth, the noise of a tile is not.
    for (0..smooth_rounds) |_| {
        @memcpy(scratch, shifts);
        for (0..high) |y| {
            for (0..wide) |x| {
                var sum = Point.zero;
                var neighbours: f32 = 0;
                const y_from = y -| 1;
                const y_to = @min(y + 1, high - 1);
                const x_from = x -| 1;
                const x_to = @min(x + 1, wide - 1);
                for (y_from..y_to + 1) |ny| {
                    for (x_from..x_to + 1) |nx| {
                        sum = sum.add(scratch[ny * wide + nx]);
                        neighbours += 1;
                    }
                }
                shifts[y * wide + x] = sum.scale(1.0 / neighbours);
            }
        }
    }
    return .{
        .tile = registration.tile,
        .tiles_wide = registration.tiles_wide,
        .tiles_high = registration.tiles_high,
        .shifts = shifts,
    };
}

const max_fill_rounds = 64;
const smooth_rounds = 2;
/// A tile gives its own value to the grid only above this correlation.
const grid_min_correlation = 0.75;

// endregion: residual grid

// region: tests

const testing = std.testing;

/// A picture with blobs of random brightness at random places, smooth enough for
/// sampling between pixels.
fn testPicture(allocator: Allocator, width: u32, height: u32, seed: u64) !Plane {
    const plane = try Plane.initFilled(allocator, width, height, 128);
    var random = std.Random.DefaultPrng.init(seed);
    const blob_count = width * height / 40;
    for (0..blob_count) |_| {
        const cx = random.random().uintLessThan(u32, width);
        const cy = random.random().uintLessThan(u32, height);
        const value = random.random().int(u8);
        const radius: u32 = 1 + random.random().uintLessThan(u32, 3);
        var y = cy -| radius;
        while (y <= @min(cy + radius, height - 1)) : (y += 1) {
            var x = cx -| radius;
            while (x <= @min(cx + radius, width - 1)) : (x += 1) plane.set(x, y, value);
        }
    }
    return plane;
}

/// The picture seen through `to_source`: the output pixel p shows the source at `to_source(p)`.
fn warpPicture(allocator: Allocator, source: Plane, to_source: Homography) !Plane {
    const out = try Plane.init(allocator, source.width, source.height);
    for (0..out.height) |y| {
        for (0..out.width) |x| {
            const p = to_source.apply(Point.init(@floatFromInt(x), @floatFromInt(y)));
            out.set(x, y, @intFromFloat(std.math.clamp(source.view().sample(p.x, p.y) + 0.5, 0, 255)));
        }
    }
    return out;
}

test "register finds a shift between pixels" {
    const reference = try testPicture(testing.allocator, 384, 512, 1);
    defer reference.deinit(testing.allocator);
    // The other picture shows the content of the reference moved by (+5.4, -3.3).
    const shift = Point.init(5.4, -3.3);
    const other = try warpPicture(testing.allocator, reference, Homography.translation(-shift.x, -shift.y));
    defer other.deinit(testing.allocator);

    const result = try register(testing.allocator, reference.view(), other.view(), .{});
    defer result.deinit(testing.allocator);
    try testing.expect(result.fitted);
    try testing.expect(result.matchedFraction() > 0.9);
    const mapped = result.transform.apply(Point.init(200, 250));
    try testing.expectApproxEqAbs(200 + shift.x, mapped.x, 0.15);
    try testing.expectApproxEqAbs(250 + shift.y, mapped.y, 0.15);
}

test "register finds a perspective change and a large shift" {
    const reference = try testPicture(testing.allocator, 512, 640, 2);
    defer reference.deinit(testing.allocator);
    // The same page seen with other corners: up to 40 pixels of difference.
    const from = geometry.Quad.rect(512, 640);
    const to: geometry.Quad = .{
        .tl = Point.init(22, 14),
        .tr = Point.init(500, -18),
        .br = Point.init(540, 660),
        .bl = Point.init(-12, 630),
    };
    const reference_to_other = Homography.fromQuads(from, to).?;
    const other = try warpPicture(testing.allocator, reference, reference_to_other.inverse().?);
    defer other.deinit(testing.allocator);

    const result = try register(testing.allocator, reference.view(), other.view(), .{});
    defer result.deinit(testing.allocator);
    try testing.expect(result.fitted);
    try testing.expect(result.matchedFraction() > 0.7);
    for ([_]Point{ Point.init(100, 100), Point.init(400, 500), Point.init(256, 320) }) |p| {
        const expected = reference_to_other.apply(p);
        const actual = result.transform.apply(p);
        try testing.expectApproxEqAbs(expected.x, actual.x, 0.3);
        try testing.expectApproxEqAbs(expected.y, actual.y, 0.3);
    }
}

test "the residual grid of a plain shift is near zero" {
    const reference = try testPicture(testing.allocator, 384, 512, 7);
    defer reference.deinit(testing.allocator);
    const other = try warpPicture(testing.allocator, reference, Homography.translation(-4.0, 2.5));
    defer other.deinit(testing.allocator);
    const result = try register(testing.allocator, reference.view(), other.view(), .{});
    defer result.deinit(testing.allocator);
    const grid = (try residualGrid(testing.allocator, &result)).?;
    defer grid.deinit(testing.allocator);
    for (grid.shifts) |shift| {
        try testing.expect(@abs(shift.x) < 0.3 and @abs(shift.y) < 0.3);
    }
    const middle = grid.sample(Point.init(190, 250));
    try testing.expect(@abs(middle.x) < 0.3 and @abs(middle.y) < 0.3);
}

test "two different pictures do not register" {
    const reference = try testPicture(testing.allocator, 384, 512, 3);
    defer reference.deinit(testing.allocator);
    const other = try testPicture(testing.allocator, 384, 512, 4);
    defer other.deinit(testing.allocator);
    const result = try register(testing.allocator, reference.view(), other.view(), .{});
    defer result.deinit(testing.allocator);
    try testing.expect(result.matchedFraction() < 0.1);
}

test "the same picture with another exposure registers" {
    const reference = try testPicture(testing.allocator, 256, 320, 5);
    defer reference.deinit(testing.allocator);
    const other = try Plane.init(testing.allocator, reference.width, reference.height);
    defer other.deinit(testing.allocator);
    for (other.data, reference.data) |*value, source| {
        value.* = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(source)) * 0.7 + 30, 0, 255));
    }
    const result = try register(testing.allocator, reference.view(), other.view(), .{});
    defer result.deinit(testing.allocator);
    try testing.expect(result.matchedFraction() > 0.95);
    const mapped = result.transform.apply(Point.init(100, 100));
    try testing.expectApproxEqAbs(@as(f32, 100), mapped.x, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 100), mapped.y, 0.1);
}

// endregion: tests
