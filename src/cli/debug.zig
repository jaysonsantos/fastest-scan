//! Pictures of intermediate results, for a person who tunes the pipeline.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fastscan = @import("fastscan");
const image = fastscan.image;
const geometry = fastscan.geometry;

pub const Color = [image.rgb_channels]u8;

pub const palette = struct {
    pub const left_page: Color = .{ 0, 230, 80 };
    pub const right_page: Color = .{ 40, 150, 255 };
    pub const covered: Color = .{ 255, 60, 60 };
    pub const not_detected: Color = .{ 255, 0, 255 };
    // The faults of a page. Green and blue: repaired. Red and the warm colours: not repaired.
    pub const glare_repaired: Color = .{ 0, 200, 60 };
    pub const glare_left: Color = .{ 255, 0, 0 };
    pub const cover_repaired: Color = .{ 30, 110, 255 };
    pub const cover_left: Color = .{ 255, 0, 255 };
    pub const outside_repaired: Color = .{ 0, 200, 220 };
    pub const outside_left: Color = .{ 120, 120, 120 };
    pub const rejected: Color = .{ 255, 150, 0 };
    pub const finger_painted: Color = .{ 150, 220, 0 };
    pub const finger_left: Color = .{ 150, 0, 200 };
    // Where the frames give data about a page.
    pub const reference_covered: Color = .{ 255, 0, 140 };
    pub const no_donor_data: Color = .{ 0, 90, 255 };
};

const jpeg_quality = 80;
const line_half_width = 1;

/// Convert a frame to RGB at its luma size. Each chroma sample colours 2x2 pixels.
pub fn frameToRgb(allocator: Allocator, frame: image.FrameView) Allocator.Error!image.Rgb8 {
    const rgb = try image.Rgb8.init(allocator, frame.width(), frame.height());
    const converter = fastscan.color.YuvToRgb.init(frame.colorimetry);
    for (0..frame.height()) |y| {
        const luma_row = frame.y.row(y);
        const chroma_y = @min(y / 2, frame.u.height - 1);
        const u_row = frame.u.row(chroma_y);
        const v_row = frame.v.row(chroma_y);
        const target = rgb.row(y);
        for (0..frame.width()) |x| {
            const chroma_x = @min(x / 2, frame.u.width - 1);
            const value = converter.convert(
                @floatFromInt(luma_row[x]),
                @floatFromInt(u_row[chroma_x]),
                @floatFromInt(v_row[chroma_x]),
            );
            for (0..image.rgb_channels) |channel| {
                target[x * image.rgb_channels + channel] = fastscan.color.toByte(value[channel]);
            }
        }
    }
    return rgb;
}

fn plot(rgb: image.Rgb8, x: i32, y: i32, color: Color) void {
    if (x < 0 or y < 0 or x >= rgb.width or y >= rgb.height) return;
    rgb.pixel(@intCast(x), @intCast(y)).* = color;
}

pub fn drawLine(rgb: image.Rgb8, from: geometry.Point, to: geometry.Point, color: Color) void {
    const length = from.distance(to);
    const steps: usize = @intFromFloat(@max(1, @ceil(length)));
    for (0..steps + 1) |step| {
        const p = from.lerp(to, @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps)));
        const center_x: i32 = @intFromFloat(@round(std.math.clamp(p.x, -1e6, 1e6)));
        const center_y: i32 = @intFromFloat(@round(std.math.clamp(p.y, -1e6, 1e6)));
        var dy: i32 = -line_half_width;
        while (dy <= line_half_width) : (dy += 1) {
            var dx: i32 = -line_half_width;
            while (dx <= line_half_width) : (dx += 1) plot(rgb, center_x + dx, center_y + dy, color);
        }
    }
}

pub fn drawQuad(rgb: image.Rgb8, quad: geometry.Quad, color: Color) void {
    const corners = quad.corners();
    for (0..corners.len) |index| drawLine(rgb, corners[index], corners[(index + 1) % corners.len], color);
}

/// Mark the covered cells of a page with a dot in the middle of each cell.
pub fn drawCoveredCells(rgb: image.Rgb8, page: *const fastscan.observe.PageObservation) void {
    const observe = fastscan.observe;
    const to_frame = geometry.Homography.fromQuads(
        geometry.Quad.rect(observe.grid_width, observe.grid_height),
        page.quad,
    ) orelse return;
    for (0..observe.grid_height) |cell_y| {
        for (0..observe.grid_width) |cell_x| {
            if (!page.covered.isSet(cell_y * observe.grid_width + cell_x)) continue;
            const p = to_frame.apply(geometry.Point.init(@as(f32, @floatFromInt(cell_x)) + 0.5, @as(f32, @floatFromInt(cell_y)) + 0.5));
            const x: i32 = @intFromFloat(@round(std.math.clamp(p.x, -1e6, 1e6)));
            const y: i32 = @intFromFloat(@round(std.math.clamp(p.y, -1e6, 1e6)));
            plot(rgb, x, y, palette.covered);
            plot(rgb, x + 1, y, palette.covered);
            plot(rgb, x, y + 1, palette.covered);
            plot(rgb, x + 1, y + 1, palette.covered);
        }
    }
}

/// The colour of each kind of cell in the picture of the faults of a page.
fn faultColor(cell: fastscan.fuse.FaultMap.Cell) ?Color {
    return switch (cell) {
        .clean => null,
        .glare_repaired => palette.glare_repaired,
        .glare_left => palette.glare_left,
        .cover_repaired => palette.cover_repaired,
        .cover_left => palette.cover_left,
        .outside_repaired => palette.outside_repaired,
        .outside_left => palette.outside_left,
        .rejected => palette.rejected,
        .finger_painted => palette.finger_painted,
        .finger_left => palette.finger_left,
    };
}

/// Tint each cell of a page where the fusion found a fault.
pub fn drawFaults(rgb: image.Rgb8, map: *const fastscan.fuse.FaultMap) void {
    const cell: usize = map.cell;
    for (0..rgb.height) |y| {
        const cell_y = @min(y / cell, map.grid_height - 1);
        for (0..rgb.width) |x| {
            const cell_x = @min(x / cell, map.grid_width - 1);
            const tint = faultColor(map.cells[cell_y * map.grid_width + cell_x]) orelse continue;
            mixTint(rgb.pixel(x, y), tint);
        }
    }
}

/// Tint each cell of a page where the reference frame shows a finger, and each cell
/// where no donor frame shows the page. Such a cell cannot get a repair.
pub fn drawCover(rgb: image.Rgb8, map: *const fastscan.fuse.FaultMap) void {
    const cell: usize = map.cell;
    for (0..rgb.height) |y| {
        const cell_y = @min(y / cell, map.grid_height - 1);
        for (0..rgb.width) |x| {
            const index = cell_y * map.grid_width + @min(x / cell, map.grid_width - 1);
            const pixel = rgb.pixel(x, y);
            if (map.reference_covered[index]) mixTint(pixel, palette.reference_covered);
            if (map.donors_with_data[index] == 0) mixTint(pixel, palette.no_donor_data);
        }
    }
}

fn mixTint(pixel: *Color, tint: Color) void {
    for (pixel, &tint) |*value, tint_value| {
        const mixed = (@as(u32, value.*) * (fault_tint_scale - fault_tint_weight) + @as(u32, tint_value) * fault_tint_weight) / fault_tint_scale;
        value.* = @intCast(mixed);
    }
}

/// The tint takes this part, of `fault_tint_scale`, of each pixel.
const fault_tint_weight = 45;
const fault_tint_scale = 100;

pub fn writeJpeg(io: Io, allocator: Allocator, dir: Io.Dir, name: []const u8, rgb: image.Rgb8) !void {
    const bytes = try fastscan.jpeg.encodeRgb(allocator, rgb, .{ .quality = jpeg_quality, .subsampling = .s420 });
    defer allocator.free(bytes);
    try dir.writeFile(io, .{ .sub_path = name, .data = bytes });
}
