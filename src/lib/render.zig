//! Render the pages of one spread from full-size frames: find the pages at the full
//! size, warp each page to the page size of the document, repair it with other
//! frames, and enhance it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");
const image = @import("image.zig");
const color = @import("color.zig");
const detect = @import("detect.zig");
const resample = @import("resample.zig");
const enhance = @import("enhance.zig");
const jpeg = @import("jpeg.zig");
const raster = @import("raster.zig");
const register = @import("register.zig");
const fuse = @import("fuse.zig");
const curl = @import("curl.zig");

const Quad = geometry.Quad;

// region: options and results

pub const Options = struct {
    detect: detect.Options = .{},
    enhance: enhance.Options = .{},
    jpeg: jpeg.Options = .{},
    register: register.Options = .{},
    fuse: fuse.Options = .{},
    /// A donor frame is used when the registration explains this fraction of the
    /// textured tiles of the page.
    min_donor_match: f32 = 0.35,
    /// A donor frame is used when its tiles lie within this distance of the fitted
    /// transform, as a root mean square in pixels.
    max_donor_residual: f32 = 1.0,
    /// Correct the curl of a page from the curve of its top edge. When off, each
    /// page is a plane through its four corners. The default is off: on the
    /// benchmark video the correction lowers the quality, see decision 0012.
    curl: bool = false,
    /// Find the pages of each donor frame again at the full size. When off, a donor
    /// frame takes the page corners of the analysis pass: they are only the start
    /// value of the registration, and the detector at the full size costs much
    /// time. The curl correction needs the page outlines, so it turns this on.
    redetect_donors: bool = false,
    /// Keep a map of what the fusion did in each cell of a page, for a debug picture.
    fault_maps: bool = false,
    /// Keep the page of each frame as it goes into the fusion, for debug pictures.
    layer_pictures: bool = false,
};

/// One frame of a spread with what the analysis pass knows about it.
pub const SourceFrame = struct {
    frame: image.FrameView,
    /// The page quads of the analysis pass, in luma pixels of this frame. The
    /// detector runs again at the full size; these are the fallback.
    quads: [detect.max_pages]Quad,
    clipped_edges: [detect.max_pages]detect.ClippedEdges,
};

pub const PageImage = struct {
    rgb: image.Rgb8,
    /// Which page of the spread this is: 0 for a single page or the left page.
    index: u8,
    /// The corners of the page in luma pixels of the reference frame.
    quad: Quad,
    /// The sides of the page that the reference frame did not show.
    clipped_edges: detect.ClippedEdges,
    /// The fraction of the page with no data in any frame. That part is white.
    outside_fraction: f32,
    /// True when the page was rendered with the curved page map.
    curled: bool,
    /// The number of donor frames that registered to the reference page.
    donors_used: u8,
    /// What the fusion found and repaired.
    fusion: fuse.Stats,
    /// What the fusion did in each cell, when `Options.fault_maps` is on.
    faults: ?fuse.FaultMap = null,
    /// The flattened page of each frame before the fusion, the reference frame
    /// first, when `Options.layer_pictures` is on. A pixel outside a frame is grey.
    layers: []image.Rgb8 = &.{},

    pub fn deinit(self: PageImage, allocator: Allocator) void {
        self.rgb.deinit(allocator);
        if (self.faults) |map| map.deinit(allocator);
        freeLayerPictures(allocator, self.layers);
    }
};

fn freeLayerPictures(allocator: Allocator, pictures: []image.Rgb8) void {
    for (pictures) |picture| picture.deinit(allocator);
    allocator.free(pictures);
}

/// The 8-bit pictures of the layers of a page, for a person who tunes the fusion.
fn layerPictures(allocator: Allocator, layers: []const fuse.Layer) Allocator.Error![]image.Rgb8 {
    const pictures = try allocator.alloc(image.Rgb8, layers.len);
    var built: usize = 0;
    errdefer {
        for (pictures[0..built]) |picture| picture.deinit(allocator);
        allocator.free(pictures);
    }
    for (layers, pictures) |layer, *picture| {
        picture.* = try enhance.toRgb8(allocator, layer.page);
        built += 1;
        const mask = layer.outside orelse continue;
        for (mask.data, 0..) |value, pixel_index| {
            if (value == 0) continue;
            picture.data[pixel_index * image.rgb_channels ..][0..image.rgb_channels].* = @splat(outside_gray);
        }
    }
    return pictures;
}

/// The colour of a pixel outside the frame in a layer picture, as an 8-bit code.
const outside_gray = 128;

pub const RenderedSpread = struct {
    pages: [detect.max_pages]PageImage,
    page_count: u8,
    /// True when the detector found the pages again in the full-size reference frame.
    redetected: bool,

    pub fn deinit(self: RenderedSpread, allocator: Allocator) void {
        for (self.pages[0..self.page_count]) |page| page.deinit(allocator);
    }

    pub fn pageSlice(self: *const RenderedSpread) []const PageImage {
        return self.pages[0..self.page_count];
    }
};

/// A small picture of each page of a spread, for the duplicate search.
pub const SpreadSignature = struct {
    /// The luma of each enhanced page at half the page size.
    pages: [detect.max_pages]image.Plane,
    page_count: u8,
    redetected: bool,
    /// The largest fraction of a page that lies outside the frame.
    outside_fraction: f32,
    /// The number of page sides that the frame cuts.
    clipped_edge_count: u8,

    pub fn deinit(self: SpreadSignature, allocator: Allocator) void {
        for (self.pages[0..self.page_count]) |page| page.deinit(allocator);
    }
};

// endregion: options and results

// region: page layout at full size

const FullLayout = struct {
    quads: [detect.max_pages]Quad,
    clipped_edges: [detect.max_pages]detect.ClippedEdges,
    outlines: [detect.max_pages]?curl.PageOutline,
    redetected: bool,
};

/// Find the pages of a full-size frame. When the detector fails or finds another
/// layout than the analysis pass, the quads of the analysis pass stay.
fn fullLayout(scratch: Allocator, source: SourceFrame, kind: detect.LayoutKind, options: Options) Allocator.Error!FullLayout {
    var layout: FullLayout = .{
        .quads = source.quads,
        .clipped_edges = source.clipped_edges,
        .outlines = @splat(null),
        .redetected = false,
    };
    var detect_options = options.detect;
    detect_options.outlines = options.curl;
    detect_options.layout = switch (kind) {
        .single => .single,
        .spread => .spread,
    };
    if (try detect.analyzeScene(scratch, source.frame, detect_options)) |scene| {
        defer scene.deinit(scratch);
        if (try detect.detectLayout(scratch, &scene, detect_options)) |found| {
            if (found.kind == kind) {
                layout.quads = found.pages;
                layout.clipped_edges = found.clipped_edges;
                layout.outlines = found.outlines;
                layout.redetected = true;
            }
        }
    }
    return layout;
}

/// The page layout of a frame as the analysis pass found it.
fn analysisLayout(source: SourceFrame) FullLayout {
    return .{
        .quads = source.quads,
        .clipped_edges = source.clipped_edges,
        .outlines = @splat(null),
        .redetected = false,
    };
}

fn pageAspect(size: image.Size) f32 {
    return @as(f32, @floatFromInt(size.width)) / @as(f32, @floatFromInt(size.height));
}

/// The map of one page of a frame to an output of `size` pixels: the curved map
/// when the page has a curved outline, else the plane through the quad. A page with
/// one side out of view gets the quad of the whole page.
fn pageMap(
    scratch: Allocator,
    frame: image.FrameView,
    layout: *const FullLayout,
    index: usize,
    size: image.Size,
    page_size: image.Size,
) Allocator.Error!?resample.PageMap {
    const quad = detect.completeQuad(layout.quads[index], layout.clipped_edges[index], pageAspect(page_size));
    var map = resample.PageMap.init(quad, size) orelse return null;
    if (layout.outlines[index]) |*outline| {
        const width: f32 = @floatFromInt(frame.width());
        const height: f32 = @floatFromInt(frame.height());
        const principal = geometry.Point.init(0.5 * (width - 1), 0.5 * (height - 1));
        const diagonal = @sqrt(width * width + height * height);
        if (try curl.CurvedMap.init(scratch, outline, size, principal, diagonal)) |curved| {
            errdefer curved.deinit(scratch);
            const stored = try scratch.create(curl.CurvedMap);
            stored.* = curved;
            map.curved = stored;
        }
    }
    return map;
}

/// Free what `pageMap` allocated.
fn freePageMap(scratch: Allocator, map: resample.PageMap) void {
    const curved = map.curved orelse return;
    curved.deinit(scratch);
    scratch.destroy(@constCast(curved));
}

const white = 255;

/// The luma of an RGB page as an 8-bit plane.
fn lumaPlane(allocator: Allocator, page: image.RgbF32) Allocator.Error!image.Plane {
    const plane = try image.Plane.init(allocator, page.width, page.height);
    for (plane.data, 0..) |*value, index| {
        const pixel = page.data[index * image.rgb_channels ..][0..image.rgb_channels];
        value.* = color.toByte(color.rgbLuma(pixel.*));
    }
    return plane;
}

// endregion: page layout at full size

// region: signatures

/// Render a small picture of each page of a spread from its reference frame. The
/// duplicate search compares these pictures.
pub fn renderSignature(
    allocator: Allocator,
    scratch: Allocator,
    reference: SourceFrame,
    kind: detect.LayoutKind,
    page_size: image.Size,
    options: Options,
) Allocator.Error!SpreadSignature {
    const layout = try fullLayout(scratch, reference, kind, options);
    const half: image.Size = .{ .width = @max(1, page_size.width / 2), .height = @max(1, page_size.height / 2) };
    var signature: SpreadSignature = .{
        .pages = undefined,
        .page_count = 0,
        .redetected = layout.redetected,
        .outside_fraction = 0,
        .clipped_edge_count = 0,
    };
    errdefer signature.deinit(allocator);
    for (0..kind.pageCount()) |index| {
        const map = (try pageMap(scratch, reference.frame, &layout, index, half, page_size)) orelse continue;
        defer freePageMap(scratch, map);
        const outside = try image.Plane.init(scratch, half.width, half.height);
        defer outside.deinit(scratch);
        const warped = try resample.warpPage(scratch, reference.frame, map, half, outside);
        defer warped.deinit(scratch);
        // No sharpening: the registration compares the structure, not fine edges.
        var enhance_options = options.enhance;
        enhance_options.sharpen_amount = 0;
        try enhance.enhance(scratch, warped, enhance_options);

        const luma = try lumaPlane(allocator, warped);
        var outside_count: usize = 0;
        for (outside.data, luma.data) |is_outside, *value| {
            if (is_outside == 0) continue;
            outside_count += 1;
            value.* = white;
        }
        signature.pages[signature.page_count] = luma;
        signature.page_count += 1;
        signature.outside_fraction = @max(
            signature.outside_fraction,
            @as(f32, @floatFromInt(outside_count)) / @as(f32, @floatFromInt(outside.data.len)),
        );
        signature.clipped_edge_count += layout.clipped_edges[index].count();
    }
    return signature;
}

// endregion: signatures

// region: pages

/// Render the pages of a spread from its reference frame, and repair them with the
/// donor frames. With no donor frames the result is the reference frame alone.
///
/// `only_page`, when given, is the one page to render: the two pages of a spread
/// can come from different reference frames. Each rendered page has its index in
/// `PageImage.index`.
///
/// `allocator` owns the returned images. `scratch` gives the working memory: all of
/// it is free again at the return. A caller that renders many spreads gives a
/// `memory.BlockCache` for the two, which keeps the large blocks for the next call.
pub fn renderSpread(
    allocator: Allocator,
    scratch: Allocator,
    reference: SourceFrame,
    donors: []const SourceFrame,
    kind: detect.LayoutKind,
    only_page: ?usize,
    page_size: image.Size,
    options: Options,
) Allocator.Error!RenderedSpread {
    const layout = try fullLayout(scratch, reference, kind, options);
    const donor_layouts = try scratch.alloc(FullLayout, donors.len);
    defer scratch.free(donor_layouts);
    const redetect = options.redetect_donors or options.curl;
    for (donors, donor_layouts) |donor, *donor_layout| {
        donor_layout.* = if (redetect) try fullLayout(scratch, donor, kind, options) else analysisLayout(donor);
    }

    var spread: RenderedSpread = .{ .pages = undefined, .page_count = 0, .redetected = layout.redetected };
    errdefer spread.deinit(allocator);
    for (0..kind.pageCount()) |index| {
        if (only_page) |wanted| {
            if (index != wanted) continue;
        }
        const map = (try pageMap(scratch, reference.frame, &layout, index, page_size, page_size)) orelse continue;
        defer freePageMap(scratch, map);
        const outside = try image.Plane.init(scratch, page_size.width, page_size.height);
        defer outside.deinit(scratch);
        const page = try resample.warpPage(scratch, reference.frame, map, page_size, outside);
        defer page.deinit(scratch);
        try enhance.flatten(scratch, page, options.enhance);

        var layers: std.ArrayList(fuse.Layer) = .empty;
        defer {
            // Layer 0 is the reference page, which has its own cleanup.
            for (layers.items[@min(1, layers.items.len)..]) |layer| {
                layer.page.deinit(scratch);
                if (layer.outside) |mask| mask.deinit(scratch);
            }
            layers.deinit(scratch);
        }
        try layers.append(scratch, .{ .page = page, .outside = outside });

        if (donors.len > 0) {
            // The registration compares the luma of the frames as the camera gave it.
            const reference_luma = try resample.warpLuma(scratch, reference.frame.y, map, page_size);
            defer reference_luma.deinit(scratch);
            for (donors, donor_layouts) |donor, *donor_layout| {
                const donor_map = (try pageMap(scratch, donor.frame, donor_layout, index, page_size, page_size)) orelse continue;
                defer freePageMap(scratch, donor_map);
                const alignment = (try alignDonor(scratch, reference_luma.view(), donor.frame.y, donor_map, page_size, options)) orelse continue;
                defer if (alignment.grid) |field| field.deinit(scratch);
                const donor_outside = try image.Plane.init(scratch, page_size.width, page_size.height);
                errdefer donor_outside.deinit(scratch);
                const donor_page = try resample.warpPageAligned(scratch, donor.frame, donor_map, alignment, page_size, donor_outside);
                errdefer donor_page.deinit(scratch);
                try enhance.flatten(scratch, donor_page, options.enhance);
                try layers.append(scratch, .{ .page = donor_page, .outside = donor_outside });
            }
        }

        const pictures: []image.Rgb8 = if (options.layer_pictures) try layerPictures(allocator, layers.items) else &.{};
        errdefer freeLayerPictures(allocator, pictures);

        var scratch_faults: ?fuse.FaultMap = null;
        defer if (scratch_faults) |found| found.deinit(scratch);
        const stats = try fuse.fuse(scratch, layers.items, options.fuse, if (options.fault_maps) &scratch_faults else null);
        try enhance.finish(scratch, page, options.enhance);

        // The map goes to the caller, so a copy moves out of the working memory.
        var faults: ?fuse.FaultMap = null;
        if (scratch_faults) |found| faults = try found.clone(allocator);
        errdefer if (faults) |kept| kept.deinit(allocator);
        const rgb = try enhance.toRgb8(allocator, page);
        errdefer rgb.deinit(allocator);
        // The part of the page that no frame shows is white.
        var outside_count: usize = 0;
        for (outside.data, 0..) |value, pixel_index| {
            if (value == 0) continue;
            outside_count += 1;
            rgb.data[pixel_index * image.rgb_channels ..][0..image.rgb_channels].* = @splat(white);
        }
        spread.pages[spread.page_count] = .{
            .rgb = rgb,
            .index = @intCast(index),
            .quad = layout.quads[index],
            .clipped_edges = layout.clipped_edges[index],
            .curled = map.curved != null,
            .outside_fraction = @as(f32, @floatFromInt(outside_count)) / @as(f32, @floatFromInt(outside.data.len)),
            .donors_used = @intCast(layers.items.len - 1),
            .fusion = stats,
            .faults = faults,
            .layers = pictures,
        };
        spread.page_count += 1;
    }
    return spread;
}

/// Find where the content of the reference page lies in the page of a donor frame.
/// Returns null when the donor does not match the reference well enough.
///
/// The page corners of a donor frame are a start value only: a hand or the border
/// of the frame can hide a corner. So the registration runs in rounds. Each next
/// round starts from the donor page moved by the transform so far, and then more
/// tiles fall into the search range. The caller frees the grid of the result.
fn alignDonor(
    scratch: Allocator,
    reference_luma: image.PlaneView,
    donor_luma: image.PlaneView,
    donor_map: resample.PageMap,
    page_size: image.Size,
    options: Options,
) Allocator.Error!?resample.Alignment {
    var total = geometry.Homography.identity;
    for (0..alignment_rounds) |round| {
        const moved = try resample.warpLumaAligned(scratch, donor_luma, donor_map, .{ .transform = total }, page_size);
        defer moved.deinit(scratch);
        const registration = try register.register(scratch, reference_luma, moved.view(), options.register);
        defer registration.deinit(scratch);
        if (!registration.fitted) return null;
        // `total` goes from a position in the reference page to the same content
        // in the donor page.
        total = total.mul(registration.transform);
        const good = registration.matchedFraction() >= options.min_donor_match and
            registration.residual <= options.max_donor_residual;
        if (good) {
            // The small shifts that the plane transform leaves were measured on the
            // moved page. They are a few pixels, so they hold after `total` too.
            return .{ .transform = total, .grid = try register.residualGrid(scratch, &registration) };
        }
        if (round + 1 == alignment_rounds or registration.inlier_tiles < min_tiles_to_continue) return null;
    }
    return null;
}

/// The largest number of registration rounds for one donor page.
const alignment_rounds = 3;
/// A transform from fewer tiles than this is not safe enough to continue with.
const min_tiles_to_continue = 16;

// endregion: pages

// region: encode

pub const EncodedPage = struct {
    jpeg: []u8,
    width: u32,
    height: u32,
    gray: bool,

    pub fn deinit(self: EncodedPage, allocator: Allocator) void {
        allocator.free(self.jpeg);
    }
};

/// Encode a page as JPEG: one grey component for a page without colour, full
/// chroma for a page with colour.
pub fn encodePage(allocator: Allocator, scratch: Allocator, page: image.Rgb8, options: jpeg.Options) jpeg.Error!EncodedPage {
    if (enhance.isGray(page)) {
        const gray = try image.Plane.init(scratch, page.width, page.height);
        defer gray.deinit(scratch);
        for (gray.data, 0..) |*value, index| {
            const pixel = page.data[index * image.rgb_channels ..][0..image.rgb_channels];
            const luma = color.rgbLuma(.{ @floatFromInt(pixel[0]), @floatFromInt(pixel[1]), @floatFromInt(pixel[2]) });
            value.* = @intFromFloat(std.math.clamp(luma + 0.5, 0, 255));
        }
        return .{
            .jpeg = try jpeg.encodeGray(allocator, scratch, gray.view(), options),
            .width = page.width,
            .height = page.height,
            .gray = true,
        };
    }
    return .{
        .jpeg = try jpeg.encodeRgb(allocator, scratch, page, options),
        .width = page.width,
        .height = page.height,
        .gray = false,
    };
}

// endregion: encode

// region: tests

const testing = std.testing;

const test_width = 320;
const test_height = 240;

/// A frame with a dark desk, a bright page at `page`, and a dark bar on the page.
/// `glare`, when given, makes a part of the bar as bright as the paper, with a warm tint.
fn testFrame(allocator: Allocator, page: Quad, glare: ?Quad) ![]u8 {
    const buffer = try allocator.alloc(u8, image.packedFrameSize(test_width, test_height));
    // The bar lies at fixed fractions of the page.
    const to_page = geometry.Homography.fromQuads(page, Quad.rect(1, 1)).?;
    for (0..test_height) |y| {
        for (0..test_width) |x| {
            const p = geometry.Point.init(@floatFromInt(x), @floatFromInt(y));
            var value: u8 = 70;
            if (page.contains(p)) {
                const uv = to_page.apply(p);
                const on_bar = uv.x > 0.2 and uv.x < 0.8 and uv.y > 0.4 and uv.y < 0.55;
                // A pattern of dots gives the registration something to hold.
                const dot = (@as(u32, @intFromFloat(uv.x * 40)) * 7 + @as(u32, @intFromFloat(uv.y * 50)) * 13) % 11 == 0;
                value = if (on_bar) 40 else if (dot) 120 else 200;
                if (glare) |area| {
                    if (on_bar and area.contains(p)) value = 195;
                }
            }
            buffer[y * test_width + x] = value;
        }
    }
    const luma_size = test_width * test_height;
    const chroma_size = (test_width / 2) * (test_height / 2);
    @memset(buffer[luma_size .. luma_size + chroma_size], 128);
    for (0..test_height / 2) |y| {
        for (0..test_width / 2) |x| {
            const p = geometry.Point.init(@floatFromInt(2 * x), @floatFromInt(2 * y));
            var v: u8 = if (page.contains(p)) 128 else 150;
            // Glare has the warm colour of the lamp.
            if (glare) |area| {
                if (area.contains(p)) v = 150;
            }
            buffer[luma_size + chroma_size + y * (test_width / 2) + x] = v;
        }
    }
    return buffer;
}

fn testSource(buffer: []const u8, page: Quad) SourceFrame {
    return .{
        .frame = image.FrameView.fromPacked(buffer, test_width, test_height, .{}),
        .quads = .{ page, page },
        .clipped_edges = @splat(.none),
    };
}

const test_page: Quad = .{
    .tl = geometry.Point.init(80, 30),
    .tr = geometry.Point.init(230, 30),
    .br = geometry.Point.init(230, 210),
    .bl = geometry.Point.init(80, 210),
};
const test_size: image.Size = .{ .width = 150, .height = 180 };

test "render a synthetic single page" {
    const buffer = try testFrame(testing.allocator, test_page, null);
    defer testing.allocator.free(buffer);

    const spread = try renderSpread(testing.allocator, testing.allocator, testSource(buffer, test_page), &.{}, .single, null, test_size, .{});
    defer spread.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), spread.page_count);
    try testing.expect(spread.redetected);
    const rgb = spread.pages[0].rgb;
    try testing.expectEqual(test_size.width, rgb.width);
    // Dark ink on the bar.
    try testing.expect(rgb.pixel(75, 85)[1] < 80);
    try testing.expectEqual(@as(f32, 0), spread.pages[0].outside_fraction);
    try testing.expectEqual(@as(u8, 0), spread.pages[0].donors_used);

    const encoded = try encodePage(testing.allocator, testing.allocator, rgb, .{});
    defer encoded.deinit(testing.allocator);
    try testing.expect(encoded.gray);
    try testing.expect(encoded.jpeg.len > 100);
}

/// The output row of the middle of the darkest rows of a column, in the top third of a page.
fn darkBarRow(page: image.Rgb8, x: usize) f32 {
    var sum: f32 = 0;
    var count: f32 = 0;
    for (0..page.height / 3) |y| {
        if (page.pixel(x, y)[1] < 100) {
            sum += @floatFromInt(y);
            count += 1;
        }
    }
    return if (count > 0) sum / count else -1;
}

test "a page with a curved top edge renders with the curved map" {
    const buffer = try testing.allocator.alloc(u8, image.packedFrameSize(test_width, test_height));
    defer testing.allocator.free(buffer);
    // The top and the bottom edge sag by 12 pixels in the middle. A dark bar runs 18
    // to 24 pixels below the top edge: a line of text on the curled paper.
    const Shape = struct {
        fn top(x: usize) f32 {
            const t = (@as(f32, @floatFromInt(x)) - 160) / 80;
            return 40 + 12 * (1 - t * t);
        }
        fn onPage(x: usize, y: usize) bool {
            if (x < 80 or x > 240) return false;
            // The bottom edge has the same bend as the top edge.
            const row: f32 = @floatFromInt(y);
            return row >= top(x) and row <= top(x) + 160;
        }
        fn onBar(x: usize, y: usize) bool {
            const below = @as(f32, @floatFromInt(y)) - top(x);
            return x > 86 and x < 234 and below >= 18 and below <= 24;
        }
    };
    for (0..test_height) |y| {
        for (0..test_width) |x| {
            buffer[y * test_width + x] = if (!Shape.onPage(x, y)) 70 else if (Shape.onBar(x, y)) 40 else 200;
        }
    }
    const luma_size = test_width * test_height;
    const chroma_size = (test_width / 2) * (test_height / 2);
    @memset(buffer[luma_size .. luma_size + chroma_size], 128);
    for (0..test_height / 2) |y| {
        for (0..test_width / 2) |x| {
            buffer[luma_size + chroma_size + y * (test_width / 2) + x] = if (Shape.onPage(2 * x, 2 * y)) 128 else 150;
        }
    }
    const page: Quad = .{
        .tl = geometry.Point.init(80, 40),
        .tr = geometry.Point.init(240, 40),
        .br = geometry.Point.init(240, 200),
        .bl = geometry.Point.init(80, 200),
    };
    const columns = [_]usize{ 15, 75, 135 };

    // With the curl correction the bar is one straight line.
    const curled = try renderSpread(testing.allocator, testing.allocator, testSource(buffer, page), &.{}, .single, null, test_size, .{ .curl = true });
    defer curled.deinit(testing.allocator);
    try testing.expect(curled.pages[0].curled);
    var lowest: f32 = std.math.inf(f32);
    var highest: f32 = -std.math.inf(f32);
    for (columns) |x| {
        const row = darkBarRow(curled.pages[0].rgb, x);
        try testing.expect(row > 0);
        lowest = @min(lowest, row);
        highest = @max(highest, row);
    }
    try testing.expect(highest - lowest < 3.5);

    // As a plane through four corners, the page keeps the bend of the bar.
    const flat = try renderSpread(testing.allocator, testing.allocator, testSource(buffer, page), &.{}, .single, null, test_size, .{});
    defer flat.deinit(testing.allocator);
    try testing.expect(!flat.pages[0].curled);
    lowest = std.math.inf(f32);
    highest = -std.math.inf(f32);
    for (columns) |x| {
        const row = darkBarRow(flat.pages[0].rgb, x);
        try testing.expect(row > 0);
        lowest = @min(lowest, row);
        highest = @max(highest, row);
    }
    try testing.expect(highest - lowest > 7);
}

test "the signature of a page has half the page size" {
    const buffer = try testFrame(testing.allocator, test_page, null);
    defer testing.allocator.free(buffer);
    const signature = try renderSignature(testing.allocator, testing.allocator, testSource(buffer, test_page), .single, test_size, .{});
    defer signature.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), signature.page_count);
    try testing.expectEqual(test_size.width / 2, signature.pages[0].width);
    try testing.expectEqual(@as(u8, 0), signature.clipped_edge_count);
}

test "donor frames repair glare on the reference frame" {
    // The reference has glare on the left part of the bar. Three donor frames show the
    // page a few pixels away, two of them with no glare.
    const glare: Quad = .{
        .tl = geometry.Point.init(100, 90),
        .tr = geometry.Point.init(160, 90),
        .br = geometry.Point.init(160, 140),
        .bl = geometry.Point.init(100, 140),
    };
    const shifts = [_]geometry.Point{ geometry.Point.init(4, 2), geometry.Point.init(-3, 3), geometry.Point.init(2, -4) };
    var donor_pages: [3]Quad = undefined;
    for (&donor_pages, shifts) |*page, shift| {
        page.* = .{ .tl = test_page.tl.add(shift), .tr = test_page.tr.add(shift), .br = test_page.br.add(shift), .bl = test_page.bl.add(shift) };
    }

    const reference_buffer = try testFrame(testing.allocator, test_page, glare);
    defer testing.allocator.free(reference_buffer);
    var donor_buffers: [3][]u8 = undefined;
    for (&donor_buffers, donor_pages) |*buffer, page| buffer.* = try testFrame(testing.allocator, page, null);
    defer for (donor_buffers) |buffer| testing.allocator.free(buffer);
    var donors: [3]SourceFrame = undefined;
    for (&donors, donor_buffers, donor_pages) |*donor, buffer, page| donor.* = testSource(buffer, page);

    // Small pages need small tiles.
    const options: Options = .{ .register = .{ .tile = 16, .max_levels = 2 }, .fuse = .{ .cell = 4 } };

    const alone = try renderSpread(testing.allocator, testing.allocator, testSource(reference_buffer, test_page), &.{}, .single, null, test_size, options);
    defer alone.deinit(testing.allocator);
    const fused = try renderSpread(testing.allocator, testing.allocator, testSource(reference_buffer, test_page), &donors, .single, null, test_size, options);
    defer fused.deinit(testing.allocator);

    // A point of the bar inside the glare: bright without the donors, dark with them.
    const x = 40;
    const y = 85;
    try testing.expect(alone.pages[0].rgb.pixel(x, y)[1] > 200);
    try testing.expectEqual(@as(u8, 3), fused.pages[0].donors_used);
    try testing.expect(fused.pages[0].fusion.glare > 0.01);
    try testing.expect(fused.pages[0].rgb.pixel(x, y)[1] < 90);
    // A point of the bar outside the glare stays dark.
    try testing.expect(fused.pages[0].rgb.pixel(110, 85)[1] < 90);
}

test "the page render frees its memory when an allocation fails" {
    // The reference has glare on the bar, and one donor frame shows the bar.
    const glare: Quad = .{
        .tl = geometry.Point.init(100, 90),
        .tr = geometry.Point.init(160, 90),
        .br = geometry.Point.init(160, 140),
        .bl = geometry.Point.init(100, 140),
    };
    const shift = geometry.Point.init(4, 2);
    const donor_page: Quad = .{ .tl = test_page.tl.add(shift), .tr = test_page.tr.add(shift), .br = test_page.br.add(shift), .bl = test_page.bl.add(shift) };
    const reference_buffer = try testFrame(testing.allocator, test_page, glare);
    defer testing.allocator.free(reference_buffer);
    const donor_buffer = try testFrame(testing.allocator, donor_page, null);
    defer testing.allocator.free(donor_buffer);
    const donors = [_]SourceFrame{testSource(donor_buffer, donor_page)};

    const Run = struct {
        fn run(allocator: Allocator, reference: SourceFrame, donor_frames: []const SourceFrame) !void {
            // The debug outputs are on, so their allocations have their turn too.
            const options: Options = .{
                .register = .{ .tile = 16, .max_levels = 2 },
                .fuse = .{ .cell = 4 },
                .fault_maps = true,
                .layer_pictures = true,
            };
            const spread = try renderSpread(allocator, allocator, reference, donor_frames, .single, null, test_size, options);
            defer spread.deinit(allocator);
            try testing.expectEqual(@as(u8, 1), spread.pages[0].donors_used);
            const encoded = try encodePage(allocator, allocator, spread.pages[0].rgb, .{});
            encoded.deinit(allocator);
        }
    };
    try testing.checkAllAllocationFailures(
        testing.allocator,
        Run.run,
        .{ testSource(reference_buffer, test_page), @as([]const SourceFrame, &donors) },
    );
}

// endregion: tests
