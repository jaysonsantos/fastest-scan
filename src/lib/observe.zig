//! The observation of one frame: where the pages are, a small picture of each page,
//! and the cells of each page that a hand or another object covers.
//!
//! An observation is small and has a fixed size. The timeline keeps one for each
//! frame of the video.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");
const image = @import("image.zig");
const detect = @import("detect.zig");

const Point = geometry.Point;
const Quad = geometry.Quad;
const Homography = geometry.Homography;

// region: grid

/// Each page is sampled into this grid of cells.
pub const grid_width = 32;
pub const grid_height = 44;
pub const grid_cells = grid_width * grid_height;

pub const CellSet = std.StaticBitSet(grid_cells);

/// Each cell is the mean of this many samples along each axis.
const samples_per_cell = 2;

/// The ink map has smaller cells than the thumbnail: each thumbnail cell holds
/// 2 x 2 ink cells.
pub const ink_per_cell = 2;
pub const ink_grid_width = grid_width * ink_per_cell;
pub const ink_grid_height = grid_height * ink_per_cell;
pub const ink_cells = ink_grid_width * ink_grid_height;
/// Each ink cell takes the darkest of this many samples along each axis.
const ink_samples_per_cell = 3;
/// The paper level of a page is this percentile of its ink map. Most cells of a
/// page are blank paper.
const paper_percentile = 0.8;

fn cellIndex(x: usize, y: usize) usize {
    return y * grid_width + x;
}

// endregion: grid

// region: observation

pub const PageObservation = struct {
    /// The corners of the page in luma pixels of the analysed frame.
    quad: Quad,
    /// The mean luma of each cell.
    thumbnail: [grid_cells]u8,
    /// The cells that do not show the page: cells that are not paper and connect to
    /// the outside of the page through cells that are not paper (a finger gives such
    /// cells, a printed picture inside the page does not), and cells that lie outside
    /// the frame.
    covered: CellSet,
    /// The sides of the page that end at the border of the frame.
    clipped_edges: detect.ClippedEdges,
    /// The darkest luma of each ink cell. Thin text is as dark here as a picture, so
    /// this map shows where glare washed out the ink.
    ink: [ink_cells]u8,
    /// The luma of blank paper on this page.
    paper_luma: u8,

    pub fn coveredFraction(self: *const PageObservation) f32 {
        return @as(f32, @floatFromInt(self.covered.count())) / grid_cells;
    }
};

pub const FrameObservation = struct {
    /// False when the frame shows no clear paper region. The other fields then hold
    /// no information.
    detected: bool,
    kind: detect.LayoutKind,
    clipped: bool,
    gutter_response: f32,
    edge_support: f32,
    pages: [detect.max_pages]PageObservation,

    pub const none: FrameObservation = .{
        .detected = false,
        .kind = .single,
        .clipped = false,
        .gutter_response = 0,
        .edge_support = 0,
        .pages = undefined,
    };

    pub fn pageCount(self: *const FrameObservation) u8 {
        return if (self.detected) self.kind.pageCount() else 0;
    }

    pub fn pageSlice(self: *const FrameObservation) []const PageObservation {
        return self.pages[0..self.pageCount()];
    }

    /// The largest covered fraction of the pages.
    pub fn coveredFraction(self: *const FrameObservation) f32 {
        var largest: f32 = 0;
        for (self.pageSlice()) |*page| largest = @max(largest, page.coveredFraction());
        return largest;
    }

    /// The number of page sides that end at the border of the frame.
    pub fn clippedEdgeCount(self: *const FrameObservation) u8 {
        var count: u8 = 0;
        for (self.pageSlice()) |*page| count += page.clipped_edges.count();
        return count;
    }
};

/// Detect the pages of a frame and sample each page. The frame can have any size;
/// a short side of about 540 pixels is enough.
pub fn observeFrame(allocator: Allocator, frame: image.FrameView, options: detect.Options) Allocator.Error!FrameObservation {
    const scene = (try detect.analyzeScene(allocator, frame, options)) orelse return FrameObservation.none;
    defer scene.deinit(allocator);
    const layout = (try detect.detectLayout(allocator, &scene, options)) orelse return FrameObservation.none;
    return observeLayout(&scene, layout);
}

/// Sample the pages of a known layout.
pub fn observeLayout(scene: *const detect.Scene, layout: detect.Layout) FrameObservation {
    var observation: FrameObservation = .{
        .detected = true,
        .kind = layout.kind,
        .clipped = layout.clipped,
        .gutter_response = layout.gutter_response,
        .edge_support = layout.edge_support,
        .pages = undefined,
    };
    for (0..layout.pageCount()) |index| {
        observation.pages[index] = observePage(scene, layout.pages[index], layout.clipped_edges[index]) orelse return FrameObservation.none;
    }
    if (layout.kind == .single) observation.pages[1] = observation.pages[0];
    return observation;
}

fn observePage(scene: *const detect.Scene, quad: Quad, clipped_edges: detect.ClippedEdges) ?PageObservation {
    // From grid coordinates (0..grid_width, 0..grid_height) to the half-size image.
    const to_scene = Homography.fromQuads(
        Quad.rect(grid_width, grid_height),
        scene.quadFromFrame(quad),
    ) orelse return null;
    const luma = scene.luma.view();
    const score = scene.score.view();

    var page: PageObservation = .{
        .quad = quad,
        .thumbnail = undefined,
        .covered = CellSet.empty,
        .clipped_edges = clipped_edges,
        .ink = undefined,
        .paper_luma = 255,
    };
    var paper = CellSet.empty;
    var outside = CellSet.empty;
    const sample_count: f32 = samples_per_cell * samples_per_cell;
    const max_x: f32 = @floatFromInt(luma.width - 1);
    const max_y: f32 = @floatFromInt(luma.height - 1);
    for (0..grid_height) |cell_y| {
        for (0..grid_width) |cell_x| {
            var luma_sum: f32 = 0;
            var score_sum: f32 = 0;
            var outside_samples: u32 = 0;
            for (0..samples_per_cell) |sub_y| {
                for (0..samples_per_cell) |sub_x| {
                    const grid_point = Point.init(
                        @as(f32, @floatFromInt(cell_x)) + (@as(f32, @floatFromInt(sub_x)) + 0.5) / samples_per_cell,
                        @as(f32, @floatFromInt(cell_y)) + (@as(f32, @floatFromInt(sub_y)) + 0.5) / samples_per_cell,
                    );
                    const p = to_scene.apply(grid_point);
                    if (p.x < 0 or p.y < 0 or p.x > max_x or p.y > max_y) outside_samples += 1;
                    luma_sum += luma.sample(p.x, p.y);
                    score_sum += score.sample(p.x, p.y);
                }
            }
            const index = cellIndex(cell_x, cell_y);
            if (outside_samples > 0) outside.set(index);
            page.thumbnail[index] = @intFromFloat(std.math.clamp(luma_sum / sample_count + 0.5, 0, 255));
            if (score_sum / sample_count > @as(f32, @floatFromInt(scene.threshold))) paper.set(index);
        }
    }
    page.covered = coveredCells(paper);
    page.covered.setUnion(outside);

    // The ink map: the darkest sample of each small cell.
    const to_scene_ink = to_scene.mul(Homography.scaling(1.0 / @as(f64, ink_per_cell), 1.0 / @as(f64, ink_per_cell)));
    var bins: [256]u32 = @splat(0);
    for (0..ink_grid_height) |cell_y| {
        for (0..ink_grid_width) |cell_x| {
            var darkest: f32 = 255;
            for (0..ink_samples_per_cell) |sub_y| {
                for (0..ink_samples_per_cell) |sub_x| {
                    const p = to_scene_ink.apply(Point.init(
                        @as(f32, @floatFromInt(cell_x)) + (@as(f32, @floatFromInt(sub_x)) + 0.5) / ink_samples_per_cell,
                        @as(f32, @floatFromInt(cell_y)) + (@as(f32, @floatFromInt(sub_y)) + 0.5) / ink_samples_per_cell,
                    ));
                    darkest = @min(darkest, luma.sample(p.x, p.y));
                }
            }
            const value: u8 = @intFromFloat(std.math.clamp(darkest + 0.5, 0, 255));
            page.ink[cell_y * ink_grid_width + cell_x] = value;
            bins[value] += 1;
        }
    }
    var cumulative: u32 = 0;
    const target: u32 = @intFromFloat(paper_percentile * @as(f32, ink_cells));
    page.paper_luma = 255;
    for (bins, 0..) |count, code| {
        cumulative += count;
        if (cumulative >= target) {
            page.paper_luma = @intCast(code);
            break;
        }
    }
    return page;
}

/// The cells that are not paper and connect to the border of the grid through
/// cells that are not paper.
fn coveredCells(paper: CellSet) CellSet {
    var covered = CellSet.empty;
    var stack: [grid_cells]u16 = undefined;
    var stack_len: usize = 0;

    const Seed = struct {
        fn push(set: *CellSet, paper_cells: CellSet, items: *[grid_cells]u16, len: *usize, x: usize, y: usize) void {
            const index = cellIndex(x, y);
            if (paper_cells.isSet(index) or set.isSet(index)) return;
            set.set(index);
            items[len.*] = @intCast(index);
            len.* += 1;
        }
    };

    for (0..grid_width) |x| {
        Seed.push(&covered, paper, &stack, &stack_len, x, 0);
        Seed.push(&covered, paper, &stack, &stack_len, x, grid_height - 1);
    }
    for (0..grid_height) |y| {
        Seed.push(&covered, paper, &stack, &stack_len, 0, y);
        Seed.push(&covered, paper, &stack, &stack_len, grid_width - 1, y);
    }
    while (stack_len > 0) {
        stack_len -= 1;
        const index = stack[stack_len];
        const x = index % grid_width;
        const y = index / grid_width;
        if (x > 0) Seed.push(&covered, paper, &stack, &stack_len, x - 1, y);
        if (x + 1 < grid_width) Seed.push(&covered, paper, &stack, &stack_len, x + 1, y);
        if (y > 0) Seed.push(&covered, paper, &stack, &stack_len, x, y - 1);
        if (y + 1 < grid_height) Seed.push(&covered, paper, &stack, &stack_len, x, y + 1);
    }
    return covered;
}

// endregion: observation

// region: comparison

/// How alike two pages look, from -1 to 1: the correlation of the two thumbnails
/// over the cells that are free in the two pages. Returns null when too few cells
/// are free in the two pages.
pub fn pageSimilarity(a: *const PageObservation, b: *const PageObservation) ?f32 {
    var blocked = a.covered;
    blocked.setUnion(b.covered);
    const free_count = grid_cells - blocked.count();
    if (free_count < min_common_cells) return null;

    var sum_a: f64 = 0;
    var sum_b: f64 = 0;
    for (0..grid_cells) |index| {
        if (blocked.isSet(index)) continue;
        sum_a += @floatFromInt(a.thumbnail[index]);
        sum_b += @floatFromInt(b.thumbnail[index]);
    }
    const n: f64 = @floatFromInt(free_count);
    const mean_a = sum_a / n;
    const mean_b = sum_b / n;
    var covariance: f64 = 0;
    var variance_a: f64 = 0;
    var variance_b: f64 = 0;
    for (0..grid_cells) |index| {
        if (blocked.isSet(index)) continue;
        const da = @as(f64, @floatFromInt(a.thumbnail[index])) - mean_a;
        const db = @as(f64, @floatFromInt(b.thumbnail[index])) - mean_b;
        covariance += da * db;
        variance_a += da * da;
        variance_b += db * db;
    }
    // Two blank pages have no structure to compare: they are alike.
    const flat_a = variance_a / n < flat_variance;
    const flat_b = variance_b / n < flat_variance;
    if (flat_a and flat_b) return 1;
    if (flat_a or flat_b) return 0;
    return @floatCast(covariance / @sqrt(variance_a * variance_b));
}

/// How alike two pages look when their quads do not agree: the best correlation of
/// the two thumbnails over a set of shifts and scales of the second thumbnail.
///
/// A finger on an edge or an edge out of view moves the corners of a quad. The
/// thumbnail then shows the same page, but moved or stretched. Returns null when no
/// shift gives enough common free cells.
pub fn alignedPageSimilarity(a: *const PageObservation, b: *const PageObservation) ?f32 {
    var best: ?f32 = null;
    const center_x = 0.5 * @as(f32, grid_width);
    const center_y = 0.5 * @as(f32, grid_height);
    for (align_scales_y) |scale_y| {
        for (align_scales_x) |scale_x| {
            var shift_y: i32 = -align_max_shift_y;
            while (shift_y <= align_max_shift_y) : (shift_y += 1) {
                var shift_x: i32 = -align_max_shift_x;
                while (shift_x <= align_max_shift_x) : (shift_x += 1) {
                    var count: u32 = 0;
                    var sum_a: f32 = 0;
                    var sum_b: f32 = 0;
                    var sum_aa: f32 = 0;
                    var sum_bb: f32 = 0;
                    var sum_ab: f32 = 0;
                    for (0..grid_height) |cell_y| {
                        const source_y_float = center_y + (@as(f32, @floatFromInt(cell_y)) + 0.5 - center_y) * scale_y + @as(f32, @floatFromInt(shift_y));
                        if (source_y_float < 0 or source_y_float >= grid_height) continue;
                        const source_y: usize = @intFromFloat(source_y_float);
                        for (0..grid_width) |cell_x| {
                            const source_x_float = center_x + (@as(f32, @floatFromInt(cell_x)) + 0.5 - center_x) * scale_x + @as(f32, @floatFromInt(shift_x));
                            if (source_x_float < 0 or source_x_float >= grid_width) continue;
                            const source_x: usize = @intFromFloat(source_x_float);
                            const index_a = cellIndex(cell_x, cell_y);
                            const index_b = cellIndex(source_x, source_y);
                            if (a.covered.isSet(index_a) or b.covered.isSet(index_b)) continue;
                            const value_a: f32 = @floatFromInt(a.thumbnail[index_a]);
                            const value_b: f32 = @floatFromInt(b.thumbnail[index_b]);
                            count += 1;
                            sum_a += value_a;
                            sum_b += value_b;
                            sum_aa += value_a * value_a;
                            sum_bb += value_b * value_b;
                            sum_ab += value_a * value_b;
                        }
                    }
                    if (count < min_aligned_cells) continue;
                    const n: f32 = @floatFromInt(count);
                    const variance_a = sum_aa - sum_a * sum_a / n;
                    const variance_b = sum_bb - sum_b * sum_b / n;
                    if (variance_a / n < flat_variance or variance_b / n < flat_variance) continue;
                    const correlation = (sum_ab - sum_a * sum_b / n) / @sqrt(variance_a * variance_b);
                    if (best == null or correlation > best.?) best = correlation;
                }
            }
        }
    }
    return best;
}

/// The scales and the largest shifts, in cells, of the aligned comparison. The y
/// range is larger: the top or the bottom of a page is out of view more often than
/// a side.
const align_scales_y = [_]f32{ 0.80, 0.87, 0.93, 1.0, 1.07, 1.15, 1.25 };
const align_scales_x = [_]f32{ 0.93, 1.0, 1.07 };
const align_max_shift_y = 10;
const align_max_shift_x = 4;
/// The aligned comparison needs this many common free cells.
const min_aligned_cells = grid_cells * 2 / 5;

/// How alike two frames look: the smallest page similarity. Null when the frames
/// have different layouts or too few free cells.
pub fn frameSimilarity(a: *const FrameObservation, b: *const FrameObservation) ?f32 {
    if (!a.detected or !b.detected or a.kind != b.kind) return null;
    var smallest: f32 = 1;
    for (a.pageSlice(), b.pageSlice()) |*page_a, *page_b| {
        const similarity = pageSimilarity(page_a, page_b) orelse return null;
        smallest = @min(smallest, similarity);
    }
    return smallest;
}

/// How alike two frames with the same layout look when their quads do not agree:
/// the smallest aligned page similarity.
pub fn alignedFrameSimilarity(a: *const FrameObservation, b: *const FrameObservation) ?f32 {
    if (!a.detected or !b.detected or a.kind != b.kind) return null;
    var smallest: f32 = 1;
    for (a.pageSlice(), b.pageSlice()) |*page_a, *page_b| {
        const similarity = alignedPageSimilarity(page_a, page_b) orelse return null;
        smallest = @min(smallest, similarity);
    }
    return smallest;
}

/// How well each page of `a` matches some page of `b`: the smallest, over the pages
/// of `a`, of the best aligned similarity with a page of `b`. A single page that is
/// one half of a spread gives a high value.
pub fn pagesFoundIn(a: *const FrameObservation, b: *const FrameObservation) ?f32 {
    if (!a.detected or !b.detected) return null;
    var smallest: f32 = 1;
    for (a.pageSlice()) |*page_a| {
        var best: ?f32 = null;
        for (b.pageSlice()) |*page_b| {
            const similarity = alignedPageSimilarity(page_a, page_b) orelse continue;
            if (best == null or similarity > best.?) best = similarity;
        }
        smallest = @min(smallest, best orelse return null);
    }
    return smallest;
}

/// The largest corner movement between two frames, as a fraction of the page height.
pub fn frameMotion(a: *const FrameObservation, b: *const FrameObservation) ?f32 {
    if (!a.detected or !b.detected or a.kind != b.kind) return null;
    var largest: f32 = 0;
    for (a.pageSlice(), b.pageSlice()) |*page_a, *page_b| {
        const height = @max(page_a.quad.meanHeight(), 1);
        largest = @max(largest, page_a.quad.maxCornerDistance(page_b.quad) / height);
    }
    return largest;
}

/// Two pages need this many common free cells for a comparison.
const min_common_cells = grid_cells / 4;
/// The luma variance below which a thumbnail is blank.
const flat_variance = 4.0;

// endregion: comparison

// region: tests

const testing = std.testing;

test "covered cells connect to the border" {
    var paper = CellSet.full;
    // A finger from the bottom edge, three cells wide and five cells long.
    for (grid_height - 5..grid_height) |y| {
        for (10..13) |x| paper.unset(cellIndex(x, y));
    }
    // A printed picture in the middle of the page.
    for (15..20) |y| {
        for (15..20) |x| paper.unset(cellIndex(x, y));
    }
    const covered = coveredCells(paper);
    try testing.expectEqual(@as(usize, 15), covered.count());
    try testing.expect(covered.isSet(cellIndex(11, grid_height - 1)));
    try testing.expect(covered.isSet(cellIndex(11, grid_height - 5)));
    try testing.expect(!covered.isSet(cellIndex(17, 17)));
}

fn testPage(seed: u64) PageObservation {
    var page: PageObservation = .{
        .quad = Quad.rect(100, 140),
        .thumbnail = undefined,
        .covered = CellSet.empty,
        .clipped_edges = .none,
        .ink = @splat(200),
        .paper_luma = 200,
    };
    var random = std.Random.DefaultPrng.init(seed);
    for (&page.thumbnail) |*value| value.* = random.random().int(u8);
    return page;
}

test "page similarity ignores covered cells" {
    const original = testPage(7);
    var with_finger = original;
    for (grid_height - 8..grid_height) |y| {
        for (5..15) |x| {
            with_finger.thumbnail[cellIndex(x, y)] = 60;
            with_finger.covered.set(cellIndex(x, y));
        }
    }
    try testing.expectApproxEqAbs(@as(f32, 1), pageSimilarity(&original, &with_finger).?, 1e-4);

    const other = testPage(8);
    try testing.expect(pageSimilarity(&original, &other).? < 0.2);
}

test "aligned similarity finds a page that is shifted in its thumbnail" {
    const original = testPage(21);
    // The same page seen with a quad that starts five cells lower.
    var shifted = testPage(22);
    const shift = 5;
    for (0..grid_height - shift) |y| {
        for (0..grid_width) |x| {
            shifted.thumbnail[cellIndex(x, y)] = original.thumbnail[cellIndex(x, y + shift)];
        }
    }
    try testing.expect(pageSimilarity(&original, &shifted).? < 0.3);
    try testing.expect(alignedPageSimilarity(&original, &shifted).? > 0.95);

    const other = testPage(23);
    try testing.expect(alignedPageSimilarity(&original, &other).? < 0.4);
}

test "page similarity needs common free cells" {
    const a = testPage(1);
    var b = testPage(1);
    b.covered = CellSet.full;
    try testing.expect(pageSimilarity(&a, &b) == null);
}

// endregion: tests
