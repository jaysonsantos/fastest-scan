//! The timeline: from one observation per frame to the list of spreads that the
//! video shows, with the best frames of each spread.
//!
//! A spread is a run of frames in which the pages stay at one place and look the
//! same. A page turn breaks the run: the pages move, a hand covers them, or the
//! detector finds nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const detect = @import("detect.zig");
const geometry = @import("geometry.zig");
const observe = @import("observe.zig");

const FrameObservation = observe.FrameObservation;

// region: options and results

pub const Options = struct {
    /// The frame rate of the video. The times below become frame counts with it.
    frames_per_second: f32 = reference_frame_rate,
    /// The largest corner movement between two frames of a stable run, as a fraction
    /// of the page height, at `reference_frame_rate`.
    max_motion: f32 = 0.05,
    /// The smallest similarity between two successive frames of a stable run.
    min_similarity: f32 = 0.85,
    /// A stable run continues over a break of at most this many seconds.
    max_gap_seconds: f32 = 0.15,
    /// A run shorter than this is not a spread.
    min_run_seconds: f32 = 0.3,
    /// The best frame of a spread has at most this fraction of a page covered.
    max_reference_cover: f32 = 0.25,
    /// The best frame of a spread has at least this edge support.
    min_reference_support: f32 = 0.12,
    /// Two runs next to each other show the same spread when their best frames are
    /// at least this similar. The value is high: a page that appears two times in the
    /// PDF is a smaller fault than a page that is missing.
    merge_similarity: f32 = 0.9,
    /// A spread with a shorter stable time than this is weak.
    weak_run_seconds: f32 = 0.6,
    /// A spread with more of a page covered than this is weak.
    weak_cover: f32 = 0.10,

    pub const reference_frame_rate = 30.0;
};

pub const Segment = struct {
    kind: detect.LayoutKind,
    /// The first and the last stable frame of the spread.
    first_frame: u32,
    last_frame: u32,
    /// The frame to render when only one frame is used.
    reference: u32,
    /// The number of stable frames between the first and the last frame.
    stable_frames: u32,
    /// The reference score of the reference frame. Higher is better.
    score: f32,
    /// True for a short view or a view with a hand on it. Such a view can be a
    /// second copy of a spread that is not next to it in the video.
    weak: bool,
};

pub const Timeline = struct {
    segments: []Segment,

    pub fn deinit(self: Timeline, allocator: Allocator) void {
        allocator.free(self.segments);
    }

    /// The number of pages in the document.
    pub fn pageCount(self: Timeline) usize {
        var count: usize = 0;
        for (self.segments) |segment| count += segment.kind.pageCount();
        return count;
    }
};

// endregion: options and results

// region: frame quality

/// Weights of the reference score. The edge support is between 0 and 1; the other
/// terms pull the score down.
const score_weight = struct {
    const cover = 2.0;
    const motion = 4.0;
    /// For each page side that ends at the border of the frame.
    const clipped_edge = 0.5;
};

/// How good a frame is as the single picture of its spread. Higher is better.
fn referenceScore(observations: []const FrameObservation, index: usize) f32 {
    const frame = &observations[index];
    var score = frame.edge_support - score_weight.cover * frame.coveredFraction();
    score -= score_weight.clipped_edge * @as(f32, @floatFromInt(frame.clippedEdgeCount()));
    return score - score_weight.motion * neighbourMotion(observations, index);
}

/// How good a frame is as the picture of one of its pages. Higher is better.
fn pageScore(observations: []const FrameObservation, index: usize, page_index: usize) f32 {
    const frame = &observations[index];
    const page = &frame.pages[page_index];
    var score = frame.edge_support - score_weight.cover * page.coveredFraction();
    score -= score_weight.clipped_edge * @as(f32, @floatFromInt(page.clipped_edges.count()));
    return score - score_weight.motion * neighbourMotion(observations, index);
}

/// The motion from the frame before plus the motion to the frame after. A frame
/// between two calm frames has little motion blur.
fn neighbourMotion(observations: []const FrameObservation, index: usize) f32 {
    const frame = &observations[index];
    var sum: f32 = 0;
    if (index > 0) {
        const motion = observe.frameMotion(&observations[index - 1], frame) orelse worst_motion;
        sum += @min(motion, worst_motion);
    }
    if (index + 1 < observations.len) {
        const motion = observe.frameMotion(frame, &observations[index + 1]) orelse worst_motion;
        sum += @min(motion, worst_motion);
    }
    return sum;
}

/// The motion value for a frame without a comparable neighbour.
const worst_motion = 0.25;

// endregion: frame quality

// region: build

const Run = struct {
    first: usize,
    last: usize,
    stable: usize,
    kind: detect.LayoutKind,
};

/// Find the spreads in the observations of all frames, in the order of the video.
pub fn build(allocator: Allocator, observations: []const FrameObservation, options: Options) Allocator.Error!Timeline {
    const rate_factor = Options.reference_frame_rate / @max(options.frames_per_second, 1);
    const max_motion = options.max_motion * rate_factor;
    const max_gap: usize = @intFromFloat(@round(options.max_gap_seconds * options.frames_per_second));
    const min_run: usize = @intFromFloat(@max(2, @round(options.min_run_seconds * options.frames_per_second)));
    const weak_run: usize = @intFromFloat(@round(options.weak_run_seconds * options.frames_per_second));

    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(allocator);

    // A frame is stable when it looks like the frame before it and the pages did not move.
    var current: ?Run = null;
    var gap: usize = 0;
    for (observations, 0..) |*frame, index| {
        var stable = false;
        if (index > 0 and frame.detected) {
            const previous = &observations[index - 1];
            const similarity = observe.frameSimilarity(previous, frame);
            const motion = observe.frameMotion(previous, frame);
            if (similarity != null and motion != null) {
                stable = similarity.? >= options.min_similarity and motion.? <= max_motion;
            }
        }
        if (stable) {
            if (current) |*run| {
                if (run.kind == frame.kind) {
                    run.last = index;
                    run.stable += 1;
                    gap = 0;
                    continue;
                }
                try runs.append(allocator, run.*);
            }
            current = .{ .first = index - 1, .last = index, .stable = 2, .kind = frame.kind };
            gap = 0;
        } else if (current) |run| {
            gap += 1;
            if (gap > max_gap) {
                try runs.append(allocator, run);
                current = null;
                gap = 0;
            }
        }
    }
    if (current) |run| try runs.append(allocator, run);

    var segments: std.ArrayList(Segment) = .empty;
    errdefer segments.deinit(allocator);
    for (runs.items) |run| {
        if (run.stable < min_run) continue;
        const reference = bestFrame(observations, run) orelse continue;
        const best = &observations[reference];
        if (best.coveredFraction() > options.max_reference_cover) continue;
        if (best.edge_support < options.min_reference_support) continue;

        const segment: Segment = .{
            .kind = run.kind,
            .first_frame = @intCast(run.first),
            .last_frame = @intCast(run.last),
            .reference = @intCast(reference),
            .stable_frames = @intCast(run.stable),
            .score = referenceScore(observations, reference),
            .weak = run.stable < weak_run or best.coveredFraction() > options.weak_cover,
        };
        // The same spread after a short break: join it with the run before.
        if (segments.items.len > 0) {
            const previous = &segments.items[segments.items.len - 1];
            const similarity = observe.frameSimilarity(&observations[previous.reference], best);
            if (previous.kind == segment.kind and similarity != null and similarity.? >= options.merge_similarity) {
                previous.last_frame = segment.last_frame;
                previous.stable_frames += segment.stable_frames;
                if (segment.score > previous.score) {
                    previous.reference = segment.reference;
                    previous.score = segment.score;
                }
                previous.weak = previous.stable_frames < weak_run or
                    observations[previous.reference].coveredFraction() > options.weak_cover;
                continue;
            }
        }
        try segments.append(allocator, segment);
    }
    return .{ .segments = try segments.toOwnedSlice(allocator) };
}

/// The frame of a run with the best reference score.
fn bestFrame(observations: []const FrameObservation, run: Run) ?usize {
    var best_index: ?usize = null;
    var best_score = -std.math.inf(f32);
    for (run.first..run.last + 1) |index| {
        const frame = &observations[index];
        if (!frame.detected or frame.kind != run.kind) continue;
        const score = referenceScore(observations, index);
        if (score > best_score) {
            best_score = score;
            best_index = index;
        }
    }
    return best_index;
}

// endregion: build

// region: donor frames

pub const FrameSpan = struct {
    first: u32,
    last: u32,
};

pub const DonorOptions = struct {
    /// The largest number of frames to choose, without the reference frame.
    count: u8 = 6,
    /// A donor frame moves at most this much from the frames next to it, as a
    /// fraction of the page height. More motion gives blur.
    max_motion: f32 = 0.03,
    /// A donor frame has at most this fraction of a page covered.
    max_cover: f32 = 0.35,
    /// A frame can repair an ink cell of the reference when its ink is this much
    /// darker, as a fraction of the paper luma.
    ink_deviation: f32 = 0.12,
    /// The choice wants this many donor frames for each cell to repair. The fusion
    /// trusts a dark value that two frames show.
    frames_per_cell: u8 = 2,
    /// A frame that repairs fewer new cells than this is chosen for its position only.
    min_repair_cells: u32 = 4,
    /// A frame chosen for its position must differ this much from each chosen frame,
    /// as a fraction of the page height.
    min_separation: f32 = 0.004,
    /// The width divided by the height of a page of the document, when known. With
    /// it, a frame that cuts one side of a page can be a donor: the place of the
    /// whole page in that frame follows from the three sides in view. Such a frame
    /// is often a view from near, and the glare is at another place in it.
    page_aspect: ?f32 = null,
    /// The largest number of frames that cut a page, in addition to `count`. They
    /// come last and take no place of a frame that shows the whole page: their
    /// start position is less exact, so more of them fail the registration.
    cut_count: u8 = 3,
};

const InkSet = std.bit_set.Static(detect.max_pages * observe.ink_cells);

/// Some pages of a frame, by their index.
const PageRange = struct {
    first: usize,
    end: usize,

    /// One page, or all the pages of the frame when `page` is null.
    fn init(frame: *const FrameObservation, page: ?usize) PageRange {
        if (page) |index| return .{ .first = index, .end = index + 1 };
        return .{ .first = 0, .end = frame.pageCount() };
    }

    /// The largest covered fraction of the pages.
    fn coveredFraction(self: PageRange, frame: *const FrameObservation) f32 {
        var largest: f32 = 0;
        for (frame.pages[self.first..self.end]) |*page| largest = @max(largest, page.coveredFraction());
        return largest;
    }

    /// The number of page sides that end at the border of the frame.
    fn clippedEdgeCount(self: PageRange, frame: *const FrameObservation) u8 {
        var count: u8 = 0;
        for (frame.pages[self.first..self.end]) |*page| count += page.clipped_edges.count();
        return count;
    }

    /// True when `detect.completeQuad` can find each page: at most one side of a
    /// page ends at the border of the frame.
    fn completable(self: PageRange, frame: *const FrameObservation) bool {
        for (frame.pages[self.first..self.end]) |*page| {
            if (page.clipped_edges.count() > 1) return false;
        }
        return true;
    }
};

/// The ink map of a page in the cells of the whole page, as fractions of the paper
/// level, each cell the darkest of its 3x3 neighbourhood. NaN where the frame does
/// not show the page: a covered cell, or a cell of the part that the frame cuts.
///
/// The ink map of an observation covers the part of the page in view. With the
/// aspect of the page, the place of the whole page follows, and each cell of the
/// whole page takes its value from the cell of the part in view that holds it.
fn wholePageInk(page: *const observe.PageObservation, page_aspect: ?f32, out: *[observe.ink_cells]f32) void {
    var in_view: [observe.ink_cells]f32 = undefined;
    pooledInk(page, &in_view);
    for (&in_view, 0..) |*value, index| {
        if (inkCellCovered(page, index)) value.* = std.math.nan(f32);
    }
    const aspect = page_aspect orelse 0;
    const whole = detect.completeQuad(page.quad, page.clipped_edges, aspect);
    if (!page.clipped_edges.any() or std.meta.eql(whole, page.quad)) {
        out.* = in_view;
        return;
    }
    @memset(out, std.math.nan(f32));
    const cells = geometry.Quad.rect(observe.ink_grid_width, observe.ink_grid_height);
    const to_frame = geometry.Homography.fromQuads(cells, whole) orelse return;
    const from_frame = (geometry.Homography.fromQuads(cells, page.quad) orelse return).inverse() orelse return;
    for (0..observe.ink_grid_height) |y| {
        for (0..observe.ink_grid_width) |x| {
            const center = geometry.Point.init(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
            const source = from_frame.apply(to_frame.apply(center));
            if (!(source.x >= 0) or !(source.y >= 0)) continue;
            const source_x: usize = @intFromFloat(source.x);
            const source_y: usize = @intFromFloat(source.y);
            if (source_x >= observe.ink_grid_width or source_y >= observe.ink_grid_height) continue;
            out[y * observe.ink_grid_width + x] = in_view[source_y * observe.ink_grid_width + source_x];
        }
    }
}

/// The ink map of a page as fractions of its paper level, with each cell the
/// darkest of its 3x3 neighbourhood. The neighbourhood allows for page corners that
/// are a cell off between two frames.
fn pooledInk(page: *const observe.PageObservation, out: *[observe.ink_cells]f32) void {
    const paper: f32 = @floatFromInt(@max(page.paper_luma, 1));
    const width = observe.ink_grid_width;
    const height = observe.ink_grid_height;
    for (0..height) |y| {
        for (0..width) |x| {
            var darkest: u8 = 255;
            // `@min` with a constant gives a small integer type: the sums need `usize`.
            const y_from = y -| 1;
            const y_to: usize = @min(y + 1, height - 1);
            const x_from = x -| 1;
            const x_to: usize = @min(x + 1, width - 1);
            for (y_from..y_to + 1) |ny| {
                for (x_from..x_to + 1) |nx| darkest = @min(darkest, page.ink[ny * width + nx]);
            }
            out[y * width + x] = @as(f32, @floatFromInt(darkest)) / paper;
        }
    }
}

/// True when the thumbnail cell that holds an ink cell is covered.
fn inkCellCovered(page: *const observe.PageObservation, ink_index: usize) bool {
    const x = (ink_index % observe.ink_grid_width) / observe.ink_per_cell;
    const y = (ink_index / observe.ink_grid_width) / observe.ink_per_cell;
    return page.covered.isSet(y * observe.grid_width + x);
}

/// The ink cells of the reference that the other frame can repair: cells where the
/// other frame shows darker ink (the reference has glare there), and cells that a
/// hand covers in the reference but not in the other frame.
fn repairCells(
    reference_ink: *const [detect.max_pages][observe.ink_cells]f32,
    other: *const FrameObservation,
    pages: PageRange,
    options: DonorOptions,
) InkSet {
    var cells = InkSet.empty;
    var other_ink: [observe.ink_cells]f32 = undefined;
    for (pages.first..pages.end) |page_index| {
        wholePageInk(&other.pages[page_index], options.page_aspect, &other_ink);
        for (reference_ink[page_index], other_ink, 0..) |reference_value, other_value, index| {
            if (std.math.isNan(other_value)) continue;
            // NaN in the reference: a hand covers the cell, or the frame cuts it.
            if (std.math.isNan(reference_value) or reference_value - other_value > options.ink_deviation) {
                cells.set(page_index * observe.ink_cells + index);
            }
        }
    }
    return cells;
}

/// Sort a list of frame indexes and drop the indexes that come more than one time.
fn sortUnique(frames: *std.ArrayList(u32)) void {
    std.mem.sort(u32, frames.items, {}, std.sort.asc(u32));
    var unique: usize = 0;
    for (frames.items) |frame| {
        if (unique > 0 and frames.items[unique - 1] == frame) continue;
        frames.items[unique] = frame;
        unique += 1;
    }
    frames.shrinkRetainingCapacity(unique);
}

/// Choose the frames that help most to repair the reference frame of a spread.
///
/// First come the frames that show dark ink where the reference has washed-out ink
/// (glare), or paper where the reference has a hand. Each new frame is the one that
/// repairs the most cells that have too few donors. This is the greedy set cover
/// (V. Chvátal, "A greedy heuristic for the set-covering problem", Mathematics of
/// Operations Research 4(3), 1979).
/// The places that are left go to frames whose pages lie at the most different
/// positions: glare moves when the camera or the page moves.
///
/// `page` is the page to repair; null is for all the pages of the reference frame.
pub fn selectDonors(
    allocator: Allocator,
    observations: []const FrameObservation,
    spans: []const FrameSpan,
    reference: u32,
    page: ?usize,
    options: DonorOptions,
) Allocator.Error![]u32 {
    var chosen: std.ArrayList(u32) = .empty;
    errdefer chosen.deinit(allocator);
    const reference_frame = &observations[reference];
    if (!reference_frame.detected or options.count == 0) return chosen.toOwnedSlice(allocator);
    const pages = PageRange.init(reference_frame, page);

    var candidates: std.ArrayList(u32) = .empty;
    defer candidates.deinit(allocator);
    for (spans) |span| {
        var index: usize = span.first;
        while (index <= span.last and index < observations.len) : (index += 1) {
            if (index == reference) continue;
            const frame = &observations[index];
            if (!frame.detected or frame.kind != reference_frame.kind) continue;
            if (pages.coveredFraction(frame) > options.max_cover) continue;
            if (cutsMore(pages, frame, reference_frame)) {
                // The frame can help only when the place of the whole page in it is known.
                if (options.page_aspect == null or options.cut_count == 0 or !pages.completable(frame)) continue;
            }
            if (index > 0) {
                const motion = observe.frameMotion(&observations[index - 1], frame) orelse continue;
                if (motion > options.max_motion) continue;
            }
            if (index + 1 < observations.len) {
                const motion = observe.frameMotion(frame, &observations[index + 1]) orelse continue;
                if (motion > options.max_motion) continue;
            }
            try candidates.append(allocator, @intCast(index));
        }
    }
    // Two spans can overlap: each frame is a candidate one time only.
    sortUnique(&candidates);
    if (candidates.items.len == 0) return chosen.toOwnedSlice(allocator);

    // What each candidate can repair.
    const reference_ink = try allocator.create([detect.max_pages][observe.ink_cells]f32);
    defer allocator.destroy(reference_ink);
    for (pages.first..pages.end) |page_index| {
        wholePageInk(&reference_frame.pages[page_index], options.page_aspect, &reference_ink[page_index]);
    }
    const repairs = try allocator.alloc(InkSet, candidates.items.len);
    defer allocator.free(repairs);
    for (candidates.items, repairs) |candidate, *cells| {
        cells.* = repairCells(reference_ink, &observations[candidate], pages, options);
    }
    const taken = try allocator.alloc(bool, candidates.items.len);
    defer allocator.free(taken);
    @memset(taken, false);
    // The frames that cut more of the pages than the reference wait for their turn.
    const cut = try allocator.alloc(bool, candidates.items.len);
    defer allocator.free(cut);
    for (candidates.items, cut) |candidate, *is_cut| {
        is_cut.* = cutsMore(pages, &observations[candidate], reference_frame);
    }

    // Greedy cover: the cells that have fewer donors than wanted still count.
    const donors_per_cell = try allocator.alloc(u8, InkSet.bit_length);
    defer allocator.free(donors_per_cell);
    @memset(donors_per_cell, 0);
    const cover: Cover = .{
        .candidates = candidates.items,
        .repairs = repairs,
        .taken = taken,
        .cut = cut,
        .donors_per_cell = donors_per_cell,
        .options = options,
    };
    try cover.choose(allocator, &chosen, false, options.count);

    // The places that are left: frames at the most different positions.
    const nearest = try allocator.alloc(f32, candidates.items.len);
    defer allocator.free(nearest);
    for (candidates.items, nearest, taken) |candidate, *distance, is_taken| {
        if (is_taken) {
            distance.* = -1;
            continue;
        }
        var smallest = observe.frameMotion(reference_frame, &observations[candidate]) orelse 0;
        // The corners of a page that the frame cuts say nothing about the position.
        if (cutsMore(pages, &observations[candidate], reference_frame)) smallest = -1;
        for (chosen.items) |frame_index| {
            smallest = @min(smallest, observe.frameMotion(&observations[frame_index], &observations[candidate]) orelse 0);
        }
        distance.* = smallest;
    }
    while (chosen.items.len < options.count) {
        var best: ?usize = null;
        var best_distance: f32 = options.min_separation;
        for (nearest, 0..) |distance, position| {
            if (distance >= best_distance) {
                best_distance = distance;
                best = position;
            }
        }
        const position = best orelse break;
        const frame_index = candidates.items[position];
        try chosen.append(allocator, frame_index);
        nearest[position] = -1;
        for (candidates.items, nearest) |candidate, *distance| {
            if (distance.* < 0) continue;
            const to_new = observe.frameMotion(&observations[frame_index], &observations[candidate]) orelse 0;
            distance.* = @min(distance.*, to_new);
        }
    }
    // Last, the frames that cut a page, for the cells that still have too few donors.
    try cover.choose(allocator, &chosen, true, chosen.items.len + options.cut_count);
    std.mem.sort(u32, chosen.items, {}, std.sort.asc(u32));
    return chosen.toOwnedSlice(allocator);
}

/// True when a frame cuts more sides of the pages than the reference frame does.
fn cutsMore(pages: PageRange, frame: *const FrameObservation, reference_frame: *const FrameObservation) bool {
    return pages.clippedEdgeCount(frame) > pages.clippedEdgeCount(reference_frame);
}

/// The state of the greedy cover of `selectDonors`.
const Cover = struct {
    candidates: []const u32,
    /// The cells that each candidate can repair.
    repairs: []const InkSet,
    taken: []bool,
    /// The candidates that cut more of the pages than the reference.
    cut: []const bool,
    donors_per_cell: []u8,
    options: DonorOptions,

    /// Add frames to `chosen` until it has `limit` frames: each time the candidate
    /// that repairs the most cells with too few donors. `cut_frames` selects the
    /// kind of candidate.
    fn choose(self: *const Cover, allocator: Allocator, chosen: *std.ArrayList(u32), cut_frames: bool, limit: usize) Allocator.Error!void {
        while (chosen.items.len < limit) {
            var best: ?usize = null;
            var best_gain: u32 = 0;
            for (self.repairs, self.taken, self.cut, 0..) |*cells, is_taken, is_cut, position| {
                if (is_taken or is_cut != cut_frames) continue;
                var gain: u32 = 0;
                var iterator = cells.iterator(.{});
                while (iterator.next()) |cell| {
                    if (self.donors_per_cell[cell] < self.options.frames_per_cell) gain += 1;
                }
                if (gain > best_gain) {
                    best_gain = gain;
                    best = position;
                }
            }
            const position = best orelse break;
            if (best_gain < self.options.min_repair_cells) break;
            self.taken[position] = true;
            try chosen.append(allocator, self.candidates[position]);
            var iterator = self.repairs[position].iterator(.{});
            while (iterator.next()) |cell| self.donors_per_cell[cell] +|= 1;
        }
    }
};

// endregion: donor frames

// region: reference frame of a page

pub const ReferenceOptions = struct {
    /// A candidate moves at most this much from the frames next to it, as a
    /// fraction of the page height.
    max_motion: f32 = 0.03,
    /// A candidate has at most this fraction of the page covered.
    max_cover: f32 = 0.25,
    /// The dark level of a cell is this quantile of its ink values over the frames.
    /// Glare and blur make ink lighter and never darker, so a low quantile is the
    /// ink of a sharp frame without glare when a part of the frames show it.
    dark_quantile: f32 = 0.1,
    /// A cell has ink when its dark level is below this fraction of the paper luma.
    ink_level: f32 = 0.8,
    /// How much the ink that a frame shows raises its score. The ink is a fraction
    /// of the ink of the page.
    ink_weight: f32 = 4.0,
    /// A frame takes the place of the first choice when its score is this much
    /// higher. A smaller difference is noise.
    min_gain: f32 = 0.05,
    /// With fewer candidate frames than this, the first choice stays.
    min_candidates: u32 = 8,
    /// The width divided by the height of a page of the document, when known. A
    /// page that lifts from the desk shows another shape.
    page_aspect: ?f32 = null,
    /// How much a wrong shape lowers the score: the factor for the difference of
    /// the logarithms of the two aspects.
    shape_weight: f32 = 2.0,
};

pub const Reference = struct {
    frame: u32,
    /// How much of the ink of the page the frame shows, as a fraction of the dark
    /// levels of the ink cells. Glare and blur make it smaller.
    ink: f32,
    /// The page score with the ink term.
    score: f32,
};

/// At most this many frames give the dark level of each cell.
const max_consensus_frames = 96;
/// A cell needs this many frames that show it for a dark level.
const min_consensus_frames = 3;

/// The ink map of a page as in `pooledInk`, with NaN in the covered cells.
fn visibleInk(page: *const observe.PageObservation, out: *[observe.ink_cells]f32) void {
    pooledInk(page, out);
    for (out, 0..) |*value, index| {
        if (inkCellCovered(page, index)) value.* = std.math.nan(f32);
    }
}

/// Choose the frame that is the best single picture of one page of a spread, from
/// all the frames of all the views of the spread. `fallback` is a frame of the
/// spread: it gives the layout, and it is the answer when no frame is clearly
/// better. The two pages of a spread can get different frames: the camera often
/// shows one page in full and cuts the other.
///
/// The score is the page score plus a term for the ink that the frame shows. Glare
/// washes ink out and blur makes thin text lighter, so the frame that shows the
/// most ink is the sharpest frame with the least glare. The ink is measured
/// against the other frames: the dark level of a cell is what the best frames show
/// there.
///
/// The idea to take the best frame of a burst as the reference is from S. W.
/// Hasinoff et al., "Burst photography for high dynamic range and low-light
/// imaging on mobile cameras", ACM Transactions on Graphics 35(6), 2016. Their
/// measure is the gradient of the frame; the measure here is the ink.
pub fn chooseReference(
    allocator: Allocator,
    observations: []const FrameObservation,
    spans: []const FrameSpan,
    fallback: u32,
    page_index: usize,
    options: ReferenceOptions,
) Allocator.Error!Reference {
    const first_frame = &observations[fallback];
    const kind = first_frame.kind;
    const clipped_limit = first_frame.pages[page_index].clipped_edges.count();

    var candidates: std.ArrayList(u32) = .empty;
    defer candidates.deinit(allocator);
    try candidates.append(allocator, fallback);
    for (spans) |span| {
        var index: usize = span.first;
        while (index <= span.last and index < observations.len) : (index += 1) {
            const frame = &observations[index];
            if (index == fallback or !frame.detected or frame.kind != kind) continue;
            const page = &frame.pages[page_index];
            if (page.coveredFraction() > options.max_cover) continue;
            // A page that the frame cuts has an ink map of a part of the page only.
            if (page.clipped_edges.count() > clipped_limit) continue;
            if (index > 0) {
                const motion = observe.frameMotion(&observations[index - 1], frame) orelse continue;
                if (motion > options.max_motion) continue;
            }
            if (index + 1 < observations.len) {
                const motion = observe.frameMotion(frame, &observations[index + 1]) orelse continue;
                if (motion > options.max_motion) continue;
            }
            try candidates.append(allocator, @intCast(index));
        }
    }
    // Two spans can overlap: each frame is a candidate one time only.
    sortUnique(&candidates);
    // A few frames give no safe dark level: the first choice stays.
    if (candidates.items.len < options.min_candidates) {
        return .{ .frame = fallback, .ink = 1, .score = pageScore(observations, fallback, page_index) };
    }

    // The dark level of each cell, from frames at even steps through the candidates.
    const sample_count = @min(candidates.items.len, max_consensus_frames);
    const samples = try allocator.alloc([observe.ink_cells]f32, sample_count);
    defer allocator.free(samples);
    for (samples, 0..) |*sample, position| {
        const frame = &observations[candidates.items[position * candidates.items.len / sample_count]];
        visibleInk(&frame.pages[page_index], sample);
    }
    const dark = try allocator.create([observe.ink_cells]f32);
    defer allocator.destroy(dark);
    var values: [max_consensus_frames]f32 = undefined;
    for (dark, 0..) |*level, cell| {
        var count: usize = 0;
        for (samples) |*sample| {
            if (std.math.isNan(sample[cell])) continue;
            values[count] = sample[cell];
            count += 1;
        }
        if (count < min_consensus_frames) {
            level.* = std.math.nan(f32);
            continue;
        }
        std.mem.sort(f32, values[0..count], {}, std.sort.asc(f32));
        // Never the darkest value alone: one frame can be wrong.
        const rank: usize = @intFromFloat(@round(options.dark_quantile * @as(f32, @floatFromInt(count - 1))));
        level.* = values[@max(rank, 1)];
    }

    var best: Reference = .{ .frame = fallback, .ink = 1, .score = -std.math.inf(f32) };
    var first_choice = best;
    var ink: [observe.ink_cells]f32 = undefined;
    for (candidates.items) |candidate| {
        visibleInk(&observations[candidate].pages[page_index], &ink);
        // The ink that the frame shows and the ink that is there, over the ink
        // cells that the frame shows.
        var shown: f32 = 0;
        var present: f32 = 0;
        for (ink, dark) |value, level| {
            // A comparison with NaN is false: a cell with no dark level, or a
            // covered cell, does not count.
            if (!(level < options.ink_level) or std.math.isNan(value)) continue;
            shown += @max(1 - value, 0);
            present += 1 - level;
        }
        const ink_fraction = if (present > 0) @min(shown / present, 1) else 1;
        var score = pageScore(observations, candidate, page_index) + options.ink_weight * (ink_fraction - 1);
        const shape = shapeError(&observations[candidate].pages[page_index], options.page_aspect);
        score -= options.shape_weight * shape;
        const choice: Reference = .{ .frame = candidate, .ink = ink_fraction, .score = score };
        if (candidate == fallback) first_choice = choice;
        if (score > best.score) best = choice;
    }
    if (best.score - first_choice.score < options.min_gain) return first_choice;
    return best;
}

/// How far the shape of a page is from the shape of the pages of the document:
/// the difference of the logarithms of the two aspects. Zero for a page that the
/// frame cuts, and when the aspect of the document is not known.
fn shapeError(page: *const observe.PageObservation, page_aspect: ?f32) f32 {
    const wanted = page_aspect orelse return 0;
    if (page.clipped_edges.any()) return 0;
    const height = page.quad.meanHeight();
    const width = page.quad.meanWidth();
    if (!(height > 0) or !(width > 0) or !(wanted > 0)) return 0;
    return @abs(@log(width / height) - @log(wanted));
}

// endregion: reference frame of a page

// region: tests

const testing = std.testing;
const alloc_check = @import("alloc_check.zig");

/// An observation of a page with a random thumbnail. The same seed gives the same page.
fn testObservation(seed: u64, kind: detect.LayoutKind, shift: f32, support: f32) FrameObservation {
    var observation: FrameObservation = .{
        .detected = true,
        .kind = kind,
        .clipped = false,
        .gutter_response = if (kind == .spread) 20 else 0,
        .edge_support = support,
        .pages = undefined,
    };
    for (&observation.pages, 0..) |*page, page_index| {
        page.clipped_edges = .none;
        var random = std.Random.DefaultPrng.init(seed * 2 + page_index);
        page.quad = .{
            .tl = geometry.Point.init(100 + shift, 100),
            .tr = geometry.Point.init(300 + shift, 100),
            .br = geometry.Point.init(300 + shift, 400),
            .bl = geometry.Point.init(100 + shift, 400),
        };
        for (&page.thumbnail) |*value| value.* = random.random().int(u8);
        page.covered = observe.CellSet.empty;
        page.ink = @splat(200);
        page.paper_luma = 200;
    }
    return observation;
}

const test_options: Options = .{ .frames_per_second = 30 };

test "two spreads with a page turn between them" {
    var observations: [90]FrameObservation = undefined;
    for (0..30) |index| observations[index] = testObservation(1, .spread, 0, 0.5);
    // The turn: the detector finds nothing for ten frames, then shaky frames.
    for (30..40) |index| observations[index] = FrameObservation.none;
    for (40..50) |index| observations[index] = testObservation(100 + index, .spread, @floatFromInt(index * 20), 0.05);
    for (50..90) |index| observations[index] = testObservation(2, .spread, 0, 0.5);
    // One frame of the second spread is the sharpest.
    observations[70].edge_support = 0.8;

    const timeline = try build(testing.allocator, &observations, test_options);
    defer timeline.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), timeline.segments.len);
    try testing.expectEqual(@as(usize, 4), timeline.pageCount());
    try testing.expectEqual(@as(u32, 0), timeline.segments[0].first_frame);
    try testing.expectEqual(@as(u32, 29), timeline.segments[0].last_frame);
    try testing.expectEqual(@as(u32, 50), timeline.segments[1].first_frame);
    try testing.expectEqual(@as(u32, 70), timeline.segments[1].reference);
}

test "a short break in one spread does not split it" {
    var observations: [80]FrameObservation = undefined;
    for (0..30) |index| observations[index] = testObservation(5, .single, 0, 0.5);
    // A hand passes for half a second and the camera moves a little.
    for (30..45) |index| observations[index] = FrameObservation.none;
    for (45..80) |index| observations[index] = testObservation(5, .single, 6, 0.5);

    const timeline = try build(testing.allocator, &observations, test_options);
    defer timeline.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), timeline.segments.len);
    try testing.expectEqual(@as(usize, 1), timeline.pageCount());
    try testing.expectEqual(@as(u32, 79), timeline.segments[0].last_frame);
}

test "a short stable moment during a turn is not a spread" {
    var observations: [60]FrameObservation = undefined;
    for (0..30) |index| observations[index] = testObservation(9, .spread, 0, 0.5);
    for (30..35) |index| observations[index] = testObservation(10, .spread, 0, 0.5);
    for (35..60) |index| observations[index] = FrameObservation.none;

    const timeline = try build(testing.allocator, &observations, test_options);
    defer timeline.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), timeline.segments.len);
}

test "a covered run is not a spread" {
    var observations: [40]FrameObservation = undefined;
    for (&observations) |*observation| {
        observation.* = testObservation(3, .single, 0, 0.5);
        // A hand covers the lower half of the page in every frame.
        for (observe.grid_cells / 2..observe.grid_cells) |cell| observation.pages[0].covered.set(cell);
    }
    const timeline = try build(testing.allocator, &observations, test_options);
    defer timeline.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), timeline.segments.len);
}

test "donors are frames at different places, in the order of the video" {
    var observations: [40]FrameObservation = undefined;
    // The camera drifts: the pages move a little in each frame.
    for (&observations, 0..) |*observation, index| {
        observation.* = testObservation(1, .spread, @as(f32, @floatFromInt(index)) * 1.5, 0.5);
    }
    const spans = [_]FrameSpan{.{ .first = 0, .last = 39 }};
    const donors = try selectDonors(testing.allocator, &observations, &spans, 20, null, .{ .count = 3 });
    defer testing.allocator.free(donors);
    try testing.expectEqual(@as(usize, 3), donors.len);
    // The two ends of the drift are the farthest from the reference in the middle.
    try testing.expectEqual(@as(u32, 0), donors[0]);
    try testing.expectEqual(@as(u32, 39), donors[2]);
    try testing.expect(donors[1] != 20);
}

test "spans that overlap give each frame one time" {
    var observations: [40]FrameObservation = undefined;
    for (&observations, 0..) |*observation, index| {
        observation.* = testObservation(1, .spread, @as(f32, @floatFromInt(index)) * 1.5, 0.5);
    }
    const spans = [_]FrameSpan{ .{ .first = 0, .last = 30 }, .{ .first = 10, .last = 39 } };
    const donors = try selectDonors(testing.allocator, &observations, &spans, 20, null, .{ .count = 6 });
    defer testing.allocator.free(donors);
    for (donors[1..], donors[0 .. donors.len - 1]) |later, earlier| try testing.expect(later > earlier);
}

test "frames that all look the same give no donors" {
    var observations: [20]FrameObservation = undefined;
    for (&observations) |*observation| observation.* = testObservation(1, .spread, 0, 0.5);
    const spans = [_]FrameSpan{.{ .first = 0, .last = 19 }};
    const donors = try selectDonors(testing.allocator, &observations, &spans, 5, null, .{});
    defer testing.allocator.free(donors);
    try testing.expectEqual(@as(usize, 0), donors.len);
}

test "a frame that shows the ink under the glare of the reference is a donor" {
    var observations: [30]FrameObservation = undefined;
    for (&observations) |*observation| observation.* = testObservation(1, .spread, 0, 0.5);
    // Text at one place of the left page: dark ink in a block of cells.
    const text_from = 20 * observe.ink_grid_width + 10;
    for (&observations) |*observation| {
        for (0..12) |offset| observation.pages[0].ink[text_from + offset] = 70;
    }
    // Glare washes the text out in most frames, also in the reference frame 15.
    for (&observations, 0..) |*observation, index| {
        if (index == 4 or index == 22) continue;
        for (0..12) |offset| observation.pages[0].ink[text_from + offset] = 180;
    }
    const spans = [_]FrameSpan{.{ .first = 0, .last = 29 }};
    const donors = try selectDonors(testing.allocator, &observations, &spans, 15, null, .{ .count = 3 });
    defer testing.allocator.free(donors);
    // The two clean frames are donors. No other frame differs, so no more are chosen.
    try testing.expectEqualSlices(u32, &.{ 4, 22 }, donors);
}

test "a frame that cuts a page is a donor when the aspect of the page is known" {
    var observations: [30]FrameObservation = undefined;
    for (&observations) |*observation| observation.* = testObservation(1, .spread, 0, 0.5);
    // Text in the top half of the left page: 4 rows of 30 cells, 20 rows from the top.
    const Text = struct {
        fn fill(observation: *FrameObservation, first_row: usize, rows: usize, value: u8) void {
            for (first_row..first_row + rows) |row| {
                for (10..40) |column| observation.pages[0].ink[row * observe.ink_grid_width + column] = value;
            }
        }
    };
    // Glare washes the text out in all frames that show the whole page.
    for (&observations) |*observation| Text.fill(observation, 20, 4, 180);
    // Frames 20 to 24 are a view from near. They show the top half of the page
    // only, with the text dark. In their own ink maps the text is two times as far
    // down and two times as high.
    for (observations[20..25]) |*near| {
        near.pages[0].clipped_edges = .{ .bottom = true };
        near.pages[0].quad.bl.y = 250;
        near.pages[0].quad.br.y = 250;
        near.pages[0].ink = @splat(200);
        Text.fill(near, 40, 8, 70);
    }
    const spans = [_]FrameSpan{.{ .first = 0, .last = 29 }};

    // The test page is 200 wide and 300 high.
    const with_aspect = try selectDonors(testing.allocator, &observations, &spans, 15, 0, .{ .count = 2, .page_aspect = 200.0 / 300.0 });
    defer testing.allocator.free(with_aspect);
    try testing.expectEqual(@as(usize, 2), with_aspect.len);
    // The first and the last frame of the view from near move too much from the frame next to them.
    for (with_aspect) |donor| try testing.expect(donor >= 21 and donor <= 23);

    // With no aspect, the place of the whole page in those frames is not known.
    const without = try selectDonors(testing.allocator, &observations, &spans, 15, 0, .{ .count = 2 });
    defer testing.allocator.free(without);
    for (without) |donor| try testing.expect(donor < 20 or donor > 24);
}

test "the reference of a page is a frame without glare on that page" {
    var observations: [30]FrameObservation = undefined;
    for (&observations) |*observation| observation.* = testObservation(1, .spread, 0, 0.5);
    // A block of text on the left page: dark ink in 6 rows of 40 cells.
    const Text = struct {
        fn fill(observation: *FrameObservation, value: u8) void {
            for (20..26) |row| {
                for (10..50) |column| observation.pages[0].ink[row * observe.ink_grid_width + column] = value;
            }
        }
    };
    // Glare washes the text out in the first 24 frames. The timeline chose frame 15.
    for (&observations, 0..) |*observation, index| Text.fill(observation, if (index < 24) 180 else 70);
    const spans = [_]FrameSpan{.{ .first = 0, .last = 29 }};

    const reference = try chooseReference(testing.allocator, &observations, &spans, 15, 0, .{});
    try testing.expect(reference.frame >= 24);
    try testing.expectEqual(@as(f32, 1), reference.ink);
    // The right page has the same ink in all frames: the first choice stays.
    const right = try chooseReference(testing.allocator, &observations, &spans, 15, 1, .{});
    try testing.expectEqual(@as(u32, 15), right.frame);

    // A frame that cuts the page is no reference for it, also when it has no glare.
    for (observations[24..]) |*observation| observation.pages[0].clipped_edges = .{ .left = true };
    const cut = try chooseReference(testing.allocator, &observations, &spans, 15, 0, .{});
    try testing.expectEqual(@as(u32, 15), cut.frame);
}

test "the timeline frees its memory when an allocation fails" {
    var observations: [90]FrameObservation = undefined;
    for (0..30) |index| observations[index] = testObservation(1, .spread, 0, 0.5);
    for (30..40) |index| observations[index] = FrameObservation.none;
    for (40..50) |index| observations[index] = testObservation(100 + index, .spread, @floatFromInt(index * 20), 0.05);
    for (50..90) |index| observations[index] = testObservation(2, .spread, 0, 0.5);

    const Check = struct {
        fn run(allocator: Allocator, frames: []const FrameObservation) !void {
            const timeline = try build(allocator, frames, test_options);
            defer timeline.deinit(allocator);
            try testing.expectEqual(@as(usize, 2), timeline.segments.len);
        }
    };
    try alloc_check.eachFailure(testing.allocator, Check.run, .{@as([]const FrameObservation, &observations)});
}

test "the donor choice and the reference choice free their memory when an allocation fails" {
    var observations: [30]FrameObservation = undefined;
    // The camera drifts, so frames are donors for their position too.
    for (&observations, 0..) |*observation, index| {
        observation.* = testObservation(1, .spread, @as(f32, @floatFromInt(index)) * 1.5, 0.5);
    }
    // Text on the left page. Glare washes it out in most frames, also in frame 15.
    const text_from = 20 * observe.ink_grid_width + 10;
    for (&observations, 0..) |*observation, index| {
        const clean = index == 4 or index == 22;
        for (0..12) |offset| observation.pages[0].ink[text_from + offset] = if (clean) 70 else 180;
    }
    // Two frames cut the left page: they come in the last step of the choice.
    for ([_]usize{ 8, 26 }) |index| observations[index].pages[0].clipped_edges = .{ .left = true };
    const spans = [_]FrameSpan{.{ .first = 0, .last = 29 }};

    const Check = struct {
        fn donors(allocator: Allocator, frames: []const FrameObservation, ranges: []const FrameSpan) !void {
            const chosen = try selectDonors(allocator, frames, ranges, 15, null, .{ .count = 4, .page_aspect = 200.0 / 300.0 });
            defer allocator.free(chosen);
            try testing.expect(chosen.len >= 2);
        }
        fn reference(allocator: Allocator, frames: []const FrameObservation, ranges: []const FrameSpan) !void {
            const chosen = try chooseReference(allocator, frames, ranges, 15, 0, .{});
            try testing.expect(chosen.frame < frames.len);
        }
    };
    const frames: []const FrameObservation = &observations;
    const ranges: []const FrameSpan = &spans;
    try alloc_check.eachFailure(testing.allocator, Check.donors, .{ frames, ranges });
    try alloc_check.eachFailure(testing.allocator, Check.reference, .{ frames, ranges });
}

// endregion: tests
