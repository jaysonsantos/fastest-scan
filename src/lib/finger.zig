//! Fingers on a page: find them in one frame, and paint over those that stay after
//! the fusion.
//!
//! The input is a flattened page (`enhance.flatten`): blank paper is at 1.0.
//!
//! - A cell has the colour of skin when red is above green by a fixed amount and
//!   blue is not above red. Gold print and paper in warm light are more yellow
//!   than skin, a header bar is darker, and text has texture.
//! - A finger is a wide blob of such cells that comes in from the border of the
//!   page or from the border of the frame. A printed picture with the colour of
//!   skin does not touch the border. The wood of a desk that shows at a round
//!   corner of the page looks the same as a finger and gets the same treatment.
//! - The paper next to a finger has a shadow, and the colour of the skin shines on
//!   it. This halo belongs to the finger: a frame gives no data about the page
//!   there.
//! - A finger that is at one place in all frames stays after the fusion. The paint
//!   puts the colour of the paper around it on the finger and on its halo. Ink
//!   that shows next to the finger stays. The paint cannot know what is below the
//!   finger: see `docs/decisions/0014-paint-over-fingers.md`.
//!
//! Source of the idea:
//! - J. Kovač, P. Peer, and F. Solina, "Human skin colour clustering for face
//!   detection", EUROCON 2003: a pixel is skin when red is above green and above
//!   blue by fixed margins. The margins here are other values: they are for a page
//!   with white paper at 1.0, and they were measured on the benchmark video.

const std = @import("std");
const Allocator = std.mem.Allocator;
const image = @import("image.zig");
const color = @import("color.zig");

const RgbF32 = image.RgbF32;
const Plane = image.Plane;
const channels = image.rgb_channels;

// region: options and results

/// Which fingers the paint covers.
pub const Paint = enum {
    /// No finger: each finger that is in all frames stays.
    none,
    /// A finger with blank paper around it. A finger with ink next to it can hide
    /// ink, so it stays.
    blank_paper,
    /// Each finger. Ink that shows next to a finger stays.
    all,
};

pub const Options = struct {
    /// Skin has this much more red than green, on the scale where paper is 1.0.
    /// Black ink is neutral.
    min_red_over_green: f32 = 0.08,
    /// Skin has blue at most this much above red. A finger in a shadow looks lilac
    /// after the flatten step; print that is blue or violet has more blue.
    max_blue_over_red: f32 = 0.05,
    /// Skin is more red than yellow: green minus blue is at most red minus green
    /// plus this value. Gold print and paper in warm light are more yellow.
    max_yellow_excess: f32 = 0.05,
    /// A cell with a mean luma below this is too dark for skin: it is print.
    min_luma: f32 = 0.25,
    /// A cell with a mean luma above this is paper.
    max_luma: f32 = 0.92,
    /// Skin has no texture: the luma in a cell changes by this much at most.
    max_cell_contrast: f32 = 0.35,
    /// A finger is a wide blob: somewhere it has skin in all cells within this
    /// distance, in cells. A thin strip of the desk at the edge of the page does not.
    core_cells: u8 = 2,
    /// The mask of a finger covers this many cells more: a finger has a soft edge.
    margin_cells: u8 = 3,

    /// The halo of a finger: the mask grows from the margin over paper with a
    /// shadow or a tint, up to this many cells.
    halo_cells: u8 = 10,
    /// A cell of the halo has no texture: its luma changes by this much at most.
    max_halo_contrast: f32 = 0.15,
    /// A cell of the halo has a tint: red is this much above blue.
    min_halo_tint: f32 = 0.04,
    /// Or a cell of the halo has a shadow: its mean luma is at most this.
    max_halo_luma: f32 = 0.93,
    /// A cell of the halo is not darker than this. A darker cell is print.
    min_halo_luma: f32 = 0.6,
    /// A group of cells that the mask closes in, with this many cells at most,
    /// belongs to the mask too: the dark gap between two fingers, for example.
    max_hole_cells: u16 = 48,

    /// Which fingers get the colour of the paper when they stay after the fusion.
    paint: Paint = .all,
    /// A dark cell this near to the finger, in cells, is the edge or the shadow of
    /// the finger. It is not ink of the page.
    edge_cells: u8 = 1,
    /// The paint looks at this many cells around a finger with its halo: for ink,
    /// and for the colour of the paper.
    ring_cells: u8 = 3,
    /// A cell has ink when its ink value is below this.
    ring_ink_value: f32 = 0.7,
    /// A cell in the margin of a finger has text when it has ink and its mean luma
    /// is this much above its ink value. A shadow has no such contrast.
    min_ink_contrast: f32 = 0.15,
    /// A cell in the margin of a finger with a mean luma below this is print. A
    /// shadow is not that dark.
    max_print_luma: f32 = 0.45,
    /// With `Paint.blank_paper`: a finger is painted when at most this many cells
    /// in it and around it have ink.
    max_ink_cells: u8 = 2,
    /// The paint takes the colour of the paper from the blank cells around a
    /// finger when there are at least this many. With fewer cells it takes the
    /// colour of flattened paper.
    min_blank_cells: u8 = 8,
    /// The cells this near to the border of the page do not count as ink: the
    /// edge of the page has a shadow, and the desk shows there.
    page_border_cells: u8 = 2,
    /// A finger with its halo that is larger than this fraction of the page is
    /// not painted: it can be a picture.
    max_region_fraction: f32 = 0.15,
    /// In a cell with ink, the paint covers a pixel with a luma above this in
    /// full: the pixel is paper.
    paper_pixel_luma: f32 = 0.9,
    /// In a cell with ink, the paint does not touch a pixel with a luma below
    /// this: the pixel is ink.
    ink_pixel_luma: f32 = 0.75,
};

/// The grid of comparison cells of a page.
pub const Grid = struct {
    width: usize,
    height: usize,
    /// The side of a cell in page pixels.
    cell: usize,

    pub fn init(page: RgbF32, cell: usize) Grid {
        return .{
            .width = (page.width + cell - 1) / cell,
            .height = (page.height + cell - 1) / cell,
            .cell = cell,
        };
    }

    pub fn count(self: Grid) usize {
        return self.width * self.height;
    }
};

/// What one frame shows of fingers. One value per cell, row after row.
pub const Mask = struct {
    /// The cells with the colour of skin and without texture.
    skin: []bool,
    /// The cells of the fingers: the wide blobs of skin that come in from a border.
    finger: []bool,
    /// The cells of the fingers with their margin and their halo. The frame gives
    /// no data about the page there.
    covered: []bool,

    pub fn deinit(self: Mask, allocator: Allocator) void {
        allocator.free(self.skin);
        allocator.free(self.finger);
        allocator.free(self.covered);
    }
};

/// What the paint did in a cell.
pub const Outcome = enum(u8) {
    none,
    /// The cell has the colour of the paper now.
    painted,
    /// The cell shows a finger that the paint did not touch.
    left,
};

// endregion: options and results

// region: cell masks

/// A cell needs this fraction of its pixels inside the frame to have a colour.
const min_inside_fraction = 0.75;

fn isSet(mask: ?Plane, x: usize, y: usize) bool {
    const plane = mask orelse return false;
    return plane.at(x, y) != 0;
}

/// The colour of each cell of a page: the input of `find`. One value per cell, row
/// after row.
pub const CellColors = struct {
    /// The mean colour of the cell.
    mean: [][channels]f32,
    /// The largest minus the smallest luma of the cell. NaN for a cell without
    /// enough pixels inside the frame.
    contrast: []f32,

    pub fn init(allocator: Allocator, grid: Grid) Allocator.Error!CellColors {
        const mean = try allocator.alloc([channels]f32, grid.count());
        errdefer allocator.free(mean);
        return .{ .mean = mean, .contrast = try allocator.alloc(f32, grid.count()) };
    }

    pub fn deinit(self: CellColors, allocator: Allocator) void {
        allocator.free(self.mean);
        allocator.free(self.contrast);
    }
};

/// Measure the colour of each cell of a flattened page. `outside` has a value that
/// is not zero for each pixel outside the frame.
pub fn measure(allocator: Allocator, page: RgbF32, outside: ?Plane, grid: Grid) Allocator.Error!CellColors {
    const colors = try CellColors.init(allocator, grid);
    for (0..grid.height) |cell_y| {
        for (0..grid.width) |cell_x| {
            const x_start = cell_x * grid.cell;
            const y_start = cell_y * grid.cell;
            const x_end = @min(x_start + grid.cell, page.width);
            const y_end = @min(y_start + grid.cell, page.height);
            var sum: [channels]f32 = @splat(0);
            var darkest = std.math.inf(f32);
            var brightest = -std.math.inf(f32);
            var inside: f32 = 0;
            for (y_start..y_end) |y| {
                for (x_start..x_end) |x| {
                    if (isSet(outside, x, y)) continue;
                    const pixel = page.pixel(x, y);
                    for (&sum, pixel) |*total, value| total.* += value;
                    const luma = color.rgbLuma(pixel.*);
                    darkest = @min(darkest, luma);
                    brightest = @max(brightest, luma);
                    inside += 1;
                }
            }
            const total: f32 = @floatFromInt((x_end - x_start) * (y_end - y_start));
            const index = cell_y * grid.width + cell_x;
            if (inside < min_inside_fraction * total or inside == 0) {
                colors.mean[index] = @splat(0);
                colors.contrast[index] = std.math.nan(f32);
                continue;
            }
            colors.mean[index] = .{ sum[0] / inside, sum[1] / inside, sum[2] / inside };
            colors.contrast[index] = brightest - darkest;
        }
    }
    return colors;
}

/// True for the mean colour of a cell that shows skin. `contrast` is the largest
/// minus the smallest luma of the cell; with NaN the result is false.
fn isSkin(mean: [channels]f32, contrast: f32, options: Options) bool {
    const red_over_green = mean[0] - mean[1];
    const green_over_blue = mean[1] - mean[2];
    const luma = color.rgbLuma(mean);
    return red_over_green >= options.min_red_over_green and
        mean[2] - mean[0] <= options.max_blue_over_red and
        green_over_blue <= red_over_green + options.max_yellow_excess and
        luma >= options.min_luma and
        luma <= options.max_luma and
        contrast <= options.max_cell_contrast;
}

/// True for the mean colour of a cell that shows blank paper with a shadow or
/// with a tint on it.
fn isHalo(mean: [channels]f32, contrast: f32, options: Options) bool {
    const luma = color.rgbLuma(mean);
    const tinted = mean[0] - mean[2] >= options.min_halo_tint;
    const shaded = luma <= options.max_halo_luma;
    return contrast <= options.max_halo_contrast and luma >= options.min_halo_luma and (tinted or shaded);
}

/// True when the cell or one of the 8 cells around it is set. `beyond` is the value
/// of a cell beyond the grid.
fn anyNeighbour(mask: []const bool, grid: Grid, x: usize, y: usize, beyond: bool) bool {
    if (beyond and (x == 0 or y == 0 or x + 1 == grid.width or y + 1 == grid.height)) return true;
    const y_from = y -| 1;
    const y_to = @min(y + 1, grid.height - 1);
    const x_from = x -| 1;
    const x_to = @min(x + 1, grid.width - 1);
    for (y_from..y_to + 1) |ny| {
        for (x_from..x_to + 1) |nx| {
            if (mask[ny * grid.width + nx]) return true;
        }
    }
    return false;
}

/// Grow a mask by one cell in the 8 directions, `rounds` times. `scratch` has the
/// size of the mask. With `allowed`, the mask grows into the allowed cells only.
fn dilate(mask: []bool, scratch: []bool, grid: Grid, rounds: usize, allowed: ?[]const bool) void {
    for (0..rounds) |_| {
        @memcpy(scratch, mask);
        for (0..grid.height) |y| {
            for (0..grid.width) |x| {
                const index = y * grid.width + x;
                if (scratch[index]) continue;
                if (allowed) |cells| {
                    if (!cells[index]) continue;
                }
                mask[index] = anyNeighbour(scratch, grid, x, y, false);
            }
        }
    }
}

/// Shrink a mask by one cell in the 8 directions, `rounds` times. A cell beyond
/// the grid counts as set: the border of the grid does not shrink the mask.
fn erode(mask: []bool, scratch: []bool, grid: Grid, rounds: usize) void {
    for (0..rounds) |_| {
        // `scratch` holds the cells that are clear before this round. A cell stays
        // when no cell around it is clear.
        for (scratch, mask) |*clear, set| clear.* = !set;
        for (0..grid.height) |y| {
            for (0..grid.width) |x| {
                const index = y * grid.width + x;
                if (mask[index]) mask[index] = !anyNeighbour(scratch, grid, x, y, false);
            }
        }
    }
}

/// Keep the cells of `mask` that connect, through cells of `mask`, to the border of
/// the grid or to a cell without data.
fn keepBorderConnected(allocator: Allocator, mask: []bool, no_data: []const bool, grid: Grid) Allocator.Error!void {
    const marked = try allocator.alloc(bool, mask.len);
    defer allocator.free(marked);
    @memset(marked, false);
    const stack = try allocator.alloc(u32, mask.len);
    defer allocator.free(stack);
    var stack_len: usize = 0;

    for (0..grid.height) |y| {
        for (0..grid.width) |x| {
            const index = y * grid.width + x;
            if (!mask[index]) continue;
            if (!anyNeighbour(no_data, grid, x, y, true)) continue;
            marked[index] = true;
            stack[stack_len] = @intCast(index);
            stack_len += 1;
        }
    }
    while (stack_len > 0) {
        stack_len -= 1;
        const index = stack[stack_len];
        const x = index % grid.width;
        const y = index / grid.width;
        const neighbours = [_]?usize{
            if (x > 0) index - 1 else null,
            if (x + 1 < grid.width) index + 1 else null,
            if (y > 0) index - grid.width else null,
            if (y + 1 < grid.height) index + grid.width else null,
        };
        for (neighbours) |maybe| {
            const neighbour = maybe orelse continue;
            if (marked[neighbour] or !mask[neighbour]) continue;
            marked[neighbour] = true;
            stack[stack_len] = @intCast(neighbour);
            stack_len += 1;
        }
    }
    @memcpy(mask, marked);
}

/// Find the fingers on a flattened page from the colours of its cells. `no_data` is
/// true for each cell where the frame does not show the page; a finger can come in
/// from there too.
pub fn find(
    allocator: Allocator,
    colors: CellColors,
    no_data: []const bool,
    grid: Grid,
    options: Options,
) Allocator.Error!Mask {
    const count = grid.count();
    const skin = try allocator.alloc(bool, count);
    errdefer allocator.free(skin);
    const finger = try allocator.alloc(bool, count);
    errdefer allocator.free(finger);
    const covered = try allocator.alloc(bool, count);
    errdefer allocator.free(covered);
    const halo = try allocator.alloc(bool, count);
    defer allocator.free(halo);
    const scratch = try allocator.alloc(bool, count);
    defer allocator.free(scratch);

    for (skin, halo, colors.mean, colors.contrast, no_data) |*is_skin, *is_halo, mean, contrast, missing| {
        is_skin.* = !missing and isSkin(mean, contrast, options);
        is_halo.* = !missing and isHalo(mean, contrast, options);
    }

    // The wide parts. A cell without data counts as skin here, so a finger keeps
    // its width where the frame cuts it.
    for (finger, skin, no_data) |*value, is_skin, missing| value.* = is_skin or missing;
    erode(finger, scratch, grid, options.core_cells);
    for (finger, no_data) |*value, missing| value.* = value.* and !missing;
    // One cell more than the way back: the blob gets its round ends again, and the
    // skin mask limits it.
    dilate(finger, scratch, grid, @as(usize, options.core_cells) + 1, skin);
    try keepBorderConnected(allocator, finger, no_data, grid);

    @memcpy(covered, finger);
    dilate(covered, scratch, grid, options.margin_cells, null);
    dilate(covered, scratch, grid, options.halo_cells, halo);
    try fillHoles(allocator, covered, grid, options.max_hole_cells);
    return .{ .skin = skin, .finger = finger, .covered = covered };
}

/// Set each group of clear cells that has `max_cells` cells at most. The cells of
/// a group connect in the 4 directions.
fn fillHoles(allocator: Allocator, mask: []bool, grid: Grid, max_cells: usize) Allocator.Error!void {
    var any = false;
    for (mask) |set| any = any or set;
    if (!any) return;
    const seen = try allocator.alloc(bool, mask.len);
    defer allocator.free(seen);
    @memcpy(seen, mask);
    const group = try allocator.alloc(u32, mask.len);
    defer allocator.free(group);
    for (0..mask.len) |start| {
        if (seen[start]) continue;
        // `group` is the list of the cells of this group, and the queue of the search.
        var len: usize = 1;
        var next: usize = 0;
        group[0] = @intCast(start);
        seen[start] = true;
        while (next < len) : (next += 1) {
            const index = group[next];
            const x = index % grid.width;
            const y = index / grid.width;
            const neighbours = [_]?usize{
                if (x > 0) index - 1 else null,
                if (x + 1 < grid.width) index + 1 else null,
                if (y > 0) index - grid.width else null,
                if (y + 1 < grid.height) index + grid.width else null,
            };
            for (neighbours) |maybe| {
                const neighbour = maybe orelse continue;
                if (seen[neighbour]) continue;
                seen[neighbour] = true;
                group[len] = @intCast(neighbour);
                len += 1;
            }
        }
        if (len > max_cells) continue;
        for (group[0..len]) |index| mask[index] = true;
    }
}

// endregion: cell masks

// region: paint

/// The number of darkest pixels of a cell that give its ink value.
const ink_pixels = 4;
/// A cell farther from a finger than the paint looks has this distance.
const far = std.math.maxInt(u8);
const no_region = 0;
/// The strength of the paint in a cell that the paint covers.
const full_strength = 1.0;
/// The colour of blank paper on a flattened page.
const flat_paper: [channels]f32 = @splat(1.0);
/// Two cells with luma values this near to each other are equally bright.
const luma_tolerance = 1e-4;

/// What a cell of the page shows.
const CellLook = struct {
    /// The mean of the darkest pixels of the cell.
    ink: f32,
    mean: [channels]f32,
};

/// Measure one cell of the page. Null for a cell without enough pixels inside
/// the frame.
fn cellLook(page: RgbF32, outside: ?Plane, grid: Grid, cell_x: usize, cell_y: usize) ?CellLook {
    const x_start = cell_x * grid.cell;
    const y_start = cell_y * grid.cell;
    const x_end = @min(x_start + grid.cell, page.width);
    const y_end = @min(y_start + grid.cell, page.height);
    var sum: [channels]f32 = @splat(0);
    var inside: f32 = 0;
    // The darkest values so far, in rising order.
    var darkest: [ink_pixels]f32 = @splat(std.math.inf(f32));
    for (y_start..y_end) |y| {
        for (x_start..x_end) |x| {
            if (isSet(outside, x, y)) continue;
            const pixel = page.pixel(x, y);
            for (&sum, pixel) |*total, value| total.* += value;
            inside += 1;
            const luma = color.rgbLuma(pixel.*);
            if (luma < darkest[ink_pixels - 1]) {
                var slot: usize = ink_pixels - 1;
                while (slot > 0 and darkest[slot - 1] > luma) : (slot -= 1) darkest[slot] = darkest[slot - 1];
                darkest[slot] = luma;
            }
        }
    }
    const total: f32 = @floatFromInt((x_end - x_start) * (y_end - y_start));
    if (inside < min_inside_fraction * total or inside < ink_pixels) return null;
    var ink_sum: f32 = 0;
    for (darkest) |value| ink_sum += value;
    return .{
        .ink = ink_sum / ink_pixels,
        .mean = .{ sum[0] / inside, sum[1] / inside, sum[2] / inside },
    };
}

/// The numbers of one finger with its halo, or of some fingers that touch.
const Region = struct {
    /// The cells of the fingers with their margin and their halo.
    cells: usize = 0,
    /// The cells in the region and around it that have ink of the page.
    ink_cells: usize = 0,
    /// The cells around the region that are blank paper.
    blank_cells: usize = 0,
    blank_luma_sum: f32 = 0,
    /// The blank cells that are as bright as the mean blank cell or brighter, and
    /// the sum of their colours. A cell with a rest of the shadow is darker.
    bright_cells: usize = 0,
    bright_sum: [channels]f32 = @splat(0),
    /// The colour of the paper around the fingers.
    paper: [channels]f32 = @splat(1),
    painted: bool = false,
};

/// Paint over the fingers that stay on `page`, in place.
///
/// - `left`: the cells where the page still shows a finger, its margin, or its halo.
/// - `finger`: the cells of `left` that show the finger itself.
/// - `skin`: the cells where the page still shows the colour of skin.
/// - `outcome`: gets what the paint did in each cell.
pub fn paint(
    allocator: Allocator,
    page: RgbF32,
    outside: ?Plane,
    left: []const bool,
    finger: []const bool,
    skin: []const bool,
    grid: Grid,
    options: Options,
    outcome: []Outcome,
) Allocator.Error!void {
    if (options.paint == .none) {
        for (outcome, finger) |*result, is_finger| result.* = if (is_finger) .left else .none;
        return;
    }
    @memset(outcome, .none);
    const count = grid.count();
    const reach: u8 = options.ring_cells;

    // The distance of each cell to the nearest cell of `left`, in cells.
    const distance = try allocator.alloc(u8, count);
    defer allocator.free(distance);
    var left_cells: usize = 0;
    for (distance, left) |*value, is_left| {
        value.* = if (is_left) 0 else far;
        if (is_left) left_cells += 1;
    }
    if (left_cells == 0) return;
    for (1..@as(usize, reach) + 1) |round| {
        for (0..grid.height) |y| {
            for (0..grid.width) |x| {
                const index = y * grid.width + x;
                if (distance[index] != far) continue;
                if (hasNeighbourAt(distance, grid, x, y, @intCast(round - 1))) distance[index] = @intCast(round);
            }
        }
    }

    // Each connected group of cells is one region with one decision.
    const labels = try allocator.alloc(u16, count);
    defer allocator.free(labels);
    @memset(labels, no_region);
    var regions: std.ArrayList(Region) = .empty;
    defer regions.deinit(allocator);
    try regions.append(allocator, .{});
    const stack = try allocator.alloc(u32, count);
    defer allocator.free(stack);
    for (0..count) |start| {
        if (distance[start] != 0 or labels[start] != no_region) continue;
        if (regions.items.len > std.math.maxInt(u16)) break;
        const label: u16 = @intCast(regions.items.len);
        var region: Region = .{};
        var stack_len: usize = 1;
        stack[0] = @intCast(start);
        labels[start] = label;
        while (stack_len > 0) {
            stack_len -= 1;
            const index = stack[stack_len];
            region.cells += 1;
            const x = index % grid.width;
            const y = index / grid.width;
            const y_from = y -| 1;
            const y_to = @min(y + 1, grid.height - 1);
            const x_from = x -| 1;
            const x_to = @min(x + 1, grid.width - 1);
            for (y_from..y_to + 1) |ny| {
                for (x_from..x_to + 1) |nx| {
                    const neighbour = ny * grid.width + nx;
                    if (distance[neighbour] != 0 or labels[neighbour] != no_region) continue;
                    labels[neighbour] = label;
                    stack[stack_len] = @intCast(neighbour);
                    stack_len += 1;
                }
            }
        }
        try regions.append(allocator, region);
    }
    // The cells around each region get its label too.
    for (1..@as(usize, reach) + 1) |round| {
        for (0..grid.height) |y| {
            for (0..grid.width) |x| {
                const index = y * grid.width + x;
                if (distance[index] != round) continue;
                labels[index] = neighbourLabel(labels, distance, grid, x, y, @intCast(round - 1));
            }
        }
    }

    const scratch = try allocator.alloc(bool, count);
    defer allocator.free(scratch);
    // A dark cell next to the finger is its edge or its shadow.
    const near_finger = try allocator.dupe(bool, finger);
    defer allocator.free(near_finger);
    dilate(near_finger, scratch, grid, options.edge_cells, null);
    // A dark line next to skin is the shadow of a finger, or the edge of the desk.
    const near_skin = try allocator.dupe(bool, skin);
    defer allocator.free(near_skin);
    dilate(near_skin, scratch, grid, 1, null);

    // Look at the cells of each region and around it: ink, or blank paper.
    const looks = try allocator.alloc(?CellLook, count);
    defer allocator.free(looks);
    @memset(looks, null);
    // The cells of a region with ink of the page in them.
    const with_ink = try allocator.alloc(bool, count);
    defer allocator.free(with_ink);
    @memset(with_ink, false);
    const border: usize = options.page_border_cells;
    for (0..grid.height) |y| {
        for (0..grid.width) |x| {
            const index = y * grid.width + x;
            const label = labels[index];
            if (label == no_region) continue;
            if (x < border or y < border or x + border >= grid.width or y + border >= grid.height) continue;
            const look = cellLook(page, outside, grid, x, y) orelse continue;
            const region = &regions.items[label];
            const luma = color.rgbLuma(look.mean);
            const has_ink = look.ink < options.ring_ink_value;
            if (distance[index] == 0) {
                if (near_finger[index] or skin[index]) continue;
                const text = has_ink and luma - look.ink >= options.min_ink_contrast;
                const print = luma < options.max_print_luma;
                if (text or print) {
                    with_ink[index] = true;
                    region.ink_cells += 1;
                }
            } else if (has_ink) {
                if (!near_skin[index]) region.ink_cells += 1;
            } else {
                looks[index] = look;
                region.blank_cells += 1;
                region.blank_luma_sum += luma;
            }
        }
    }
    for (looks, labels) |maybe, label| {
        const look = maybe orelse continue;
        const region = &regions.items[label];
        const mean_luma = region.blank_luma_sum / @as(f32, @floatFromInt(region.blank_cells));
        if (color.rgbLuma(look.mean) < mean_luma - luma_tolerance) continue;
        region.bright_cells += 1;
        for (&region.bright_sum, look.mean) |*total, value| total.* += value;
    }
    const max_cells = options.max_region_fraction * @as(f32, @floatFromInt(count));
    for (regions.items[1..]) |*region| {
        region.paper = flat_paper;
        if (region.blank_cells >= options.min_blank_cells and region.bright_cells > 0) {
            const bright: f32 = @floatFromInt(region.bright_cells);
            for (&region.paper, region.bright_sum) |*value, total| value.* = total / bright;
        }
        const small = @as(f32, @floatFromInt(region.cells)) <= max_cells;
        const blank = region.ink_cells <= options.max_ink_cells;
        region.painted = small and (blank or options.paint == .all);
    }

    // The strength of the paint in each cell, with a soft edge.
    const strength = try allocator.alloc(f32, count);
    defer allocator.free(strength);
    var painted_cells: usize = 0;
    for (strength, outcome, labels, left, finger, with_ink) |*value, *result, label, is_left, is_finger, has_ink| {
        value.* = 0;
        if (!is_left) continue;
        if (!regions.items[label].painted) {
            if (is_finger) result.* = .left;
            continue;
        }
        value.* = full_strength;
        if (has_ink) continue;
        result.* = .painted;
        painted_cells += 1;
    }
    if (painted_cells == 0) return;
    const sharp = try allocator.dupe(f32, strength);
    defer allocator.free(sharp);
    for (0..grid.height) |y| {
        for (0..grid.width) |x| {
            var sum: f32 = 0;
            var cells: f32 = 0;
            const y_from = y -| 1;
            const y_to = @min(y + 1, grid.height - 1);
            const x_from = x -| 1;
            const x_to = @min(x + 1, grid.width - 1);
            for (y_from..y_to + 1) |ny| {
                for (x_from..x_to + 1) |nx| {
                    sum += sharp[ny * grid.width + nx];
                    cells += 1;
                }
            }
            strength[y * grid.width + x] = sum / cells;
        }
    }

    // Mix the pixels. In a cell that the paint covers, each pixel gets the paper.
    // In a cell with ink, and in a cell at the soft edge, only the pixels that are
    // as bright as paper get it: the ink stays as it is.
    const cell_float: f32 = @floatFromInt(grid.cell);
    const luma_span = @max(options.paper_pixel_luma - options.ink_pixel_luma, luma_tolerance);
    for (0..page.height) |y| {
        const cell_y = @min(y / grid.cell, grid.height - 1);
        const gy = std.math.clamp((@as(f32, @floatFromInt(y)) + 0.5) / cell_float - 0.5, 0, @as(f32, @floatFromInt(grid.height - 1)));
        const y0: usize = @intFromFloat(gy);
        const y1 = @min(y0 + 1, grid.height - 1);
        const fy = gy - @as(f32, @floatFromInt(y0));
        for (0..page.width) |x| {
            const cell_x = @min(x / grid.cell, grid.width - 1);
            const cell_index = cell_y * grid.width + cell_x;
            const label = labels[cell_index];
            if (label == no_region or !regions.items[label].painted) continue;
            if (isSet(outside, x, y)) continue;
            const gx = std.math.clamp((@as(f32, @floatFromInt(x)) + 0.5) / cell_float - 0.5, 0, @as(f32, @floatFromInt(grid.width - 1)));
            const x0: usize = @intFromFloat(gx);
            const x1 = @min(x0 + 1, grid.width - 1);
            const fx = gx - @as(f32, @floatFromInt(x0));
            const top = strength[y0 * grid.width + x0] * (1 - fx) + strength[y0 * grid.width + x1] * fx;
            const bottom = strength[y1 * grid.width + x0] * (1 - fx) + strength[y1 * grid.width + x1] * fx;
            var mix = top * (1 - fy) + bottom * fy;
            if (mix <= 0) continue;
            const target = page.pixel(x, y);
            if (outcome[cell_index] != .painted) {
                const luma = color.rgbLuma(target.*);
                mix *= std.math.clamp((luma - options.ink_pixel_luma) / luma_span, 0, 1);
            }
            for (target, regions.items[label].paper) |*value, paper| value.* += mix * (paper - value.*);
        }
    }
}

fn hasNeighbourAt(distance: []const u8, grid: Grid, x: usize, y: usize, wanted: u8) bool {
    const y_from = y -| 1;
    const y_to = @min(y + 1, grid.height - 1);
    const x_from = x -| 1;
    const x_to = @min(x + 1, grid.width - 1);
    for (y_from..y_to + 1) |ny| {
        for (x_from..x_to + 1) |nx| {
            if (distance[ny * grid.width + nx] == wanted) return true;
        }
    }
    return false;
}

/// The label of a cell next to this one that lies at the distance `wanted`.
fn neighbourLabel(labels: []const u16, distance: []const u8, grid: Grid, x: usize, y: usize, wanted: u8) u16 {
    const y_from = y -| 1;
    const y_to = @min(y + 1, grid.height - 1);
    const x_from = x -| 1;
    const x_to = @min(x + 1, grid.width - 1);
    for (y_from..y_to + 1) |ny| {
        for (x_from..x_to + 1) |nx| {
            const index = ny * grid.width + nx;
            if (distance[index] == wanted and labels[index] != no_region) return labels[index];
        }
    }
    return no_region;
}

// endregion: paint

// region: tests

const testing = std.testing;

const test_cell = 8;
const test_skin = [channels]f32{ 0.7, 0.45, 0.4 };

fn testPage(allocator: Allocator) !RgbF32 {
    const page = try RgbF32.init(allocator, 320, 400);
    for (page.data) |*value| value.* = 1.0;
    return page;
}

fn fill(page: RgbF32, x_from: usize, x_to: usize, y_from: usize, y_to: usize, value: [channels]f32) void {
    for (y_from..y_to) |y| {
        for (x_from..x_to) |x| page.pixel(x, y).* = value;
    }
}

/// Lines of text: dark rows with gaps, as wide as the page.
fn fillText(page: RgbF32, x_from: usize, x_to: usize, y_from: usize, y_to: usize) void {
    for (y_from..y_to) |y| {
        if (y % 12 >= 5) continue;
        for (x_from..x_to) |x| {
            if (x % 7 < 4) page.pixel(x, y).* = @splat(0.1);
        }
    }
}

fn testFind(page: RgbF32, outside: ?Plane) !Mask {
    const grid = Grid.init(page, test_cell);
    const no_data = try testing.allocator.alloc(bool, grid.count());
    defer testing.allocator.free(no_data);
    for (no_data, 0..) |*missing, index| {
        const x = (index % grid.width) * test_cell;
        const y = (index / grid.width) * test_cell;
        missing.* = isSet(outside, x, y);
    }
    const colors = try measure(testing.allocator, page, outside, grid);
    defer colors.deinit(testing.allocator);
    return find(testing.allocator, colors, no_data, grid, .{});
}

fn cellAt(page: RgbF32, x: usize, y: usize) usize {
    const grid = Grid.init(page, test_cell);
    return (y / test_cell) * grid.width + x / test_cell;
}

test "skin that comes in from the border is a finger, a picture in the page is not" {
    const page = try testPage(testing.allocator);
    defer page.deinit(testing.allocator);
    // A finger from the bottom edge, and a picture with the same colour in the page.
    fill(page, 104, 176, 320, 400, test_skin);
    fill(page, 100, 220, 100, 200, test_skin);

    const mask = try testFind(page, null);
    defer mask.deinit(testing.allocator);
    try testing.expect(mask.finger[cellAt(page, 140, 360)]);
    try testing.expect(mask.skin[cellAt(page, 160, 150)]);
    try testing.expect(!mask.finger[cellAt(page, 160, 150)]);
    try testing.expect(!mask.covered[cellAt(page, 160, 150)]);
    // The margin lies around the finger.
    try testing.expect(mask.covered[cellAt(page, 140, 304)]);
    try testing.expect(!mask.finger[cellAt(page, 140, 304)]);
    try testing.expect(!mask.covered[cellAt(page, 140, 280)]);
}

test "gold print, warm paper, a dark bar, and text are not skin" {
    const page = try testPage(testing.allocator);
    defer page.deinit(testing.allocator);
    // Each thing comes in from the left edge, as a finger does.
    fill(page, 0, 120, 20, 80, .{ 0.6, 0.45, 0.18 });
    fill(page, 0, 120, 100, 160, .{ 0.98, 0.91, 0.77 });
    fill(page, 0, 120, 180, 240, .{ 0.21, 0.15, 0.10 });
    fill(page, 0, 120, 260, 320, test_skin);
    fillText(page, 0, 120, 260, 320);

    const mask = try testFind(page, null);
    defer mask.deinit(testing.allocator);
    for (mask.covered) |covered| try testing.expect(!covered);
}

test "a thin strip of the desk at the edge of the page is not a finger" {
    const page = try testPage(testing.allocator);
    defer page.deinit(testing.allocator);
    fill(page, 0, 320, 384, 400, test_skin);

    const mask = try testFind(page, null);
    defer mask.deinit(testing.allocator);
    try testing.expect(mask.skin[cellAt(page, 160, 392)]);
    for (mask.finger) |is_finger| try testing.expect(!is_finger);
}

test "a finger that comes in from the border of the frame is a finger" {
    const page = try testPage(testing.allocator);
    defer page.deinit(testing.allocator);
    const outside = try Plane.initFilled(testing.allocator, page.width, page.height, 0);
    defer outside.deinit(testing.allocator);
    // The frame ends at row 320. The finger touches that row, not the page border.
    for (320..400) |y| @memset(outside.row(y), 255);
    fill(page, 104, 176, 240, 320, test_skin);

    const mask = try testFind(page, outside);
    defer mask.deinit(testing.allocator);
    try testing.expect(mask.finger[cellAt(page, 140, 280)]);
    try testing.expect(!mask.finger[cellAt(page, 140, 200)]);
}

test "the paper with a tint next to a finger is its halo, clean paper is not" {
    const page = try testPage(testing.allocator);
    defer page.deinit(testing.allocator);
    fill(page, 104, 176, 320, 400, test_skin);
    // The skin shines on the paper at the left of the finger.
    fill(page, 40, 104, 320, 400, .{ 0.99, 0.95, 0.88 });

    const mask = try testFind(page, null);
    defer mask.deinit(testing.allocator);
    try testing.expect(mask.covered[cellAt(page, 48, 360)]);
    try testing.expect(!mask.finger[cellAt(page, 48, 360)]);
    // At the right the paper is clean: the mask ends with the margin.
    try testing.expect(mask.covered[cellAt(page, 196, 360)]);
    try testing.expect(!mask.covered[cellAt(page, 212, 360)]);
}

/// Find the fingers on a page and paint over them, as the fusion does when no
/// other frame shows the page.
fn testPaint(page: RgbF32, options: Options, outcome: []Outcome) !void {
    const grid = Grid.init(page, test_cell);
    const mask = try testFind(page, null);
    defer mask.deinit(testing.allocator);
    try paint(testing.allocator, page, null, mask.covered, mask.finger, mask.skin, grid, options, outcome);
}

test "a finger with blank paper around it gets the colour of the paper" {
    const page = try testPage(testing.allocator);
    defer page.deinit(testing.allocator);
    for (page.data) |*value| value.* = 0.96;
    fill(page, 104, 176, 320, 400, test_skin);
    // A halo at the left of the finger.
    fill(page, 64, 104, 320, 400, .{ 0.95, 0.9, 0.84 });
    // Text far from the finger does not matter.
    fillText(page, 20, 300, 100, 200);
    const outcome = try testing.allocator.alloc(Outcome, Grid.init(page, test_cell).count());
    defer testing.allocator.free(outcome);

    try testPaint(page, .{ .paint = .blank_paper }, outcome);
    try testing.expectEqual(Outcome.painted, outcome[cellAt(page, 140, 360)]);
    for ([_][2]usize{ .{ 140, 360 }, .{ 108, 324 }, .{ 172, 396 }, .{ 80, 360 } }) |point| {
        const pixel = page.pixel(point[0], point[1]);
        for (pixel) |value| try testing.expectApproxEqAbs(@as(f32, 0.96), value, 0.01);
    }
    // The text is as it was.
    try testing.expectApproxEqAbs(@as(f32, 0.1), page.pixel(21, 108)[1], 0.001);
}

/// A page with a finger from the bottom edge and a line of text that goes below it.
fn testFingerOnText(allocator: Allocator) !RgbF32 {
    const page = try testPage(allocator);
    fillText(page, 20, 300, 336, 348);
    fill(page, 104, 176, 320, 400, test_skin);
    return page;
}

test "with the rule for blank paper, a finger with text next to it stays" {
    const page = try testFingerOnText(testing.allocator);
    defer page.deinit(testing.allocator);
    const before = try testing.allocator.dupe(f32, page.data);
    defer testing.allocator.free(before);
    const outcome = try testing.allocator.alloc(Outcome, Grid.init(page, test_cell).count());
    defer testing.allocator.free(outcome);

    try testPaint(page, .{ .paint = .blank_paper }, outcome);
    try testing.expectEqual(Outcome.left, outcome[cellAt(page, 140, 360)]);
    try testing.expectEqualSlices(f32, before, page.data);
}

test "with the rule for all fingers, the finger goes and the text next to it stays" {
    const page = try testFingerOnText(testing.allocator);
    defer page.deinit(testing.allocator);
    const outcome = try testing.allocator.alloc(Outcome, Grid.init(page, test_cell).count());
    defer testing.allocator.free(outcome);

    try testPaint(page, .{ .paint = .all }, outcome);
    try testing.expectEqual(Outcome.painted, outcome[cellAt(page, 140, 360)]);
    try testing.expectApproxEqAbs(@as(f32, 1.0), page.pixel(140, 360)[0], 0.01);
    // The text at the two sides of the finger: in the margin of the finger, and
    // farther away.
    for ([_]usize{ 21, 70, 84, 196, 210, 280 }) |x| {
        try testing.expect(x % 7 < 4);
        try testing.expectApproxEqAbs(@as(f32, 0.1), page.pixel(x, 338)[1], 0.001);
    }
}

test "with the paint off, a finger stays" {
    const page = try testPage(testing.allocator);
    defer page.deinit(testing.allocator);
    fill(page, 104, 176, 320, 400, test_skin);
    const before = try testing.allocator.dupe(f32, page.data);
    defer testing.allocator.free(before);
    const outcome = try testing.allocator.alloc(Outcome, Grid.init(page, test_cell).count());
    defer testing.allocator.free(outcome);

    try testPaint(page, .{ .paint = .none }, outcome);
    try testing.expectEqual(Outcome.left, outcome[cellAt(page, 140, 360)]);
    try testing.expectEqualSlices(f32, before, page.data);
}

test "a blob that is larger than a finger stays" {
    const page = try testPage(testing.allocator);
    defer page.deinit(testing.allocator);
    fill(page, 40, 280, 200, 400, test_skin);
    const before = try testing.allocator.dupe(f32, page.data);
    defer testing.allocator.free(before);
    const outcome = try testing.allocator.alloc(Outcome, Grid.init(page, test_cell).count());
    defer testing.allocator.free(outcome);

    try testPaint(page, .{}, outcome);
    try testing.expectEqual(Outcome.left, outcome[cellAt(page, 160, 300)]);
    try testing.expectEqualSlices(f32, before, page.data);
}

test "the paint does not touch a cell that is not in its list" {
    const page = try testPage(testing.allocator);
    defer page.deinit(testing.allocator);
    fill(page, 104, 176, 320, 400, test_skin);
    const grid = Grid.init(page, test_cell);
    const mask = try testFind(page, null);
    defer mask.deinit(testing.allocator);
    // The left half of the finger has content of a donor frame: it is not in the list.
    const left = try testing.allocator.dupe(bool, mask.covered);
    defer testing.allocator.free(left);
    const finger = try testing.allocator.dupe(bool, mask.finger);
    defer testing.allocator.free(finger);
    for (0..grid.height) |y| {
        for (0..grid.width / 2 - 3) |x| {
            left[y * grid.width + x] = false;
            finger[y * grid.width + x] = false;
        }
    }
    const outcome = try testing.allocator.alloc(Outcome, grid.count());
    defer testing.allocator.free(outcome);

    try paint(testing.allocator, page, null, left, finger, mask.skin, grid, .{}, outcome);
    try testing.expectEqual(Outcome.none, outcome[cellAt(page, 110, 360)]);
    try testing.expectApproxEqAbs(test_skin[0], page.pixel(108, 360)[0], 0.001);
    try testing.expectEqual(Outcome.painted, outcome[cellAt(page, 170, 360)]);
    try testing.expectApproxEqAbs(@as(f32, 1.0), page.pixel(172, 360)[0], 0.01);
}

// endregion: tests
