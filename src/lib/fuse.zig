//! Fusion: repair the page of the reference frame with pixels of other frames of
//! the same page.
//!
//! The rule is the one of `docs/decisions/0005-reference-plus-patch-fusion.md`: the
//! result is the reference frame, but for the places where the reference frame
//! disagrees with the other frames. There the result comes from another frame.
//!
//! All frames are flattened first (`enhance.flatten`): blank paper is at 1.0 in
//! each of them, so their brightness can be compared.
//!
//! - Glare makes ink brighter. It does not make paper brighter. So the frames with
//!   the darkest value at a place show the ink, as in the soft minimum of PhotoScan.
//!   The reference has glare where it is brighter than those frames.
//! - A finger has the colour of skin and comes in from an edge of the page or of
//!   the frame (`finger.zig`). A frame gives no data where it shows a finger, so a
//!   finger never moves from a donor frame into the result, and a finger on the
//!   reference goes away when another frame shows the paper.
//! - A part of the page outside the reference frame has no data at all.
//!
//! A fault that is at one place in all frames stays; the result never has invented
//! content. The one exception is a finger with blank paper around it: it hides
//! blank paper, so it gets the colour of that paper
//! (`docs/decisions/0014-paint-over-fingers.md`).
//!
//! Each connected region of faults takes its pixels from one donor frame, and only
//! from a donor that shows the same content as the reference around the region
//! (`docs/decisions/0013-page-reference-and-patch-check.md`).
//!
//! Sources of the ideas:
//! - S. W. Hasinoff, D. Sharlet, R. Geiss, A. Adams, J. T. Barron, F. Kainz,
//!   J. Chen, and M. Levoy, "Burst photography for high dynamic range and low-light
//!   imaging on mobile cameras", ACM Transactions on Graphics 35(6), 2016: another
//!   frame goes into the result only where it agrees with the reference frame.
//! - C. Liu, M. Rubinstein, M. Krainin, and B. Freeman, "PhotoScan: Taking
//!   Glare-Free Pictures of Pictures", Google Research blog, 2017: glare is an
//!   outlier among registered frames of the same subject.
//! - L.-W. He and Z. Zhang, "Real-time whiteboard capture and processing using a
//!   video camera for remote collaboration", IEEE Transactions on Multimedia 9(1),
//!   2007 (report MSR-TR-2004-91): the comparison works on cells, not on pixels, and
//!   a thing in front of the page is what differs from the stable content of a cell.

const std = @import("std");
const Allocator = std.mem.Allocator;
const image = @import("image.zig");
const color = @import("color.zig");
const raster = @import("raster.zig");
const finger = @import("finger.zig");

const RgbF32 = image.RgbF32;
const Plane = image.Plane;
const channels = image.rgb_channels;

// region: options and results

pub const Options = struct {
    /// The side of a comparison cell, in page pixels.
    cell: u32 = 8,
    /// The reference has glare in a cell when its ink value is this much above the
    /// ink value of the dark frames, on the scale where paper is 1.0. The ink value
    /// of a cell is the mean of its darkest pixels: thin text counts as much as a
    /// dark picture.
    deviation: f32 = 0.10,
    /// How to find a finger in a frame, and when to paint over one that stays.
    finger: finger.Options = .{},
    /// The repair covers this many cells more around each cell at fault.
    grow_cells: u8 = 2,
    /// A cell at fault needs this many cells at fault among its 8 neighbours. One
    /// cell alone is noise.
    min_fault_neighbours: u8 = 2,
    /// The patch check: around a region of faults, the donor must show the same
    /// content as the reference. The check looks at the cells with ink within this
    /// many cells of the region.
    ring_cells: u8 = 3,
    /// The check moves the donor by up to this many pixels to find the best fit. The
    /// repair then uses the donor at that position.
    ring_search_px: u8 = 12,
    /// The smallest correlation of the reference and the donor in the ring. Two
    /// different texts with lines at the same height reach about 0.5, and a donor
    /// that fits is above 0.8 on the benchmark video.
    min_ring_agreement: f32 = 0.7,
    /// The ring needs this many cells with ink for a check. With fewer cells the
    /// surroundings are blank paper, where an error of the position does not show.
    min_ring_cells: u8 = 4,
    /// A donor must repair this fraction of a region to be its donor.
    min_region_cover: f32 = 0.5,
    /// A cell that looks covered is a fault when its mean luma differs this much
    /// from the frames that show the page there.
    cover_deviation: f32 = 0.10,
    /// A cell is a dark area (a header bar, a picture) when the dark frames show a
    /// mean luma below this. Glare on a dark area leaves dark specks, so the ink
    /// value does not show it: there the mean luma is compared too.
    dark_area_luma: f32 = 0.6,
    /// Glare on dark print has the colour of the lamp, or of gold print: the cell
    /// has a mean luma below `tinted_area_luma` and red is this much above blue.
    glare_tint: f32 = 0.12,
    tinted_area_luma: f32 = 0.7,
    /// One frame alone shows the print below such glare when its cell is a dark
    /// area, darker than the reference by `deviation`, and has this much less tint.
    tint_deviation: f32 = 0.08,
};

/// One frame of the page: the reference or a donor.
pub const Layer = struct {
    /// The flattened page. All layers have the same size.
    page: RgbF32,
    /// `raster.mask_set` for the pixels that lie outside the frame, or null when the
    /// frame shows the whole page.
    outside: ?Plane = null,
};

pub const Stats = struct {
    /// Fractions of the page area.
    glare: f32 = 0,
    cover: f32 = 0,
    outside: f32 = 0,
    /// The part of the faults that no donor could repair.
    unrepaired: f32 = 0,

    /// The part of the faults where each donor failed the patch check.
    rejected: f32 = 0,
    /// The part of the page that shows a finger in all frames and has the colour
    /// of the paper now.
    painted: f32 = 0,
    /// The part of the page that shows a finger in all frames and still shows it:
    /// there is ink around the finger.
    finger_left: f32 = 0,

    pub fn repaired(self: Stats) f32 {
        return self.glare + self.cover + self.outside - self.unrepaired;
    }
};

/// What the fusion did in each cell, for a debug picture.
pub const FaultMap = struct {
    /// One value per cell, row after row.
    cells: []Cell,
    /// For each cell: true when the reference frame shows a finger there, or the
    /// margin or the halo of a finger.
    reference_covered: []bool,
    /// For each cell: the number of donor frames that show the page there.
    donors_with_data: []u8,
    grid_width: u32,
    grid_height: u32,
    /// The side of a cell in page pixels.
    cell: u32,

    pub const Cell = enum(u8) {
        clean,
        glare_repaired,
        glare_left,
        cover_repaired,
        cover_left,
        outside_repaired,
        outside_left,
        /// A fault where the donors did not agree with the reference around it.
        rejected,
        /// A finger in all frames, with the colour of the paper now.
        finger_painted,
        /// A finger in all frames that stays.
        finger_left,
    };

    pub fn deinit(self: FaultMap, allocator: Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.reference_covered);
        allocator.free(self.donors_with_data);
    }

    /// A copy that `allocator` owns.
    pub fn clone(self: FaultMap, allocator: Allocator) Allocator.Error!FaultMap {
        const cells = try allocator.dupe(Cell, self.cells);
        errdefer allocator.free(cells);
        const reference_covered = try allocator.dupe(bool, self.reference_covered);
        errdefer allocator.free(reference_covered);
        const donors_with_data = try allocator.dupe(u8, self.donors_with_data);
        var copy = self;
        copy.cells = cells;
        copy.reference_covered = reference_covered;
        copy.donors_with_data = donors_with_data;
        return copy;
    }
};

// endregion: options and results

// region: cell grid

const max_layers = 16;
const no_donor = 0;
/// A cell needs this fraction of its pixels inside the frame to count as data.
const min_inside_fraction = 0.75;

const Fault = enum(u8) { none, glare, cover, outside };

const CellGrid = struct {
    width: usize,
    height: usize,
    /// For each layer: the mean luma of each cell, then smoothed. NaN for a cell without data.
    luma: [][]f32,

    fn deinit(self: CellGrid, allocator: Allocator) void {
        for (self.luma) |plane| allocator.free(plane);
        allocator.free(self.luma);
    }
};

/// The number of darkest pixels of a cell that give its ink value.
const ink_pixels = 4;

/// What one layer shows in each cell, from one pass over its pixels. One value per
/// cell, row after row.
const LayerCells = struct {
    /// The ink value: the mean of the darkest pixels. NaN for a cell without data.
    ink: []f32,
    /// The mean luma. NaN for a cell without data.
    mean: []f32,
    /// The tint: the mean red minus the mean blue. Paper and black ink are near
    /// zero. NaN for a cell without data.
    tint: []f32,
    /// The colours for the finger mask.
    colors: finger.CellColors,

    fn deinit(self: LayerCells, allocator: Allocator) void {
        allocator.free(self.ink);
        allocator.free(self.mean);
        allocator.free(self.tint);
        self.colors.deinit(allocator);
    }
};

/// The three channels of a pixel, for arithmetic on all of them at a time.
const Color = @Vector(channels, f32);

/// Measure each cell of a layer. A cell with too many pixels outside the frame has
/// no data.
fn measureLayer(allocator: Allocator, layer: Layer, grid: finger.Grid) Allocator.Error!LayerCells {
    const count = grid.count();
    const ink = try allocator.alloc(f32, count);
    errdefer allocator.free(ink);
    const mean = try allocator.alloc(f32, count);
    errdefer allocator.free(mean);
    const tint = try allocator.alloc(f32, count);
    errdefer allocator.free(tint);
    const colors = try finger.CellColors.init(allocator, grid);
    const page = layer.page;
    const red = 0;
    const blue = 2;
    for (0..grid.height) |cell_y| {
        for (0..grid.width) |cell_x| {
            const x_start = cell_x * grid.cell;
            const y_start = cell_y * grid.cell;
            const x_end = @min(x_start + grid.cell, page.width);
            const y_end = @min(y_start + grid.cell, page.height);
            var sum: Color = @splat(0);
            var brightest = -std.math.inf(f32);
            var inside: f32 = 0;
            // The darkest values so far, in rising order.
            var darkest: [ink_pixels]f32 = @splat(std.math.inf(f32));
            for (y_start..y_end) |y| {
                for (x_start..x_end) |x| {
                    if (layer.outside) |mask| {
                        if (mask.at(x, y) != 0) continue;
                    }
                    const pixel = page.pixel(x, y).*;
                    sum += @as(Color, pixel);
                    inside += 1;
                    const luma = color.rgbLuma(pixel);
                    brightest = @max(brightest, luma);
                    if (luma < darkest[ink_pixels - 1]) {
                        var slot: usize = ink_pixels - 1;
                        while (slot > 0 and darkest[slot - 1] > luma) : (slot -= 1) darkest[slot] = darkest[slot - 1];
                        darkest[slot] = luma;
                    }
                }
            }
            const total: f32 = @floatFromInt((x_end - x_start) * (y_end - y_start));
            const index = cell_y * grid.width + cell_x;
            if (!(inside >= min_inside_fraction * total and inside >= ink_pixels)) {
                ink[index] = std.math.nan(f32);
                mean[index] = std.math.nan(f32);
                tint[index] = std.math.nan(f32);
                colors.mean[index] = @splat(0);
                colors.contrast[index] = std.math.nan(f32);
                continue;
            }
            var ink_sum: f32 = 0;
            for (darkest) |value| ink_sum += value;
            ink[index] = ink_sum / ink_pixels;
            const mean_color: [channels]f32 = sum / @as(Color, @splat(inside));
            // The luma is a weighted sum of the channels, so the luma of the mean
            // colour is the mean luma.
            mean[index] = color.rgbLuma(mean_color);
            tint[index] = mean_color[red] - mean_color[blue];
            colors.mean[index] = mean_color;
            colors.contrast[index] = brightest - darkest[0];
        }
    }
    return .{ .ink = ink, .mean = mean, .tint = tint, .colors = colors };
}

/// A 3x3 mean over the cells with data. A cell without data stays without data.
fn smoothCells(allocator: Allocator, values: []f32, grid_width: usize, grid_height: usize) Allocator.Error!void {
    const copy = try allocator.dupe(f32, values);
    defer allocator.free(copy);
    for (0..grid_height) |y| {
        for (0..grid_width) |x| {
            if (std.math.isNan(copy[y * grid_width + x])) continue;
            var sum: f32 = 0;
            var count: f32 = 0;
            const y_from = y -| 1;
            const y_to = @min(y + 1, grid_height - 1);
            const x_from = x -| 1;
            const x_to = @min(x + 1, grid_width - 1);
            for (y_from..y_to + 1) |ny| {
                for (x_from..x_to + 1) |nx| {
                    const value = copy[ny * grid_width + nx];
                    if (std.math.isNan(value)) continue;
                    sum += value;
                    count += 1;
                }
            }
            values[y * grid_width + x] = sum / count;
        }
    }
}

/// With this many frames at a cell, the second darkest value is the ink value.
const frames_for_second_darkest = 4;

// endregion: cell grid

// region: fuse

/// Repair `layers[0].page`, the reference, in place with the other layers. The
/// other layers must be aligned to the reference. `fault_map`, when given, gets a
/// map of what happened in each cell; the caller frees it with `allocator`.
pub fn fuse(allocator: Allocator, layers: []const Layer, options: Options, fault_map: ?*?FaultMap) Allocator.Error!Stats {
    if (fault_map) |out| out.* = null;
    if (layers.len == 0 or layers.len > max_layers) return .{};
    const reference = layers[0];
    const page = reference.page;
    const cell: usize = options.cell;
    const grid_width = (page.width + cell - 1) / cell;
    const grid_height = (page.height + cell - 1) / cell;
    const cell_count = grid_width * grid_height;

    // One pass over each layer gives its cell values and its fingers. A layer gives
    // no data where it shows a finger.
    const finger_grid: finger.Grid = .{ .width = grid_width, .height = grid_height, .cell = cell };
    var grid: CellGrid = .{ .width = grid_width, .height = grid_height, .luma = try allocator.alloc([]f32, layers.len) };
    // The mean luma and the tint of each cell, for each layer.
    const means = try allocator.alloc([]f32, layers.len);
    const tints = try allocator.alloc([]f32, layers.len);
    const masks = try allocator.alloc(finger.Mask, layers.len);
    const covered = try allocator.alloc([]const bool, layers.len);
    var built: usize = 0;
    var masks_built: usize = 0;
    defer {
        for (grid.luma[0..built], means[0..built], tints[0..built]) |ink_plane, mean_plane, tint_plane| {
            allocator.free(ink_plane);
            allocator.free(mean_plane);
            allocator.free(tint_plane);
        }
        for (masks[0..masks_built]) |mask| mask.deinit(allocator);
        allocator.free(grid.luma);
        allocator.free(means);
        allocator.free(tints);
        allocator.free(masks);
        allocator.free(covered);
    }
    {
        const no_data = try allocator.alloc(bool, cell_count);
        defer allocator.free(no_data);
        for (layers, 0..) |layer, index| {
            const cells = try measureLayer(allocator, layer, finger_grid);
            defer cells.colors.deinit(allocator);
            grid.luma[index] = cells.ink;
            means[index] = cells.mean;
            tints[index] = cells.tint;
            built = index + 1;
            try smoothCells(allocator, cells.ink, grid_width, grid_height);
            try smoothCells(allocator, cells.mean, grid_width, grid_height);
            try smoothCells(allocator, cells.tint, grid_width, grid_height);
            for (no_data, cells.mean) |*missing, value| missing.* = std.math.isNan(value);
            masks[index] = try finger.find(allocator, cells.colors, no_data, finger_grid, options.finger);
            masks_built = index + 1;
            covered[index] = masks[index].covered;
        }
    }

    // The fault of the reference and the best donor, for each cell.
    const fault = try allocator.alloc(Fault, cell_count);
    defer allocator.free(fault);
    const donor = try allocator.alloc(u8, cell_count);
    defer allocator.free(donor);
    @memset(donor, no_donor);
    for (0..cell_count) |index| {
        fault[index] = .none;
        // The frames that show the page at this cell.
        var values: [max_layers]f32 = undefined;
        var mean_values: [max_layers]f32 = undefined;
        var count: usize = 0;
        var usable_donors: usize = 0;
        for (grid.luma, means, covered, 0..) |plane, mean_plane, cover_plane, layer_index| {
            if (std.math.isNan(plane[index]) or cover_plane[index]) continue;
            values[count] = plane[index];
            mean_values[count] = mean_plane[index];
            count += 1;
            if (layer_index > 0) usable_donors += 1;
        }
        if (usable_donors == 0) continue;
        std.mem.sort(f32, values[0..count], {}, std.sort.asc(f32));
        std.mem.sort(f32, mean_values[0..count], {}, std.sort.asc(f32));
        // The dark frames show the ink. With four frames or more, the second darkest
        // value is safe against one frame with a shadow.
        const dark_rank: usize = if (count >= frames_for_second_darkest) 1 else 0;
        const dark_value = values[dark_rank];
        const dark_mean = mean_values[dark_rank];

        const reference_luma = grid.luma[0][index];
        const reference_mean = means[0][index];
        const washed_ink = reference_luma - dark_value > options.deviation;
        // Glare on a header bar or a picture: the area as a whole is brighter.
        const washed_area = dark_mean < options.dark_area_luma and reference_mean - dark_mean > options.deviation;
        // Glare with a tint on dark print. The frames can all have it but one, so
        // the second darkest value does not show it. The frame that shows the cell
        // darker and with less tint shows the print.
        var untinted: u8 = no_donor;
        const reference_tint = tints[0][index];
        if (reference_mean < options.tinted_area_luma and reference_tint >= options.glare_tint) {
            var darkest = options.dark_area_luma;
            for (means[1..], tints[1..], covered[1..], 1..) |mean_plane, tint_plane, cover_plane, layer_index| {
                // A comparison with NaN is false: a cell without data is no candidate.
                if (cover_plane[index] or !(mean_plane[index] < darkest)) continue;
                if (!(reference_mean - mean_plane[index] > options.deviation)) continue;
                if (!(reference_tint - tint_plane[index] > options.tint_deviation)) continue;
                darkest = mean_plane[index];
                untinted = @intCast(layer_index);
            }
        }

        if (std.math.isNan(reference_luma)) {
            fault[index] = .outside;
        } else if (covered[0][index] and coverDiffers(means, covered, index, options.cover_deviation)) {
            fault[index] = .cover;
        } else if (washed_ink or washed_area or untinted != no_donor) {
            fault[index] = .glare;
        }
        if (fault[index] == .none) continue;

        if (fault[index] == .glare and !washed_ink and !washed_area) {
            donor[index] = untinted;
            continue;
        }
        // The donor: the frame nearest to the dark value. For a dark area with ink
        // that looks right, the frame nearest to the dark mean.
        const by_mean = fault[index] == .glare and !washed_ink;
        var best_distance = std.math.inf(f32);
        for (grid.luma[1..], means[1..], covered[1..], 1..) |plane, mean_plane, cover_plane, layer_index| {
            if (std.math.isNan(plane[index]) or cover_plane[index]) continue;
            const distance = if (by_mean) @abs(mean_plane[index] - dark_mean) else @abs(plane[index] - dark_value);
            if (distance < best_distance) {
                best_distance = distance;
                donor[index] = @intCast(layer_index);
            }
        }
        // A donor that is as bright as the reference repairs nothing.
        if (fault[index] == .glare and donor[index] != no_donor) {
            const darker_ink = reference_luma - grid.luma[donor[index]][index] > options.deviation;
            const darker_area = reference_mean - means[donor[index]][index] > options.deviation;
            if (!darker_ink and !darker_area) {
                fault[index] = .none;
                donor[index] = no_donor;
            }
        }
    }

    // One cell at fault alone is noise.
    {
        const copy = try allocator.dupe(Fault, fault);
        defer allocator.free(copy);
        for (0..grid_height) |y| {
            for (0..grid_width) |x| {
                const index = y * grid_width + x;
                if (copy[index] == .none or copy[index] == .outside) continue;
                var neighbours: u8 = 0;
                const y_from = y -| 1;
                const y_to = @min(y + 1, grid_height - 1);
                const x_from = x -| 1;
                const x_to = @min(x + 1, grid_width - 1);
                for (y_from..y_to + 1) |ny| {
                    for (x_from..x_to + 1) |nx| {
                        if (ny == y and nx == x) continue;
                        if (copy[ny * grid_width + nx] != .none) neighbours += 1;
                    }
                }
                if (neighbours < options.min_fault_neighbours) {
                    fault[index] = .none;
                    donor[index] = no_donor;
                }
            }
        }
    }

    // One donor for each connected region of faults, checked against the reference
    // around the region. `donor` holds the choice of each cell alone up to here.
    const lumas = try allocator.alloc(Plane, layers.len);
    var lumas_built: usize = 0;
    defer {
        for (lumas[0..lumas_built]) |plane| plane.deinit(allocator);
        allocator.free(lumas);
    }
    for (layers, 0..) |layer, index| {
        lumas[index] = try lumaBytes(allocator, layer.page);
        lumas_built = index + 1;
    }
    const shifts = try allocator.alloc(Shift, cell_count);
    defer allocator.free(shifts);
    @memset(shifts, .{});
    const rejected = try allocator.alloc(bool, cell_count);
    defer allocator.free(rejected);
    @memset(rejected, false);
    try assignRegions(allocator, .{
        .layers = layers,
        .lumas = lumas,
        .fault = fault,
        .donor = donor,
        .shifts = shifts,
        .rejected = rejected,
        .ink = grid.luma,
        .means = means,
        .covered = covered,
        .grid_width = grid_width,
        .grid_height = grid_height,
        .cell = cell,
        .options = options,
    });

    var stats: Stats = .{};
    const cell_area = 1.0 / @as(f32, @floatFromInt(cell_count));
    for (fault, donor, rejected) |kind, chosen, was_rejected| {
        switch (kind) {
            .none => continue,
            .glare => stats.glare += cell_area,
            .cover => stats.cover += cell_area,
            .outside => stats.outside += cell_area,
        }
        if (chosen == no_donor) stats.unrepaired += cell_area;
        if (was_rejected) stats.rejected += cell_area;
    }
    if (fault_map) |out| {
        const cells = try allocator.alloc(FaultMap.Cell, cell_count);
        for (cells, fault, donor, rejected) |*value, kind, chosen, was_rejected| {
            const repaired = chosen != no_donor;
            value.* = if (was_rejected and !repaired) .rejected else switch (kind) {
                .none => .clean,
                .glare => if (repaired) .glare_repaired else .glare_left,
                .cover => if (repaired) .cover_repaired else .cover_left,
                .outside => if (repaired) .outside_repaired else .outside_left,
            };
        }
        errdefer allocator.free(cells);
        const reference_covered = try allocator.dupe(bool, covered[0]);
        errdefer allocator.free(reference_covered);
        const donors_with_data = try allocator.alloc(u8, cell_count);
        @memset(donors_with_data, 0);
        for (grid.luma[1..], covered[1..]) |plane, cover_plane| {
            for (donors_with_data, plane, cover_plane) |*count, value, is_covered| {
                if (!std.math.isNan(value) and !is_covered) count.* += 1;
            }
        }
        out.* = .{
            .cells = cells,
            .reference_covered = reference_covered,
            .donors_with_data = donors_with_data,
            .grid_width = @intCast(grid_width),
            .grid_height = @intCast(grid_height),
            .cell = options.cell,
        };
    }

    // The repair covers some cells more around each repaired cell: the border of a
    // glare patch is weak glare, below the limit. Each new cell takes the donor and
    // the shift of the cell next to it, when that donor has data there.
    const scratch = try allocator.alloc(u8, cell_count);
    defer allocator.free(scratch);
    // Some rounds more than the grown patch: the soft edge of the blend needs a donor too.
    const label_rounds = @as(usize, options.grow_cells) + blend_rounds;
    const alpha = try allocator.alloc(f32, cell_count);
    defer allocator.free(alpha);
    for (0..label_rounds) |round| {
        if (round == options.grow_cells) {
            // The cells that the repair covers at full strength.
            for (alpha, donor) |*value, chosen| value.* = if (chosen != no_donor) 1 else 0;
        }
        @memcpy(scratch, donor);
        for (0..grid_height) |y| {
            for (0..grid_width) |x| {
                const index = y * grid_width + x;
                if (scratch[index] != no_donor) continue;
                const y_from = y -| 1;
                const y_to = @min(y + 1, grid_height - 1);
                const x_from = x -| 1;
                const x_to = @min(x + 1, grid_width - 1);
                search: for (y_from..y_to + 1) |ny| {
                    for (x_from..x_to + 1) |nx| {
                        const neighbour_index = ny * grid_width + nx;
                        const neighbour = scratch[neighbour_index];
                        if (neighbour == no_donor) continue;
                        if (std.math.isNan(grid.luma[neighbour][index]) or covered[neighbour][index]) continue;
                        donor[index] = neighbour;
                        shifts[index] = shifts[neighbour_index];
                        break :search;
                    }
                }
            }
        }
    }
    if (options.grow_cells >= label_rounds) {
        for (alpha, donor) |*value, chosen| value.* = if (chosen != no_donor) 1 else 0;
    }

    // A soft edge: a 3x3 mean of the strength.
    const alpha_copy = try allocator.alloc(f32, cell_count);
    defer allocator.free(alpha_copy);
    for (0..blend_rounds) |_| {
        @memcpy(alpha_copy, alpha);
        for (0..grid_height) |y| {
            for (0..grid_width) |x| {
                var sum: f32 = 0;
                var count: f32 = 0;
                const y_from = y -| 1;
                const y_to = @min(y + 1, grid_height - 1);
                const x_from = x -| 1;
                const x_to = @min(x + 1, grid_width - 1);
                for (y_from..y_to + 1) |ny| {
                    for (x_from..x_to + 1) |nx| {
                        sum += alpha_copy[ny * grid_width + nx];
                        count += 1;
                    }
                }
                alpha[y * grid_width + x] = sum / count;
            }
        }
    }

    // Mix the pixels.
    const cell_float: f32 = @floatFromInt(cell);
    const last_x: i32 = @intCast(page.width - 1);
    const last_y: i32 = @intCast(page.height - 1);
    for (0..page.height) |y| {
        const cell_y = y / cell;
        const gy = std.math.clamp((@as(f32, @floatFromInt(y)) + 0.5) / cell_float - 0.5, 0, @as(f32, @floatFromInt(grid_height - 1)));
        const y0: usize = @intFromFloat(gy);
        const y1 = @min(y0 + 1, grid_height - 1);
        const fy = gy - @as(f32, @floatFromInt(y0));
        for (0..page.width) |x| {
            const cell_x = x / cell;
            const cell_index = cell_y * grid_width + cell_x;
            const chosen = donor[cell_index];
            if (chosen == no_donor) continue;
            const gx = std.math.clamp((@as(f32, @floatFromInt(x)) + 0.5) / cell_float - 0.5, 0, @as(f32, @floatFromInt(grid_width - 1)));
            const x0: usize = @intFromFloat(gx);
            const x1 = @min(x0 + 1, grid_width - 1);
            const fx = gx - @as(f32, @floatFromInt(x0));
            const top = alpha[y0 * grid_width + x0] * (1 - fx) + alpha[y0 * grid_width + x1] * fx;
            const bottom = alpha[y1 * grid_width + x0] * (1 - fx) + alpha[y1 * grid_width + x1] * fx;
            var strength = top * (1 - fy) + bottom * fy;

            // The donor pixel, at the position that the patch check found.
            const shift = shifts[cell_index];
            const from_x = @as(i32, @intCast(x)) + shift.x;
            const from_y = @as(i32, @intCast(y)) + shift.y;
            if (from_x < 0 or from_y < 0 or from_x > last_x or from_y > last_y) continue;
            const source = layers[chosen];
            if (source.outside) |mask| {
                if (mask.at(@intCast(from_x), @intCast(from_y)) != 0) continue;
            }
            // A pixel outside the reference frame has no reference value to keep.
            if (reference.outside) |mask| {
                if (mask.at(x, y) != 0) {
                    strength = 1;
                    mask.set(x, y, 0);
                }
            }
            if (strength <= 0) continue;
            const target = page.pixel(x, y);
            const from = source.page.pixel(@intCast(from_x), @intCast(from_y));
            for (0..channels) |channel| {
                target[channel] += strength * (from[channel] - target[channel]);
            }
        }
    }

    // A finger of the reference that no donor replaced is in all frames.
    {
        const left = try allocator.alloc(bool, cell_count);
        defer allocator.free(left);
        const finger_left = try allocator.alloc(bool, cell_count);
        defer allocator.free(finger_left);
        const skin_left = try allocator.alloc(bool, cell_count);
        defer allocator.free(skin_left);
        for (0..cell_count) |index| {
            const shows_reference = alpha[index] < full_repair;
            left[index] = masks[0].covered[index] and shows_reference;
            finger_left[index] = masks[0].finger[index] and shows_reference;
            skin_left[index] = masks[0].skin[index] and shows_reference;
        }
        const outcome = try allocator.alloc(finger.Outcome, cell_count);
        defer allocator.free(outcome);
        try finger.paint(allocator, page, reference.outside, left, finger_left, skin_left, finger_grid, options.finger, outcome);
        for (outcome, 0..) |result, index| {
            switch (result) {
                .none => continue,
                .painted => stats.painted += cell_area,
                .left => stats.finger_left += cell_area,
            }
            const map = if (fault_map) |out| out.* orelse continue else continue;
            map.cells[index] = if (result == .painted) .finger_painted else .finger_left;
        }
    }
    return stats;
}

/// A cell with a repair of this strength shows the donor frame only.
const full_repair = 0.999;

/// The soft edge of a repair is about two cells wide. A wide edge mixes the
/// reference with a donor over a whole word, and a small error of the alignment
/// then shows the word two times.
const blend_rounds = 1;

/// True when the frames that show the page in a cell show something that the
/// reference does not show there. A dark header bar next to a finger looks like a
/// part of the finger, but the other frames show the same bar: nothing is wrong.
fn coverDiffers(means: []const []f32, covered: []const []const bool, index: usize, deviation: f32) bool {
    var values: [max_layers]f32 = undefined;
    var count: usize = 0;
    for (means[1..], covered[1..]) |plane, cover_plane| {
        if (std.math.isNan(plane[index]) or cover_plane[index]) continue;
        values[count] = plane[index];
        count += 1;
    }
    if (count == 0 or std.math.isNan(means[0][index])) return true;
    std.mem.sort(f32, values[0..count], {}, std.sort.asc(f32));
    return @abs(means[0][index] - values[count / 2]) > deviation;
}

// endregion: fuse

// region: regions and the patch check

/// Where the donor pixel of a cell lies relative to the cell, in pixels.
const Shift = struct {
    x: i8 = 0,
    y: i8 = 0,
};

/// The byte value of blank paper in the luma planes of the patch check.
const luma_paper_code = 200.0;
/// A ring cell has ink when its ink value is below this, on the scale where paper is 1.0.
const ring_ink_value = 0.8;
/// The patch check reads every second pixel of a ring cell along each axis.
const ring_pixel_step = 2;
/// A shift must be this much better than no shift to be used.
const min_shift_gain = 0.02;
/// The regions are found and given a donor this many times: the cells that the
/// first donor of a region could not repair form new regions for the next round.
const region_rounds = 2;

/// The luma of a flattened page as bytes.
fn lumaBytes(allocator: Allocator, page: RgbF32) Allocator.Error!Plane {
    const plane = try Plane.init(allocator, page.width, page.height);
    for (plane.data, 0..) |*value, index| {
        const luma = color.rgbLuma(page.data[index * channels ..][0..channels].*);
        value.* = @intFromFloat(std.math.clamp(luma * luma_paper_code, 0, 255));
    }
    return plane;
}

const RegionContext = struct {
    layers: []const Layer,
    lumas: []const Plane,
    fault: []const Fault,
    /// In: the donor that each cell chose alone. Out: the donor of its region.
    donor: []u8,
    shifts: []Shift,
    rejected: []bool,
    /// The smoothed ink value of each cell, for each layer.
    ink: []const []f32,
    /// The smoothed mean luma of each cell, for each layer.
    means: []const []f32,
    covered: []const []const bool,
    grid_width: usize,
    grid_height: usize,
    cell: usize,
    options: Options,

    /// True when the layer shows the page in the cell.
    fn usable(self: *const RegionContext, layer: usize, index: usize) bool {
        return !std.math.isNan(self.ink[layer][index]) and !self.covered[layer][index];
    }

    /// True when the layer can repair the fault of the cell.
    fn repairs(self: *const RegionContext, layer: usize, index: usize) bool {
        if (!self.usable(layer, index)) return false;
        if (self.fault[index] != .glare) return true;
        // Darker ink, or a darker area as a whole.
        return self.ink[0][index] - self.ink[layer][index] > self.options.deviation or
            self.means[0][index] - self.means[layer][index] > self.options.deviation;
    }
};

/// Give each connected region of faults one donor. Two donors next to each other
/// are never aligned to the pixel, and a change of donor in the middle of a word
/// shows the word two times. The donor of a region must pass the patch check:
/// around the region, where the reference is good, it must show the same content.
///
/// The rule that another frame is used only where it agrees with the reference is
/// the idea of the merge of S. W. Hasinoff et al., "Burst photography for high
/// dynamic range and low-light imaging on mobile cameras", ACM Transactions on
/// Graphics 35(6), 2016. They compare the tile itself. Here the reference is wrong
/// inside the fault, so the comparison is around it.
fn assignRegions(allocator: Allocator, context: RegionContext) Allocator.Error!void {
    const cell_count = context.grid_width * context.grid_height;
    const first_choice = try allocator.dupe(u8, context.donor);
    defer allocator.free(first_choice);
    @memset(context.donor, no_donor);

    const visited = try allocator.alloc(bool, cell_count);
    defer allocator.free(visited);
    const stack = try allocator.alloc(u32, cell_count);
    defer allocator.free(stack);
    const region = try allocator.alloc(u32, cell_count);
    defer allocator.free(region);
    const ring = try allocator.alloc(u32, cell_count);
    defer allocator.free(ring);
    // The region that marked a cell as a ring cell last, so that each cell enters a ring one time.
    const ring_stamp = try allocator.alloc(u32, cell_count);
    defer allocator.free(ring_stamp);
    @memset(ring_stamp, 0);
    var stamp: u32 = 0;

    for (0..region_rounds) |_| {
        @memset(visited, false);
        for (0..cell_count) |seed| {
            if (!openCell(&context, first_choice, seed) or visited[seed]) continue;

            // The cells of the region, and how many of them chose each layer.
            var votes: [max_layers]u32 = @splat(0);
            var region_len: usize = 0;
            var stack_len: usize = 1;
            stack[0] = @intCast(seed);
            visited[seed] = true;
            while (stack_len > 0) {
                stack_len -= 1;
                const index = stack[stack_len];
                region[region_len] = index;
                region_len += 1;
                votes[first_choice[index]] += 1;
                const x = index % context.grid_width;
                const y = index / context.grid_width;
                const y_from = y -| 1;
                const y_to = @min(y + 1, context.grid_height - 1);
                const x_from = x -| 1;
                const x_to = @min(x + 1, context.grid_width - 1);
                for (y_from..y_to + 1) |ny| {
                    for (x_from..x_to + 1) |nx| {
                        const neighbour = ny * context.grid_width + nx;
                        if (visited[neighbour] or !openCell(&context, first_choice, neighbour)) continue;
                        visited[neighbour] = true;
                        stack[stack_len] = @intCast(neighbour);
                        stack_len += 1;
                    }
                }
            }
            const cells = region[0..region_len];

            // The layers that can be the donor of the region: each one agrees with
            // the reference around the region, or has nothing there to compare.
            var candidates: [max_layers]Candidate = undefined;
            var candidate_count: usize = 0;
            for (1..context.layers.len) |candidate| {
                var repaired: usize = 0;
                for (cells) |index| {
                    if (context.repairs(candidate, index)) repaired += 1;
                }
                if (@as(f32, @floatFromInt(repaired)) < context.options.min_region_cover * @as(f32, @floatFromInt(region_len))) continue;

                stamp += 1;
                const ring_len = collectRing(&context, cells, candidate, ring, ring_stamp, stamp);
                // Blank paper around the region, or a ring with no contrast in the
                // reference: nothing to check, and nothing to show an error.
                const fit: ?RingFit = if (ring_len < context.options.min_ring_cells) null else ringFit(&context, ring[0..ring_len], candidate);
                var quality: f32 = undefined;
                var shift: Shift = .{};
                if (fit) |found| {
                    if (found.agreement < context.options.min_ring_agreement) continue;
                    // The best shift at the end of the range: the real position
                    // can be farther off, so the donor is not safe.
                    const range = context.options.ring_search_px;
                    if (@abs(found.shift.x) >= range or @abs(found.shift.y) >= range) continue;
                    quality = found.agreement * @min(found.sharpness, 1);
                    shift = found.shift;
                } else {
                    // Below each checked layer, in the order of the votes.
                    quality = unchecked_quality * @as(f32, @floatFromInt(votes[candidate])) / @as(f32, @floatFromInt(region_len));
                }
                candidates[candidate_count] = .{
                    .layer = candidate,
                    .shift = shift,
                    .quality = quality,
                    .sharpness = innerSharpness(&context, cells, candidate, shift),
                };
                candidate_count += 1;
            }

            // The donor of the region: the layer that agrees best with the reference
            // around the region, is as sharp there, and is sharp in the region. With
            // nothing around the region to compare, the votes take the place of the
            // agreement.
            var sharpest: f32 = 0;
            for (candidates[0..candidate_count]) |candidate| sharpest = @max(sharpest, candidate.sharpness);
            var chosen: ?usize = null;
            var chosen_shift: Shift = .{};
            var chosen_quality: f32 = -1;
            for (candidates[0..candidate_count]) |candidate| {
                // A region of blank paper has only noise: no layer is sharper there.
                const relative = if (sharpest >= min_inner_sharpness) candidate.sharpness / sharpest else 1;
                const quality = candidate.quality * relative;
                if (quality > chosen_quality) {
                    chosen = candidate.layer;
                    chosen_shift = candidate.shift;
                    chosen_quality = quality;
                }
            }

            if (chosen) |layer| {
                for (cells) |index| {
                    if (!context.repairs(layer, index)) continue;
                    context.donor[index] = @intCast(layer);
                    context.shifts[index] = chosen_shift;
                }
            } else {
                for (cells) |index| context.rejected[index] = true;
            }
        }
    }
}

/// A layer that can be the donor of a region.
const Candidate = struct {
    layer: usize,
    shift: Shift,
    /// The agreement with the reference around the region and the sharpness there,
    /// or the share of the votes when there is nothing to compare.
    quality: f32,
    /// `innerSharpness` of the layer in the region.
    sharpness: f32,
};

/// The sharpest layer of a region must reach this value for the sharpness to count,
/// in luma codes of the patch check. Below it the region shows blank paper.
const min_inner_sharpness = 4.0;

/// How sharp a layer is in the cells of a region that it repairs, at its shift: the
/// root mean square of the luma difference of two pixels next to each other, for
/// the direction where it is smaller. Blur makes each edge wide and the squares
/// small; the blur of a camera that moves does that in one direction only. The
/// reference cannot be the measure here: it is wrong in the region.
///
/// The sum of squared gradients as a measure of focus is the Tenengrad measure:
/// J. M. Tenenbaum, "Accommodation in computer vision", PhD thesis, Stanford
/// University, 1970, and E. Krotkov, "Focusing", International Journal of Computer
/// Vision 1(3), 1987.
fn innerSharpness(context: *const RegionContext, cells: []const u32, layer: usize, shift: Shift) f32 {
    const plane = context.lumas[layer];
    const outside = context.layers[layer].outside;
    // The pixel to the right and the pixel below must exist.
    const last_x = @as(i32, @intCast(plane.width)) - 2;
    const last_y = @as(i32, @intCast(plane.height)) - 2;
    var sum_x: u64 = 0;
    var sum_y: u64 = 0;
    var count: u64 = 0;
    for (cells) |index| {
        if (!context.repairs(layer, index)) continue;
        const x_start = (index % context.grid_width) * context.cell;
        const y_start = (index / context.grid_width) * context.cell;
        const x_end = @min(x_start + context.cell, plane.width);
        const y_end = @min(y_start + context.cell, plane.height);
        for (y_start..y_end) |y| {
            const from_y = @as(i32, @intCast(y)) + shift.y;
            if (from_y < 0 or from_y > last_y) continue;
            for (x_start..x_end) |x| {
                const from_x = @as(i32, @intCast(x)) + shift.x;
                if (from_x < 0 or from_x > last_x) continue;
                const at_x: usize = @intCast(from_x);
                const at_y: usize = @intCast(from_y);
                if (outside) |mask| {
                    if (mask.at(at_x, at_y) != 0) continue;
                }
                const here: i32 = plane.at(at_x, at_y);
                const right = @as(i32, plane.at(at_x + 1, at_y)) - here;
                const below = @as(i32, plane.at(at_x, at_y + 1)) - here;
                sum_x += @intCast(right * right);
                sum_y += @intCast(below * below);
                count += 1;
            }
        }
    }
    if (count == 0) return 0;
    return @sqrt(@as(f32, @floatFromInt(@min(sum_x, sum_y))) / @as(f32, @floatFromInt(count)));
}

/// A cell that still needs a region donor.
fn openCell(context: *const RegionContext, first_choice: []const u8, index: usize) bool {
    return context.fault[index] != .none and first_choice[index] != no_donor and
        context.donor[index] == no_donor and !context.rejected[index];
}

/// The cells around a region where the reference and the layer both show ink and
/// the reference has no fault. Returns the number of cells written to `ring`.
fn collectRing(
    context: *const RegionContext,
    cells: []const u32,
    layer: usize,
    ring: []u32,
    ring_stamp: []u32,
    stamp: u32,
) usize {
    const reach: usize = context.options.ring_cells;
    var count: usize = 0;
    for (cells) |index| {
        const x = index % context.grid_width;
        const y = index / context.grid_width;
        const y_from = y -| reach;
        const y_to = @min(y + reach, context.grid_height - 1);
        const x_from = x -| reach;
        const x_to = @min(x + reach, context.grid_width - 1);
        for (y_from..y_to + 1) |ny| {
            for (x_from..x_to + 1) |nx| {
                const neighbour = ny * context.grid_width + nx;
                if (ring_stamp[neighbour] == stamp) continue;
                ring_stamp[neighbour] = stamp;
                if (context.fault[neighbour] != .none) continue;
                if (!context.usable(0, neighbour) or !context.usable(layer, neighbour)) continue;
                if (!(context.ink[0][neighbour] < ring_ink_value)) continue;
                ring[count] = @intCast(neighbour);
                count += 1;
            }
        }
    }
    return count;
}

const RingFit = struct {
    shift: Shift,
    /// The correlation of the reference and the layer in the ring, at the shift.
    agreement: f32,
    /// The contrast of the layer in the ring as a fraction of the contrast of the
    /// reference. A blurred layer has less contrast.
    sharpness: f32,
};

/// The quality of a layer that could not be checked is at most this: below each
/// checked layer that is not badly blurred.
const unchecked_quality = 0.25;
/// The step of the first pass of the shift search, in pixels.
const coarse_shift_step = 2;

/// Find the shift of the layer, within the search range, that makes it agree best
/// with the reference in the ring cells. Returns null when the reference has no
/// contrast in the ring: then there is nothing to compare.
fn ringFit(context: *const RegionContext, ring: []const u32, layer: usize) ?RingFit {
    const reference = context.lumas[0];
    const other = context.lumas[layer];
    const outside = context.layers[layer].outside;
    const radius: i32 = context.options.ring_search_px;
    const width: i32 = @intCast(reference.width);
    const height: i32 = @intCast(reference.height);

    // The contrast of the reference does not depend on the shift.
    {
        var sums: Sums = .{};
        for (ring) |index| {
            const x_start = (index % context.grid_width) * context.cell;
            const y_start = (index / context.grid_width) * context.cell;
            const x_end = @min(x_start + context.cell, reference.width);
            const y_end = @min(y_start + context.cell, reference.height);
            var y = y_start;
            while (y < y_end) : (y += ring_pixel_step) {
                var x = x_start;
                while (x < x_end) : (x += ring_pixel_step) {
                    const a = reference.at(x, y);
                    sums.add(a, a);
                }
            }
        }
        if (sums.count < min_ring_pixels or sums.varianceA() < min_ring_variance) return null;
    }

    const search: RingSearch = .{
        .context = context,
        .ring = ring,
        .reference = reference,
        .other = other,
        .outside = outside,
        .width = width,
        .height = height,
    };
    // A coarse pass over the range, then the shifts next to the best one.
    const at_zero = search.at(0, 0);
    var best = at_zero;
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += coarse_shift_step) {
        var dx: i32 = -radius;
        while (dx <= radius) : (dx += coarse_shift_step) {
            const fit = search.at(dx, dy);
            if (fit.agreement > best.agreement) best = fit;
        }
    }
    const center = best.shift;
    var fine_y: i32 = -1;
    while (fine_y <= 1) : (fine_y += 1) {
        var fine_x: i32 = -1;
        while (fine_x <= 1) : (fine_x += 1) {
            const shift_x = @as(i32, center.x) + fine_x;
            const shift_y = @as(i32, center.y) + fine_y;
            if (@abs(shift_x) > radius or @abs(shift_y) > radius) continue;
            const fit = search.at(shift_x, shift_y);
            if (fit.agreement > best.agreement) best = fit;
        }
    }
    // A shift that is not clearly better than no shift is noise.
    if (at_zero.agreement >= best.agreement - min_shift_gain) return at_zero;
    return best;
}

const RingSearch = struct {
    context: *const RegionContext,
    ring: []const u32,
    reference: Plane,
    other: Plane,
    outside: ?Plane,
    width: i32,
    height: i32,

    /// Compare the reference with the layer moved by one shift.
    fn at(self: *const RingSearch, dx: i32, dy: i32) RingFit {
        const context = self.context;
        var sums: Sums = .{};
        for (self.ring) |index| {
            const x_start = (index % context.grid_width) * context.cell;
            const y_start = (index / context.grid_width) * context.cell;
            const x_end = @min(x_start + context.cell, self.reference.width);
            const y_end = @min(y_start + context.cell, self.reference.height);
            var y = y_start;
            while (y < y_end) : (y += ring_pixel_step) {
                const other_y = @as(i32, @intCast(y)) + dy;
                if (other_y < 0 or other_y >= self.height) continue;
                var x = x_start;
                while (x < x_end) : (x += ring_pixel_step) {
                    const other_x = @as(i32, @intCast(x)) + dx;
                    if (other_x < 0 or other_x >= self.width) continue;
                    if (self.outside) |mask| {
                        if (mask.at(@intCast(other_x), @intCast(other_y)) != 0) continue;
                    }
                    sums.add(self.reference.at(x, y), self.other.at(@intCast(other_x), @intCast(other_y)));
                }
            }
        }
        return .{
            .shift = .{ .x = @intCast(dx), .y = @intCast(dy) },
            .agreement = sums.correlation(),
            .sharpness = sums.contrastRatio(),
        };
    }
};

/// The sums for the correlation of two sets of byte values.
const Sums = struct {
    count: u64 = 0,
    a: u64 = 0,
    b: u64 = 0,
    aa: u64 = 0,
    bb: u64 = 0,
    ab: u64 = 0,

    fn add(self: *Sums, first: u8, second: u8) void {
        const a: u64 = first;
        const b: u64 = second;
        self.count += 1;
        self.a += a;
        self.b += b;
        self.aa += a * a;
        self.bb += b * b;
        self.ab += a * b;
    }

    fn varianceA(self: Sums) f64 {
        if (self.count == 0) return 0;
        const n: f64 = @floatFromInt(self.count);
        const mean = @as(f64, @floatFromInt(self.a)) / n;
        return @as(f64, @floatFromInt(self.aa)) / n - mean * mean;
    }

    /// The contrast of the second set as a fraction of the contrast of the first.
    fn contrastRatio(self: Sums) f32 {
        if (self.count == 0) return 0;
        const n: f64 = @floatFromInt(self.count);
        const mean_a = @as(f64, @floatFromInt(self.a)) / n;
        const mean_b = @as(f64, @floatFromInt(self.b)) / n;
        const variance_a = @as(f64, @floatFromInt(self.aa)) / n - mean_a * mean_a;
        const variance_b = @as(f64, @floatFromInt(self.bb)) / n - mean_b * mean_b;
        if (variance_a < min_ring_variance) return 0;
        return @floatCast(@sqrt(@max(variance_b, 0) / variance_a));
    }

    /// The correlation, or 0 when one of the two sets has no contrast: a donor that
    /// shows blank paper where the reference has ink does not agree with it.
    fn correlation(self: Sums) f32 {
        if (self.count < min_ring_pixels) return 0;
        const n: f64 = @floatFromInt(self.count);
        const mean_a = @as(f64, @floatFromInt(self.a)) / n;
        const mean_b = @as(f64, @floatFromInt(self.b)) / n;
        const variance_a = @as(f64, @floatFromInt(self.aa)) / n - mean_a * mean_a;
        const variance_b = @as(f64, @floatFromInt(self.bb)) / n - mean_b * mean_b;
        if (variance_a < min_ring_variance or variance_b < min_ring_variance) return 0;
        const covariance = @as(f64, @floatFromInt(self.ab)) / n - mean_a * mean_b;
        return @floatCast(covariance / @sqrt(variance_a * variance_b));
    }
};

const min_ring_pixels = 32;
const min_ring_variance = 4.0;

// endregion: regions and the patch check

// region: tests

const testing = std.testing;

const test_page_width = 160;
/// The page of the tests with a finger: a finger needs more space.
const test_finger_page_width = 320;
/// The tests give the sizes of the finger rule in cells of their small page.
const test_options: Options = .{ .finger = .{ .reference_page_width = test_page_width } };
const test_finger_options: Options = .{ .finger = .{ .reference_page_width = test_finger_page_width } };

/// A page with a dark bar on white paper.
fn testPage(allocator: Allocator) !RgbF32 {
    const page = try RgbF32.init(allocator, test_page_width, 200);
    for (0..page.height) |y| {
        for (0..page.width) |x| {
            const ink = y >= 60 and y < 100 and x >= 20 and x < 140;
            page.pixel(x, y).* = @splat(if (ink) 0.15 else 1.0);
        }
    }
    return page;
}

fn fillRect(page: RgbF32, x_from: usize, x_to: usize, y_from: usize, y_to: usize, value: f32) void {
    for (y_from..y_to) |y| {
        for (x_from..x_to) |x| page.pixel(x, y).* = @splat(value);
    }
}

const skin = [channels]f32{ 0.6, 0.35, 0.3 };

fn fillFinger(page: RgbF32, x_from: usize, x_to: usize, y_from: usize, y_to: usize) void {
    for (y_from..y_to) |y| {
        for (x_from..x_to) |x| page.pixel(x, y).* = skin;
    }
}

/// Glare has the colour of the lamp: bright, but not neutral.
fn fillGlare(page: RgbF32, x_from: usize, x_to: usize, y_from: usize, y_to: usize) void {
    for (y_from..y_to) |y| {
        for (x_from..x_to) |x| page.pixel(x, y).* = .{ 0.95, 0.85, 0.6 };
    }
}

test "glare on the reference goes away with clean donors" {
    var pages: [4]RgbF32 = undefined;
    for (&pages) |*page| page.* = try testPage(testing.allocator);
    defer for (pages) |page| page.deinit(testing.allocator);
    // Glare on the reference: a part of the bar is bright.
    fillGlare(pages[0], 40, 90, 60, 100);
    // One donor has glare at another place.
    fillGlare(pages[2], 100, 140, 60, 100);

    const layers = [_]Layer{ .{ .page = pages[0] }, .{ .page = pages[1] }, .{ .page = pages[2] }, .{ .page = pages[3] } };
    const stats = try fuse(testing.allocator, &layers, test_options, null);
    try testing.expect(stats.glare > 0.03);
    try testing.expectEqual(@as(f32, 0), stats.cover);
    try testing.expect(stats.unrepaired < 0.005);
    // The bar is dark again where the glare was, and the rest did not change.
    try testing.expectApproxEqAbs(@as(f32, 0.15), pages[0].pixel(65, 80)[1], 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0.15), pages[0].pixel(120, 80)[1], 0.02);
    try testing.expectApproxEqAbs(@as(f32, 1.0), pages[0].pixel(80, 150)[1], 0.02);
}

test "glare in most frames goes away with one clean donor" {
    var pages: [5]RgbF32 = undefined;
    for (&pages) |*page| page.* = try testPage(testing.allocator);
    defer for (pages) |page| page.deinit(testing.allocator);
    // The same glare in the reference and in two of the four donors.
    for ([_]usize{ 0, 1, 2 }) |index| fillGlare(pages[index], 40, 90, 60, 100);

    const layers = [_]Layer{ .{ .page = pages[0] }, .{ .page = pages[1] }, .{ .page = pages[2] }, .{ .page = pages[3] }, .{ .page = pages[4] } };
    _ = try fuse(testing.allocator, &layers, test_options, null);
    try testing.expectApproxEqAbs(@as(f32, 0.15), pages[0].pixel(65, 80)[1], 0.02);
}

test "a finger on the reference goes away, a finger in all frames stays" {
    var pages: [4]RgbF32 = undefined;
    for (&pages) |*page| page.* = try testPage(testing.allocator);
    defer for (pages) |page| page.deinit(testing.allocator);
    // A finger only on the reference. It comes in from the bottom edge.
    fillFinger(pages[0], 16, 72, 144, 200);
    // A finger at the same place in all frames.
    for (pages) |page| fillFinger(page, 96, 152, 152, 200);

    const layers = [_]Layer{ .{ .page = pages[0] }, .{ .page = pages[1] }, .{ .page = pages[2] }, .{ .page = pages[3] } };
    const stats = try fuse(testing.allocator, &layers, .{ .finger = .{ .paint = .none, .reference_page_width = test_page_width } }, null);
    try testing.expect(stats.cover > 0.03);
    try testing.expectEqual(@as(f32, 0), stats.painted);
    try testing.expect(stats.finger_left > 0.03);
    try testing.expectApproxEqAbs(@as(f32, 1.0), pages[0].pixel(44, 180)[1], 0.02);
    try testing.expectApproxEqAbs(skin[1], pages[0].pixel(124, 185)[1], 0.02);
}

test "a finger in the donor frames does not come onto a clean reference" {
    var pages: [4]RgbF32 = undefined;
    for (&pages) |*page| page.* = try testPage(testing.allocator);
    defer for (pages) |page| page.deinit(testing.allocator);
    // All three donors have a finger where the reference shows paper.
    for (pages[1..]) |page| fillFinger(page, 16, 72, 144, 200);
    const before = try testing.allocator.dupe(f32, pages[0].data);
    defer testing.allocator.free(before);

    const layers = [_]Layer{ .{ .page = pages[0] }, .{ .page = pages[1] }, .{ .page = pages[2] }, .{ .page = pages[3] } };
    _ = try fuse(testing.allocator, &layers, test_options, null);
    try testing.expectEqualSlices(f32, before, pages[0].data);
}

test "a finger in a donor frame that the frame cuts does not come onto the reference" {
    var pages: [3]RgbF32 = undefined;
    for (&pages) |*page| page.* = try testPage(testing.allocator);
    defer for (pages) |page| page.deinit(testing.allocator);
    // The two donors end at row 176. Their finger touches that row, not the page border.
    var masks: [2]Plane = undefined;
    for (&masks, pages[1..]) |*mask, page| {
        mask.* = try Plane.initFilled(testing.allocator, page.width, page.height, 0);
        for (176..page.height) |y| @memset(mask.row(y), raster.mask_set);
        fillFinger(page, 16, 72, 120, 176);
    }
    defer for (masks) |mask| mask.deinit(testing.allocator);
    const before = try testing.allocator.dupe(f32, pages[0].data);
    defer testing.allocator.free(before);

    const layers = [_]Layer{ .{ .page = pages[0] }, .{ .page = pages[1], .outside = masks[0] }, .{ .page = pages[2], .outside = masks[1] } };
    _ = try fuse(testing.allocator, &layers, test_options, null);
    try testing.expectEqualSlices(f32, before, pages[0].data);
}

test "a finger in all frames with blank paper around it gets the colour of the paper" {
    // A page that is large enough for a finger to be a small part of it.
    var pages: [3]RgbF32 = undefined;
    for (&pages) |*page| {
        page.* = try RgbF32.init(testing.allocator, test_finger_page_width, 400);
        for (page.data) |*value| value.* = 1.0;
        fillRect(page.*, 40, 280, 100, 140, 0.15);
        fillFinger(page.*, 128, 192, 336, 400);
    }
    defer for (pages) |page| page.deinit(testing.allocator);

    const layers = [_]Layer{ .{ .page = pages[0] }, .{ .page = pages[1] }, .{ .page = pages[2] } };
    var map: ?FaultMap = null;
    defer if (map) |found| found.deinit(testing.allocator);
    const stats = try fuse(testing.allocator, &layers, test_finger_options, &map);
    try testing.expect(stats.painted > 0.03);
    try testing.expectEqual(@as(f32, 0), stats.finger_left);
    try testing.expectApproxEqAbs(@as(f32, 1.0), pages[0].pixel(160, 360)[1], 0.02);
    // The bar is as it was.
    try testing.expectApproxEqAbs(@as(f32, 0.15), pages[0].pixel(160, 120)[1], 0.001);
    const cells = map.?;
    try testing.expectEqual(FaultMap.Cell.finger_painted, cells.cells[(360 / 8) * cells.grid_width + 160 / 8]);
}

test "a finger alone on a page with no other frame gets the colour of the paper" {
    const page = try RgbF32.init(testing.allocator, test_finger_page_width, 400);
    defer page.deinit(testing.allocator);
    for (page.data) |*value| value.* = 1.0;
    fillFinger(page, 128, 192, 336, 400);

    const stats = try fuse(testing.allocator, &.{.{ .page = page }}, test_finger_options, null);
    try testing.expect(stats.painted > 0.03);
    try testing.expectApproxEqAbs(@as(f32, 1.0), page.pixel(160, 360)[1], 0.02);
}

test "a part outside the reference frame comes from one donor" {
    var pages: [2]RgbF32 = undefined;
    for (&pages) |*page| page.* = try testPage(testing.allocator);
    defer for (pages) |page| page.deinit(testing.allocator);
    // The reference frame did not show the top 48 rows: they hold no data.
    const outside = try Plane.initFilled(testing.allocator, pages[0].width, pages[0].height, 0);
    defer outside.deinit(testing.allocator);
    for (0..48) |y| {
        for (0..pages[0].width) |x| outside.set(x, y, raster.mask_set);
    }
    fillRect(pages[0], 0, pages[0].width, 0, 48, 0.5);
    // The donor has a mark there.
    fillRect(pages[1], 60, 100, 10, 30, 0.2);

    const layers = [_]Layer{ .{ .page = pages[0], .outside = outside }, .{ .page = pages[1] } };
    const stats = try fuse(testing.allocator, &layers, test_options, null);
    try testing.expect(stats.outside > 0.2);
    try testing.expect(stats.unrepaired < 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.2), pages[0].pixel(80, 20)[1], 0.02);
    try testing.expectApproxEqAbs(@as(f32, 1.0), pages[0].pixel(20, 20)[1], 0.02);
    try testing.expectEqual(@as(u8, 0), outside.at(80, 20));
}

test "frames that agree change nothing" {
    var pages: [3]RgbF32 = undefined;
    for (&pages) |*page| page.* = try testPage(testing.allocator);
    defer for (pages) |page| page.deinit(testing.allocator);
    const before = try testing.allocator.dupe(f32, pages[0].data);
    defer testing.allocator.free(before);
    const layers = [_]Layer{ .{ .page = pages[0] }, .{ .page = pages[1] }, .{ .page = pages[2] } };
    const stats = try fuse(testing.allocator, &layers, test_options, null);
    try testing.expectEqual(@as(f32, 0), stats.repaired());
    try testing.expectEqualSlices(f32, before, pages[0].data);
}

test "glare on a dark bar goes away when it leaves dark specks" {
    var pages: [4]RgbF32 = undefined;
    for (&pages) |*page| page.* = try testPage(testing.allocator);
    defer for (pages) |page| page.deinit(testing.allocator);
    // The glare makes a part of the bar bright, but each cell keeps some dark pixels:
    // the ink value of the cells stays dark.
    for (60..100) |y| {
        for (40..100) |x| {
            if (x % 4 == 0 and y % 4 == 0) continue;
            pages[0].pixel(x, y).* = .{ 0.8, 0.7, 0.4 };
        }
    }

    const layers = [_]Layer{ .{ .page = pages[0] }, .{ .page = pages[1] }, .{ .page = pages[2] }, .{ .page = pages[3] } };
    const stats = try fuse(testing.allocator, &layers, test_options, null);
    try testing.expect(stats.glare > 0.03);
    try testing.expectApproxEqAbs(@as(f32, 0.15), pages[0].pixel(70, 81)[1], 0.03);
    // The paper next to the bar stays as it is.
    try testing.expectApproxEqAbs(@as(f32, 1.0), pages[0].pixel(70, 130)[1], 0.02);
}

/// A page with rows of short dark dashes, as the words of a text. `seed` gives the pattern.
fn testTextPage(allocator: Allocator, seed: u64, shift_x: i32, shift_y: i32) !RgbF32 {
    const page = try RgbF32.init(allocator, 160, 200);
    @memset(page.data, 1.0);
    var random = std.Random.DefaultPrng.init(seed);
    var row_y: i32 = 20;
    while (row_y < 180) : (row_y += 20) {
        var x: i32 = 10;
        while (x < 140) {
            const word = 4 + random.random().intRangeAtMost(i32, 0, 12);
            const gap = 3 + random.random().intRangeAtMost(i32, 0, 6);
            var y = row_y;
            while (y < row_y + 7) : (y += 1) {
                var column = x;
                while (column < x + word) : (column += 1) {
                    const at_x = column + shift_x;
                    const at_y = y + shift_y;
                    if (at_x < 0 or at_y < 0 or at_x >= 160 or at_y >= 200) continue;
                    page.pixel(@intCast(at_x), @intCast(at_y)).* = @splat(0.15);
                }
            }
            x += word + gap;
        }
    }
    return page;
}

/// The mean difference of the green channel of two pages in a rectangle.
fn meanDifference(a: RgbF32, b: RgbF32, x_from: usize, x_to: usize, y_from: usize, y_to: usize) f32 {
    var sum: f32 = 0;
    for (y_from..y_to) |y| {
        for (x_from..x_to) |x| sum += @abs(a.pixel(x, y)[1] - b.pixel(x, y)[1]);
    }
    return sum / @as(f32, @floatFromInt((x_to - x_from) * (y_to - y_from)));
}

test "glare with a tint on a dark bar goes away when one frame alone shows the bar" {
    var pages: [5]RgbF32 = undefined;
    for (&pages) |*page| page.* = try testPage(testing.allocator);
    defer for (pages) |page| page.deinit(testing.allocator);
    // Weak glare of gold print at one place in all frames but the last one. The
    // second darkest frame has it too.
    for (pages[0..4]) |page| {
        for (60..100) |y| {
            for (40..90) |x| page.pixel(x, y).* = .{ 0.45, 0.35, 0.2 };
        }
    }

    const layers = [_]Layer{ .{ .page = pages[0] }, .{ .page = pages[1] }, .{ .page = pages[2] }, .{ .page = pages[3] }, .{ .page = pages[4] } };
    const stats = try fuse(testing.allocator, &layers, test_options, null);
    try testing.expect(stats.glare > 0.03);
    try testing.expect(stats.unrepaired < 0.005);
    for (pages[0].pixel(65, 80)) |value| try testing.expectApproxEqAbs(@as(f32, 0.15), value, 0.02);
    // The paper next to the bar did not change.
    try testing.expectApproxEqAbs(@as(f32, 1.0), pages[0].pixel(65, 130)[1], 0.02);
}

test "a donor that lies some pixels off repairs the page at the right place" {
    const clean = try testTextPage(testing.allocator, 7, 0, 0);
    defer clean.deinit(testing.allocator);
    var pages: [4]RgbF32 = undefined;
    pages[0] = try testTextPage(testing.allocator, 7, 0, 0);
    // The registration left the donors 3 pixels to the right and 2 pixels up.
    for (pages[1..]) |*page| page.* = try testTextPage(testing.allocator, 7, 3, -2);
    defer for (pages) |page| page.deinit(testing.allocator);
    fillGlare(pages[0], 48, 104, 56, 96);

    const layers = [_]Layer{ .{ .page = pages[0] }, .{ .page = pages[1] }, .{ .page = pages[2] }, .{ .page = pages[3] } };
    const stats = try fuse(testing.allocator, &layers, test_options, null);
    try testing.expect(stats.glare > 0.02);
    try testing.expectEqual(@as(f32, 0), stats.rejected);
    // The words under the glare are back where they are on the page. A copy of the
    // donor with no shift leaves each word 3 pixels off: a mean difference near 0.2.
    try testing.expect(meanDifference(pages[0], clean, 56, 96, 60, 92) < 0.05);
}

test "among the donors that agree, a region takes the one that is sharp in the region" {
    const clean = try testTextPage(testing.allocator, 7, 0, 0);
    defer clean.deinit(testing.allocator);
    var pages: [3]RgbF32 = undefined;
    for (&pages) |*page| page.* = try testTextPage(testing.allocator, 7, 0, 0);
    defer for (pages) |page| page.deinit(testing.allocator);
    fillGlare(pages[0], 48, 104, 56, 96);
    // The first donor is blurred where the reference has the glare, and sharp
    // around it: the check around the region cannot tell the two donors apart.
    for (56..96) |y| {
        for (48..104) |x| {
            var sum: f32 = 0;
            for (x - 3..x + 4) |from_x| sum += clean.pixel(from_x, y)[1];
            pages[1].pixel(x, y).* = @splat(sum / 7);
        }
    }

    const layers = [_]Layer{ .{ .page = pages[0] }, .{ .page = pages[1] }, .{ .page = pages[2] } };
    const stats = try fuse(testing.allocator, &layers, test_options, null);
    try testing.expect(stats.glare > 0.02);
    try testing.expectEqual(@as(f32, 0), stats.rejected);
    // The sharp words are back. The blurred donor leaves a mean difference of
    // about 0.04 in this rectangle.
    try testing.expect(meanDifference(pages[0], clean, 56, 96, 60, 92) < 0.01);
}

test "a donor that shows other content around the fault repairs nothing" {
    var pages: [4]RgbF32 = undefined;
    pages[0] = try testTextPage(testing.allocator, 7, 0, 0);
    // The donors are another page: other words at all places.
    for (pages[1..]) |*page| page.* = try testTextPage(testing.allocator, 99, 0, 0);
    defer for (pages) |page| page.deinit(testing.allocator);
    fillGlare(pages[0], 48, 104, 56, 96);
    const before: RgbF32 = .{
        .data = try testing.allocator.dupe(f32, pages[0].data),
        .width = pages[0].width,
        .height = pages[0].height,
    };
    defer before.deinit(testing.allocator);

    const layers = [_]Layer{ .{ .page = pages[0] }, .{ .page = pages[1] }, .{ .page = pages[2] }, .{ .page = pages[3] } };
    const stats = try fuse(testing.allocator, &layers, test_options, null);
    try testing.expect(stats.rejected > 0.02);
    // The glare stays: the words of another page do not come into it.
    try testing.expectEqual(@as(f32, 0), meanDifference(pages[0], before, 56, 96, 60, 92));
}

test "a dark bar with a warm tint that the donors show too is not a finger" {
    var pages: [4]RgbF32 = undefined;
    for (&pages) |*page| page.* = try testPage(testing.allocator);
    defer for (pages) |page| page.deinit(testing.allocator);
    // A header bar that runs to the border of the page. In the reference it has the
    // colour of skin; the donors show it as dark, with no tint.
    for (pages, 0..) |page, index| {
        for (150..180) |y| {
            for (60..160) |x| page.pixel(x, y).* = if (index == 0) .{ 0.5, 0.4, 0.3 } else @splat(0.4);
        }
    }
    const before = try testing.allocator.dupe(f32, pages[0].data);
    defer testing.allocator.free(before);

    const layers = [_]Layer{ .{ .page = pages[0] }, .{ .page = pages[1] }, .{ .page = pages[2] }, .{ .page = pages[3] } };
    const stats = try fuse(testing.allocator, &layers, test_options, null);
    try testing.expectEqual(@as(f32, 0), stats.cover);
    try testing.expectEqualSlices(f32, before, pages[0].data);
}

// endregion: tests
