//! Find the spreads that the video shows more than one time, and keep the best copy.
//!
//! A spread appears two times when the camera moves or a hand passes in the middle
//! of its stable time, or when the user shows it again. Two copies are the same
//! spread when their pages register: the text of one lies on the text of the other.
//! Two different spreads with the same pictures do not register, because their
//! text differs.
//!
//! Two different pages can also register when one page has a part of the print of
//! the other page at the same place: the two pages of an invoice share the header
//! and the footer, and the half-title of a book has the title of the title page.
//! The other print of the fuller page then lies on blank paper of the other page.
//! Two copies of one page do not show that, except where a finger or the border of
//! the frame hides the paper. See `docs/decisions/0031-print-on-blank-paper.md`.

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
    /// Two pages are different when this fraction of their printed tiles, or more,
    /// lies on blank paper in the other page. In the test videos, the copies of one
    /// page gave at most 0.11, and two different pages that register gave 0.29 and
    /// more.
    max_print_on_blank: f32 = 0.25,
    /// Blank paper has no pixel darker than this luma code. The enhancement makes
    /// blank paper pure white. Print that blur or glare made pale is not blank.
    min_blank_luma: u8 = 248,
    /// The test for blank paper looks this far around a tile, in pixels of the small
    /// picture: the alignment of two copies has an error of a few pixels.
    blank_margin: u32 = 8,
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
    /// For each page, a picture of the signature size with a value that is not zero
    /// for each pixel that does not show the paper: outside the frame, or a finger.
    /// Null: each pixel shows the paper.
    hidden: [detect.max_pages]?image.PlaneView = @splat(null),

    fn pageView(self: *const Candidate, page: usize) PageView {
        return .{ .plane = self.signatures[page], .hidden = self.hidden[page] };
    }
};

/// One comparison of two candidates, for the debug table.
pub const Comparison = struct {
    first: u32,
    second: u32,
    same: bool,
    /// The matched fraction of each page pair; -1 for a pair that was not compared.
    matched: [detect.max_pages]f32,
    /// The fraction of the printed tiles on blank paper, for each page pair; -1 for
    /// a pair that was not compared.
    print_on_blank: [detect.max_pages]f32,
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
    var resolver: Resolver = .init(options);
    defer resolver.deinit(allocator);
    const owner = try allocator.alloc(u32, candidates.len);
    errdefer allocator.free(owner);

    for (candidates, 0..) |candidate, index| {
        const id: u32 = @intCast(index);
        switch (try resolver.add(allocator, id, candidate, log)) {
            .kept => owner[index] = id,
            .duplicate => |earlier| owner[index] = earlier,
            .replaces => |earlier| {
                // All copies of the spread now belong to the better copy.
                for (owner[0..index]) |*value| {
                    if (value.* == earlier) value.* = id;
                }
                owner[index] = id;
            },
        }
    }
    const kept = try allocator.alloc(u32, resolver.kept.items.len);
    for (kept, resolver.kept.items) |*id, entry| id.* = entry.id;
    return .{ .kept = kept, .owner = owner };
}

/// The duplicate search for spreads that come one by one. `resolve` is the same
/// code for a list of all spreads.
pub const Resolver = struct {
    options: Options,
    /// The spreads to keep, in the order of the pages of the document.
    kept: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        id: u32,
        candidate: Candidate,
    };

    /// What a new spread is.
    pub const Decision = union(enum) {
        /// A spread that the document does not have yet.
        kept,
        /// A copy of the kept spread with this id. The kept spread is the better copy.
        duplicate: u32,
        /// A better copy of the kept spread with this id. The new spread takes its
        /// own place in the order, and the spread with this id leaves the document.
        replaces: u32,
    };

    pub fn init(options: Options) Resolver {
        return .{ .options = options };
    }

    pub fn deinit(self: *Resolver, allocator: Allocator) void {
        self.kept.deinit(allocator);
    }

    /// True when a later call of `add` can still read the signatures of the kept
    /// spread `id`. The caller can free the signatures of each other spread.
    pub fn compares(self: *const Resolver, id: u32) bool {
        const first = self.kept.items.len -| self.options.lookback;
        for (self.kept.items[first..]) |entry| {
            if (entry.id == id) return true;
        }
        return false;
    }

    /// Take the next spread of the video. The signatures of the candidate stay with
    /// the caller: they must live while `compares` is true for `id`.
    pub fn add(
        self: *Resolver,
        allocator: Allocator,
        id: u32,
        candidate: Candidate,
        log: ?*std.ArrayList(Comparison),
    ) Allocator.Error!Decision {
        const kept = &self.kept;
        var duplicate_position: ?usize = null;
        var back: usize = 1;
        while (back <= self.options.lookback and back <= kept.items.len) : (back += 1) {
            const position = kept.items.len - back;
            const earlier = &kept.items[position];
            if (back > 1 and !candidate.weak and !earlier.candidate.weak) continue;
            var comparison = try compare(allocator, &earlier.candidate, &candidate, self.options);
            comparison.first = earlier.id;
            comparison.second = id;
            if (log) |list| try list.append(allocator, comparison);
            if (comparison.same) {
                duplicate_position = position;
                break;
            }
        }
        if (duplicate_position) |position| {
            const earlier = kept.items[position];
            if (!isBetter(&candidate, &earlier.candidate)) return .{ .duplicate = earlier.id };
            // The append comes first: when it fails, the list has no change.
            try kept.append(allocator, .{ .id = id, .candidate = candidate });
            _ = kept.orderedRemove(position);
            return .{ .replaces = earlier.id };
        }
        try kept.append(allocator, .{ .id = id, .candidate = candidate });
        return .kept;
    }
};

/// Compare two candidates, as `Resolver.add` does. The ids of the result are 0
/// for `a` and 1 for `b`.
pub fn compare(allocator: Allocator, a: *const Candidate, b: *const Candidate, options: Options) Allocator.Error!Comparison {
    var comparison: Comparison = .{
        .first = 0,
        .second = 1,
        .same = false,
        .matched = @splat(-1),
        .print_on_blank = @splat(-1),
    };
    comparison.same = try sameSpread(allocator, a, b, options, &comparison);
    return comparison;
}

/// A spread with two pages has more of the document than one page of it.
fn isBetter(a: *const Candidate, b: *const Candidate) bool {
    if (a.kind != b.kind) return a.kind == .spread;
    return a.quality > b.quality;
}

/// True when the two candidates show the same pages. For two spreads, each page
/// must match. For one page and a spread, the page must match one page of the spread.
/// The values of each compared page pair go to `comparison`.
fn sameSpread(
    allocator: Allocator,
    a: *const Candidate,
    b: *const Candidate,
    options: Options,
    comparison: *Comparison,
) Allocator.Error!bool {
    if (a.kind == b.kind) {
        var smallest: f32 = 1;
        var largest: f32 = 0;
        var different = false;
        for (0..a.kind.pageCount()) |page| {
            const match = try comparePages(allocator, a.pageView(page), b.pageView(page), options);
            comparison.matched[page] = match.matched;
            comparison.print_on_blank[page] = match.print_on_blank;
            smallest = @min(smallest, match.matched);
            largest = @max(largest, match.matched);
            if (match.print_on_blank >= options.max_print_on_blank) different = true;
        }
        // The two pages of a spread are one sheet of paper side by side. When one page
        // matches well, a weaker match of the other page (a hand lies on it) is enough.
        return !different and largest >= options.min_matched_fraction and smallest >= options.min_weaker_fraction;
    }
    const single = if (a.kind == .single) a else b;
    const spread = if (a.kind == .single) b else a;
    for (0..spread.kind.pageCount()) |page| {
        const match = try comparePages(allocator, spread.pageView(page), single.pageView(0), options);
        comparison.matched[page] = match.matched;
        comparison.print_on_blank[page] = match.print_on_blank;
        if (match.matched >= options.min_matched_fraction and match.print_on_blank < options.max_print_on_blank) return true;
    }
    return false;
}

/// What the comparison of two pictures of a page found.
const PageMatch = struct {
    /// The fraction of the textured tiles of the first picture that the transform explains.
    matched: f32 = 0,
    /// The fraction of the printed tiles of the two pictures that lie on blank paper
    /// in the other picture, after the transform.
    print_on_blank: f32 = 0,
};

/// A small picture of a page, and the pixels of it that do not show the paper.
const PageView = struct {
    plane: image.PlaneView,
    hidden: ?image.PlaneView,

    /// True when a hidden pixel lies in the square of side `side` around `center`,
    /// a position in pixels of the picture.
    fn hiddenAround(self: PageView, center: geometry.Point, side: f32) bool {
        const hidden = self.hidden orelse return false;
        const half = 0.5 * side;
        const first_x = pixelCoordinate(center.x - half, hidden.width);
        const last_x = pixelCoordinate(center.x + half, hidden.width);
        const first_y = pixelCoordinate(center.y - half, hidden.height);
        const last_y = pixelCoordinate(center.y + half, hidden.height);
        for (first_y..last_y + 1) |y| {
            for (hidden.row(y)[first_x .. last_x + 1]) |value| {
                if (value != 0) return true;
            }
        }
        return false;
    }
};

fn pixelCoordinate(value: f32, size: u32) usize {
    return @intFromFloat(std.math.clamp(@round(value), 0, @as(f32, @floatFromInt(size - 1))));
}

fn comparePages(allocator: Allocator, a: PageView, b: PageView, options: Options) Allocator.Error!PageMatch {
    if (a.plane.width != b.plane.width or a.plane.height != b.plane.height) return .{};
    var match: PageMatch = .{};
    // The first round finds the rough transform between the two copies. Each next
    // round starts from `b` moved by that transform, so that the tiles of a real
    // copy fall into the search range. Two different pages gain nothing: the parts
    // that matched in the first round (pictures) match again, the text does not.
    var total = geometry.Homography.identity;
    var moved: ?image.Plane = null;
    defer if (moved) |plane| plane.deinit(allocator);
    for (0..alignment_rounds) |round| {
        const other = if (moved) |plane| plane.view() else b.plane;
        const result = try register.register(allocator, a.plane, other, options.register);
        defer result.deinit(allocator);
        if (!result.fitted or result.comparable_tiles < min_comparable_tiles) return match;
        match = .{
            .matched = result.matchedFraction(),
            .print_on_blank = printOnBlank(a, b, other, result.transform, total, options),
        };
        if (round + 1 == alignment_rounds or result.inlier_tiles < min_tiles_to_continue) break;

        // `total` goes from a position in `a` to the same content in `b`.
        total = total.mul(result.transform);
        const next = try image.Plane.init(allocator, a.plane.width, a.plane.height);
        for (0..next.height) |y| {
            const row = next.row(y);
            for (row, 0..) |*value, x| {
                const p = total.apply(geometry.Point.init(@floatFromInt(x), @floatFromInt(y)));
                value.* = @intFromFloat(std.math.clamp(b.plane.sample(p.x, p.y) + 0.5, 0, 255));
            }
        }
        if (moved) |plane| plane.deinit(allocator);
        moved = next;
    }
    return match;
}

fn isPrint(plane: image.PlaneView, x: usize, y: usize, options: Options) bool {
    const min_texture = options.register.min_texture;
    return register.tileStats(plane, x, y, options.register.tile).variance() >= min_texture * min_texture;
}

/// True when the tile at (x, y) and the margin around it have no pixel darker than
/// blank paper. The part of the margin outside the plane does not count.
fn blankAround(plane: image.PlaneView, x: usize, y: usize, options: Options) bool {
    const margin = options.blank_margin;
    const tile = options.register.tile;
    const first_x = x -| margin;
    const first_y = y -| margin;
    const end_x = @min(plane.width, x + tile + margin);
    const end_y = @min(plane.height, y + tile + margin);
    for (first_y..end_y) |row| {
        for (plane.row(row)[first_x..end_x]) |value| {
            if (value < options.min_blank_luma) return false;
        }
    }
    return true;
}

/// The fraction of the printed tiles of `a` and `b` that lie on blank paper in the
/// other picture. `other` is `b` moved by `total`, and `transform` goes from a
/// position in `a` to the same content in `other`. A tile is printed when it has
/// texture. A tile with a hidden pixel in `a` or in `b` does not count.
fn printOnBlank(
    a: PageView,
    b: PageView,
    other: image.PlaneView,
    transform: geometry.Homography,
    total: geometry.Homography,
    options: Options,
) f32 {
    const tile: usize = options.register.tile;
    const tile_size: f32 = @floatFromInt(tile);
    const half = 0.5 * (tile_size - 1);
    const other_width: f32 = @floatFromInt(other.width);
    const other_height: f32 = @floatFromInt(other.height);
    var printed: u32 = 0;
    var on_blank: u32 = 0;
    var y: usize = 0;
    while (y + tile <= a.plane.height) : (y += tile) {
        var x: usize = 0;
        while (x + tile <= a.plane.width) : (x += tile) {
            const center = geometry.Point.init(@as(f32, @floatFromInt(x)) + half, @as(f32, @floatFromInt(y)) + half);
            const in_other = transform.apply(center);
            const rounded_x = @round(in_other.x - half);
            const rounded_y = @round(in_other.y - half);
            // A tile with its content outside the other picture has nothing to compare.
            if (!(rounded_x >= 0 and rounded_y >= 0 and rounded_x + tile_size <= other_width and rounded_y + tile_size <= other_height)) continue;
            if (a.hiddenAround(center, tile_size) or b.hiddenAround(total.apply(in_other), tile_size)) continue;
            const other_x: usize = @intFromFloat(rounded_x);
            const other_y: usize = @intFromFloat(rounded_y);
            const print_a = isPrint(a.plane, x, y, options);
            const print_b = isPrint(other, other_x, other_y, options);
            if (!print_a and !print_b) continue;
            printed += 1;
            if ((print_a and blankAround(other, other_x, other_y, options)) or
                (print_b and blankAround(a.plane, x, y, options))) on_blank += 1;
        }
    }
    if (printed == 0) return 0;
    return @as(f32, @floatFromInt(on_blank)) / @as(f32, @floatFromInt(printed));
}

const alignment_rounds = 3;
/// A transform from fewer tiles than this is not safe enough to continue with.
const min_tiles_to_continue = 16;

/// A page with fewer textured tiles than this has too little content to compare.
const min_comparable_tiles = 12;

// region: tests

const testing = std.testing;
const alloc_check = @import("alloc_check.zig");

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

/// A white page of a form, like the enhanced page of a letter. All pages of one
/// `form` seed have the same header and footer. The body has the print of `body`;
/// with no `body` seed, the page has blank paper there.
fn formPage(allocator: Allocator, form: u64, body: ?u64) !image.Plane {
    const plane = try image.Plane.initFilled(allocator, 256, 320, 255);
    var form_random = std.Random.DefaultPrng.init(form);
    drawBlobs(plane, form_random.random(), 16, 112);
    drawBlobs(plane, form_random.random(), 256, 304);
    if (body) |seed| {
        var body_random = std.Random.DefaultPrng.init(seed);
        drawBlobs(plane, body_random.random(), 128, 208);
    }
    return plane;
}

/// Dark blobs between the rows `top` and `bottom` of a page, as many for each row
/// as on the pages of `testSignature`.
fn drawBlobs(plane: image.Plane, random: std.Random, top: u32, bottom: u32) void {
    const blobs_per_row = 5;
    const margin = 8;
    for (0..(bottom - top) * blobs_per_row) |_| {
        const cx = margin + random.uintLessThan(u32, plane.width - 2 * margin);
        const cy = top + 2 + random.uintLessThan(u32, bottom - top - 4);
        const value = random.uintLessThan(u8, 120);
        for (cy - 2..cy + 3) |y| {
            for (cx - 2..cx + 3) |x| plane.set(x, y, value);
        }
    }
}

test "two pages of one form with different bodies stay two pages" {
    // Page 1 has a body, page 2 has blank paper there. They share the header and
    // the footer, so most textured tiles of page 2 match page 1.
    const first = try formPage(testing.allocator, 41, 42);
    defer first.deinit(testing.allocator);
    const second = try formPage(testing.allocator, 41, null);
    defer second.deinit(testing.allocator);

    for ([_][2]image.PlaneView{ .{ first.view(), second.view() }, .{ second.view(), first.view() } }) |order| {
        const candidates = [_]Candidate{
            .{ .kind = .single, .signatures = .{ order[0], order[0] }, .quality = 0.5, .weak = false },
            .{ .kind = .single, .signatures = .{ order[1], order[1] }, .quality = 0.9, .weak = false },
        };
        var log: std.ArrayList(Comparison) = .empty;
        defer log.deinit(testing.allocator);
        const resolution = try resolve(testing.allocator, &candidates, .{}, &log);
        defer resolution.deinit(testing.allocator);
        try testing.expectEqualSlices(u32, &.{ 0, 1 }, resolution.kept);
        // The matched fraction alone does not see the difference.
        try testing.expect(log.items[0].matched[0] >= (Options{}).min_matched_fraction);
    }
}

test "a copy with a finger on its print stays one page" {
    const page = try formPage(testing.allocator, 51, 52);
    defer page.deinit(testing.allocator);
    // The same page, a little lower. A finger hides a part of the body, and the
    // enhancement makes the finger white like blank paper.
    var copy = try image.Plane.initFilled(testing.allocator, page.width, page.height, 255);
    defer copy.deinit(testing.allocator);
    const shift = 3;
    for (0..page.height - shift) |y| @memcpy(copy.row(y + shift), page.view().row(y));
    var hidden = try image.Plane.initFilled(testing.allocator, page.width, page.height, 0);
    defer hidden.deinit(testing.allocator);
    for (120..220) |y| {
        @memset(copy.row(y)[0..200], 255);
        @memset(hidden.row(y)[0..200], 1);
    }

    var candidates = [_]Candidate{
        .{ .kind = .single, .signatures = .{ page.view(), page.view() }, .quality = 0.5, .weak = false },
        .{ .kind = .single, .signatures = .{ copy.view(), copy.view() }, .quality = 0.4, .weak = false, .hidden = .{ hidden.view(), hidden.view() } },
    };
    const with_mask = try resolve(testing.allocator, &candidates, .{}, null);
    defer with_mask.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{0}, with_mask.kept);

    // With no mask, the finger looks like blank paper, and the copy like another page.
    candidates[1].hidden = @splat(null);
    const without_mask = try resolve(testing.allocator, &candidates, .{}, null);
    defer without_mask.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, without_mask.kept);
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

test "the duplicate search frees its memory when an allocation fails" {
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

    const Check = struct {
        fn run(allocator: Allocator, spreads: []const Candidate) !void {
            var log: std.ArrayList(Comparison) = .empty;
            defer log.deinit(allocator);
            const resolution = try resolve(allocator, spreads, .{}, &log);
            defer resolution.deinit(allocator);
            try testing.expectEqual(@as(usize, 2), resolution.kept.len);
        }
        fn pair(allocator: Allocator, spreads: []const Candidate) !void {
            const comparison = try compare(allocator, &spreads[0], &spreads[1], .{});
            try testing.expect(comparison.same);
        }
    };
    try alloc_check.eachFailure(testing.allocator, Check.run, .{@as([]const Candidate, &candidates)});
    try alloc_check.eachFailure(testing.allocator, Check.pair, .{@as([]const Candidate, &candidates)});
}

// endregion: tests
