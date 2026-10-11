//! Find the spreads that the video shows more than one time, and keep the best copy.
//!
//! A spread appears two times when the camera moves or a hand passes in the middle
//! of its stable time, or when the user shows it again. Two copies are the same
//! spread when their pages register: the text of one lies on the text of the other.
//! Two different spreads with the same pictures do not register, because their
//! text differs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const image = @import("image.zig");
const detect = @import("detect.zig");
const register = @import("register.zig");
const geometry = @import("geometry.zig");

pub const Options = struct {
    /// Two copies of a spread can differ much: a finger on an edge or a lifted page
    /// moves the corners of a quad by a tenth of the page and more. So the search
    /// starts wide, with small tiles that each find their own shift, and the fit
    /// allows the distance that a bent page gives.
    register: register.Options = .{
        .tile = 16,
        .max_levels = 4,
        .coarse_radius = 16,
        .middle_radius = 2,
        .fine_radius = 1,
        .inlier_distance = 3.0,
    },
    /// Two pages are the same when the registration explains this fraction of the
    /// textured tiles.
    min_matched_fraction: f32 = 0.5,
    /// The smallest matched fraction of the weaker page of a spread. Two different
    /// spreads with the same pictures reach about 0.25.
    min_weaker_fraction: f32 = 0.35,
    /// A weak spread is compared with this many kept spreads before it. A strong
    /// spread is compared with the one before it and with weak spreads only.
    lookback: u8 = 4,
};

pub const Candidate = struct {
    kind: detect.LayoutKind,
    /// A small luma picture of each page. All signatures have the same size.
    signatures: [detect.max_pages]image.PlaneView,
    /// Higher is better: the copy with the higher value stays.
    quality: f32,
    /// A short or partly covered view. It can be a copy of a spread that is not next to it.
    weak: bool,
};

/// One comparison of two candidates, for the debug table.
pub const Comparison = struct {
    first: u32,
    second: u32,
    same: bool,
    /// The matched fraction of each page pair; -1 for a pair that was not compared.
    matched: [detect.max_pages]f32,
};

pub const Resolution = struct {
    /// The indexes of the candidates to keep, in the order of the pages of the document.
    kept: []u32,
    /// For each candidate, the kept candidate that shows the same spread. A kept
    /// candidate is its own owner.
    owner: []u32,

    pub fn deinit(self: Resolution, allocator: Allocator) void {
        allocator.free(self.kept);
        allocator.free(self.owner);
    }
};

/// Find the duplicates. `log`, when given, gets one entry for each comparison.
pub fn resolve(
    allocator: Allocator,
    candidates: []const Candidate,
    options: Options,
    log: ?*std.ArrayList(Comparison),
) Allocator.Error!Resolution {
    var kept: std.ArrayList(u32) = .empty;
    errdefer kept.deinit(allocator);
    const owner = try allocator.alloc(u32, candidates.len);
    errdefer allocator.free(owner);
    for (owner, 0..) |*value, index| value.* = @intCast(index);

    for (candidates, 0..) |*candidate, index| {
        var duplicate_position: ?usize = null;
        var back: usize = 1;
        while (back <= options.lookback and back <= kept.items.len) : (back += 1) {
            const position = kept.items.len - back;
            const earlier_index = kept.items[position];
            const earlier = &candidates[earlier_index];
            if (back > 1 and !candidate.weak and !earlier.weak) continue;
            var comparison: Comparison = .{
                .first = earlier_index,
                .second = @intCast(index),
                .same = false,
                .matched = @splat(-1),
            };
            comparison.same = try sameSpread(allocator, earlier, candidate, options, &comparison.matched);
            if (log) |list| try list.append(allocator, comparison);
            if (comparison.same) {
                duplicate_position = position;
                break;
            }
        }
        if (duplicate_position) |position| {
            const earlier_index = kept.items[position];
            if (isBetter(candidate, &candidates[earlier_index])) {
                // The better copy takes its own place in the order, and all copies
                // of the spread now belong to it.
                _ = kept.orderedRemove(position);
                try kept.append(allocator, @intCast(index));
                for (owner[0..index]) |*value| {
                    if (value.* == earlier_index) value.* = @intCast(index);
                }
            } else {
                owner[index] = earlier_index;
            }
            continue;
        }
        try kept.append(allocator, @intCast(index));
    }
    return .{ .kept = try kept.toOwnedSlice(allocator), .owner = owner };
}

/// A spread with two pages has more of the document than one page of it.
fn isBetter(a: *const Candidate, b: *const Candidate) bool {
    if (a.kind != b.kind) return a.kind == .spread;
    return a.quality > b.quality;
}

/// True when the two candidates show the same pages. For two spreads, each page
/// must match. For one page and a spread, the page must match one page of the spread.
fn sameSpread(
    allocator: Allocator,
    a: *const Candidate,
    b: *const Candidate,
    options: Options,
    matched: *[detect.max_pages]f32,
) Allocator.Error!bool {
    if (a.kind == b.kind) {
        var smallest: f32 = 1;
        var largest: f32 = 0;
        for (0..a.kind.pageCount()) |page| {
            matched[page] = try matchedFraction(allocator, a.signatures[page], b.signatures[page], options);
            smallest = @min(smallest, matched[page]);
            largest = @max(largest, matched[page]);
        }
        // The two pages of a spread are one sheet of paper side by side. When one page
        // matches well, a weaker match of the other page (a hand lies on it) is enough.
        return largest >= options.min_matched_fraction and smallest >= options.min_weaker_fraction;
    }
    const single = if (a.kind == .single) a else b;
    const spread = if (a.kind == .single) b else a;
    for (0..spread.kind.pageCount()) |page| {
        matched[page] = try matchedFraction(allocator, spread.signatures[page], single.signatures[0], options);
        if (matched[page] >= options.min_matched_fraction) return true;
    }
    return false;
}

fn matchedFraction(allocator: Allocator, a: image.PlaneView, b: image.PlaneView, options: Options) Allocator.Error!f32 {
    if (a.width != b.width or a.height != b.height) return 0;
    var fraction: f32 = 0;
    // The first round finds the rough transform between the two copies. Each next
    // round starts from `b` moved by that transform, so that the tiles of a real
    // copy fall into the search range. Two different pages gain nothing: the parts
    // that matched in the first round (pictures) match again, the text does not.
    var total = geometry.Homography.identity;
    var moved: ?image.Plane = null;
    defer if (moved) |plane| plane.deinit(allocator);
    for (0..alignment_rounds) |round| {
        const other = if (moved) |plane| plane.view() else b;
        const result = try register.register(allocator, a, other, options.register);
        defer result.deinit(allocator);
        if (!result.fitted or result.comparable_tiles < min_comparable_tiles) return fraction;
        fraction = result.matchedFraction();
        if (round + 1 == alignment_rounds or result.inlier_tiles < min_tiles_to_continue) break;

        // `total` goes from a position in `a` to the same content in `b`.
        total = total.mul(result.transform);
        const next = try image.Plane.init(allocator, a.width, a.height);
        for (0..next.height) |y| {
            const row = next.row(y);
            for (row, 0..) |*value, x| {
                const p = total.apply(geometry.Point.init(@floatFromInt(x), @floatFromInt(y)));
                value.* = @intFromFloat(std.math.clamp(b.sample(p.x, p.y) + 0.5, 0, 255));
            }
        }
        if (moved) |plane| plane.deinit(allocator);
        moved = next;
    }
    return fraction;
}

const alignment_rounds = 3;
/// A transform from fewer tiles than this is not safe enough to continue with.
const min_tiles_to_continue = 16;

/// A page with fewer textured tiles than this has too little content to compare.
const min_comparable_tiles = 12;

// region: tests

const testing = std.testing;

/// A page of random blobs. The same seed gives the same page.
fn testSignature(allocator: Allocator, seed: u64, shift: u32) !image.Plane {
    const width = 256;
    const height = 320;
    const plane = try image.Plane.initFilled(allocator, width, height, 200);
    var random = std.Random.DefaultPrng.init(seed);
    for (0..1500) |_| {
        const cx = shift + 8 + random.random().uintLessThan(u32, width - 24);
        const cy = 8 + random.random().uintLessThan(u32, height - 16);
        const value = random.random().uintLessThan(u8, 120);
        for (cy - 2..cy + 3) |y| {
            for (cx - 2..cx + 3) |x| plane.set(x, y, value);
        }
    }
    return plane;
}

test "a spread that appears two times stays one time" {
    var planes: [6]image.Plane = undefined;
    // Spread A, spread A again with a small shift, then spread B.
    planes[0] = try testSignature(testing.allocator, 1, 0);
    planes[1] = try testSignature(testing.allocator, 2, 0);
    planes[2] = try testSignature(testing.allocator, 1, 3);
    planes[3] = try testSignature(testing.allocator, 2, 3);
    planes[4] = try testSignature(testing.allocator, 3, 0);
    planes[5] = try testSignature(testing.allocator, 4, 0);
    defer for (planes) |plane| plane.deinit(testing.allocator);

    const candidates = [_]Candidate{
        .{ .kind = .spread, .signatures = .{ planes[0].view(), planes[1].view() }, .quality = 0.4, .weak = false },
        .{ .kind = .spread, .signatures = .{ planes[2].view(), planes[3].view() }, .quality = 0.7, .weak = false },
        .{ .kind = .spread, .signatures = .{ planes[4].view(), planes[5].view() }, .quality = 0.5, .weak = false },
    };
    var log: std.ArrayList(Comparison) = .empty;
    defer log.deinit(testing.allocator);
    const resolution = try resolve(testing.allocator, &candidates, .{}, &log);
    defer resolution.deinit(testing.allocator);
    // The second copy of spread A is better, so it stays, and it owns the first copy.
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, resolution.kept);
    try testing.expectEqualSlices(u32, &.{ 1, 1, 2 }, resolution.owner);
    try testing.expectEqual(@as(usize, 2), log.items.len);
    try testing.expect(log.items[0].same);
    try testing.expect(!log.items[1].same);
}

test "a single page that is one half of the spread before it is dropped" {
    const left = try testSignature(testing.allocator, 11, 0);
    defer left.deinit(testing.allocator);
    const right = try testSignature(testing.allocator, 12, 0);
    defer right.deinit(testing.allocator);
    const right_again = try testSignature(testing.allocator, 12, 2);
    defer right_again.deinit(testing.allocator);

    const candidates = [_]Candidate{
        .{ .kind = .spread, .signatures = .{ left.view(), right.view() }, .quality = 0.5, .weak = false },
        .{ .kind = .single, .signatures = .{ right_again.view(), right_again.view() }, .quality = 0.9, .weak = false },
    };
    const resolution = try resolve(testing.allocator, &candidates, .{}, null);
    defer resolution.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{0}, resolution.kept);
    try testing.expectEqualSlices(u32, &.{ 0, 0 }, resolution.owner);
}

test "a weak early view is replaced by the good view some spreads later" {
    var planes: [8]image.Plane = undefined;
    for (&planes, 0..) |*plane, index| {
        // Candidates 0 and 3 show the same spread (seeds 21 and 22).
        const seed: u64 = switch (index) {
            0, 6 => 21,
            1, 7 => 22,
            else => 30 + index,
        };
        plane.* = try testSignature(testing.allocator, seed, 0);
    }
    defer for (planes) |plane| plane.deinit(testing.allocator);

    const candidates = [_]Candidate{
        .{ .kind = .spread, .signatures = .{ planes[0].view(), planes[1].view() }, .quality = 0.2, .weak = true },
        .{ .kind = .spread, .signatures = .{ planes[2].view(), planes[3].view() }, .quality = 0.5, .weak = false },
        .{ .kind = .spread, .signatures = .{ planes[4].view(), planes[5].view() }, .quality = 0.5, .weak = false },
        .{ .kind = .spread, .signatures = .{ planes[6].view(), planes[7].view() }, .quality = 0.6, .weak = false },
    };
    const resolution = try resolve(testing.allocator, &candidates, .{}, null);
    defer resolution.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, resolution.kept);
    try testing.expectEqualSlices(u32, &.{ 3, 1, 2, 3 }, resolution.owner);
}

// endregion: tests
