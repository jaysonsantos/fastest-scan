//! A PDF writer for documents of JPEG pages.
//!
//! The format is ISO 32000-1:2008 (PDF 1.7).
//!
//! Each page holds one image that fills the page. The writer sends the bytes to a
//! callback as it gets them, so the document never lies in memory as a whole.
//!
//! A later OCR text layer fits this layout: a page then gets a second content
//! stream with invisible text (text rendering mode 3) and a font resource.

const std = @import("std");
const Allocator = std.mem.Allocator;

// region: output

pub const WriteError = error{WriteFailed};

/// Where the bytes go. The CLI gives a file, an app can give a memory buffer or a
/// callback into another language.
pub const Output = struct {
    context: ?*anyopaque,
    writeFn: *const fn (context: ?*anyopaque, bytes: []const u8) WriteError!void,

    pub fn write(self: Output, bytes: []const u8) WriteError!void {
        return self.writeFn(self.context, bytes);
    }
};

// endregion: output

// region: constants

const points_per_inch = 72.0;

/// The object numbers that every document uses. Each page then takes three numbers.
const object = struct {
    const catalog = 1;
    const pages = 2;
    const info = 3;
    const first_page = 4;
    const per_page = 3;
    const image_offset = 0;
    const content_offset = 1;
    const page_offset = 2;
};

/// The name of the page image in the resources of its page.
const image_name = "Im0";

const header = "%PDF-1.7\n" ++
    // Four bytes above 127 tell transfer programs that the file is binary.
    "%\xE2\xE3\xCF\xD3\n";

const format_buffer_bytes = 512;

// endregion: constants

pub const ColorSpace = enum {
    gray,
    rgb,

    fn pdfName(self: ColorSpace) []const u8 {
        return switch (self) {
            .gray => "/DeviceGray",
            .rgb => "/DeviceRGB",
        };
    }
};

pub const Page = struct {
    /// A complete baseline JPEG file.
    jpeg: []const u8,
    width_px: u32,
    height_px: u32,
    color_space: ColorSpace,
    /// Pixels per inch. The size of the page on paper comes from it.
    dpi: f32,
};

pub const Metadata = struct {
    title: ?[]const u8 = null,
    producer: []const u8 = "fastest-scan",
};

pub const Error = WriteError || Allocator.Error || error{
    /// `finish` was already called.
    DocumentFinished,
};

pub const Writer = struct {
    allocator: Allocator,
    output: Output,
    metadata: Metadata,
    /// The byte position of each object, by object number. Index 0 is unused.
    offsets: std.ArrayList(u64),
    position: u64 = 0,
    page_count: u32 = 0,
    finished: bool = false,

    pub fn init(allocator: Allocator, output: Output, metadata: Metadata) Error!Writer {
        var writer: Writer = .{
            .allocator = allocator,
            .output = output,
            .metadata = metadata,
            .offsets = .empty,
        };
        errdefer writer.deinit();
        // The catalog, the page tree, and the information object come at the end,
        // when the number of pages is known.
        try writer.offsets.appendNTimes(allocator, 0, object.first_page);
        try writer.raw(header);
        return writer;
    }

    pub fn deinit(self: *Writer) void {
        self.offsets.deinit(self.allocator);
    }

    pub fn addPage(self: *Writer, page: Page) Error!void {
        if (self.finished) return error.DocumentFinished;
        const base = object.first_page + self.page_count * object.per_page;
        const image_id = base + object.image_offset;
        const content_id = base + object.content_offset;
        const page_id = base + object.page_offset;
        try self.offsets.appendNTimes(self.allocator, 0, object.per_page);

        const width_pt = @as(f32, @floatFromInt(page.width_px)) * points_per_inch / page.dpi;
        const height_pt = @as(f32, @floatFromInt(page.height_px)) * points_per_inch / page.dpi;

        try self.beginObject(image_id);
        try self.print(
            "<< /Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace {s} " ++
                "/BitsPerComponent 8 /Filter /DCTDecode /Length {d} >>\nstream\n",
            .{ page.width_px, page.height_px, page.color_space.pdfName(), page.jpeg.len },
        );
        try self.raw(page.jpeg);
        try self.raw("\nendstream\nendobj\n");

        // The image is one unit square; the matrix stretches it over the page.
        var content_buffer: [format_buffer_bytes]u8 = undefined;
        const content = std.mem.print(
            &content_buffer,
            "q {d:.3} 0 0 {d:.3} 0 0 cm /{s} Do Q\n",
            .{ width_pt, height_pt, image_name },
        ) catch unreachable;
        try self.beginObject(content_id);
        try self.print("<< /Length {d} >>\nstream\n", .{content.len});
        try self.raw(content);
        try self.raw("endstream\nendobj\n");

        try self.beginObject(page_id);
        try self.print(
            "<< /Type /Page /Parent {d} 0 R /MediaBox [0 0 {d:.3} {d:.3}] " ++
                "/Resources << /XObject << /{s} {d} 0 R >> >> /Contents [{d} 0 R] >>\nendobj\n",
            .{ object.pages, width_pt, height_pt, image_name, image_id, content_id },
        );
        self.page_count += 1;
    }

    /// Write the page tree, the cross-reference table, and the trailer.
    pub fn finish(self: *Writer) Error!void {
        if (self.finished) return error.DocumentFinished;
        self.finished = true;

        try self.beginObject(object.catalog);
        try self.print("<< /Type /Catalog /Pages {d} 0 R >>\nendobj\n", .{object.pages});

        try self.beginObject(object.pages);
        try self.raw("<< /Type /Pages /Kids [");
        for (0..self.page_count) |index| {
            const page_id = object.first_page + index * object.per_page + object.page_offset;
            try self.print("{d} 0 R ", .{page_id});
        }
        try self.print("] /Count {d} >>\nendobj\n", .{self.page_count});

        try self.beginObject(object.info);
        try self.raw("<< /Producer ");
        try self.literalString(self.metadata.producer);
        if (self.metadata.title) |title| {
            try self.raw(" /Title ");
            try self.literalString(title);
        }
        try self.raw(" >>\nendobj\n");

        const xref_position = self.position;
        const object_count = self.offsets.items.len;
        try self.print("xref\n0 {d}\n", .{object_count});
        // Each entry has exactly 20 bytes. Object 0 is the head of the free list.
        try self.raw("0000000000 65535 f \n");
        for (self.offsets.items[1..]) |offset| {
            try self.print("{d:0>10} 00000 n \n", .{offset});
        }
        try self.print(
            "trailer\n<< /Size {d} /Root {d} 0 R /Info {d} 0 R >>\nstartxref\n{d}\n%%EOF\n",
            .{ object_count, object.catalog, object.info, xref_position },
        );
    }

    fn beginObject(self: *Writer, id: usize) Error!void {
        self.offsets.items[id] = self.position;
        try self.print("{d} 0 obj\n", .{id});
    }

    fn raw(self: *Writer, bytes: []const u8) Error!void {
        try self.output.write(bytes);
        self.position += bytes.len;
    }

    fn print(self: *Writer, comptime format: []const u8, args: anytype) Error!void {
        var buffer: [format_buffer_bytes]u8 = undefined;
        const text = std.mem.print(&buffer, format, args) catch unreachable;
        try self.raw(text);
    }

    /// A PDF literal string. The three special characters get a backslash.
    fn literalString(self: *Writer, text: []const u8) Error!void {
        try self.raw("(");
        for (text) |char| {
            switch (char) {
                '(', ')', '\\' => try self.raw(&.{ '\\', char }),
                else => try self.raw(&.{char}),
            }
        }
        try self.raw(")");
    }
};

// region: tests

const testing = std.testing;

const MemoryOutput = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn output(self: *MemoryOutput) Output {
        return .{ .context = self, .writeFn = write };
    }

    fn write(context: ?*anyopaque, bytes: []const u8) WriteError!void {
        const self: *MemoryOutput = @ptrCast(@alignCast(context.?));
        self.bytes.appendSlice(testing.allocator, bytes) catch return error.WriteFailed;
    }
};

test "a document with two pages has a correct cross-reference table" {
    var memory: MemoryOutput = .{};
    defer memory.bytes.deinit(testing.allocator);

    var writer = try Writer.init(testing.allocator, memory.output(), .{ .title = "A (test) title" });
    defer writer.deinit();
    const fake_jpeg = "\xFF\xD8 not a real image \xFF\xD9";
    try writer.addPage(.{ .jpeg = fake_jpeg, .width_px = 1200, .height_px = 1800, .color_space = .rgb, .dpi = 300 });
    try writer.addPage(.{ .jpeg = fake_jpeg, .width_px = 600, .height_px = 900, .color_space = .gray, .dpi = 150 });
    try writer.finish();
    try testing.expectError(error.DocumentFinished, writer.finish());

    const bytes = memory.bytes.items;
    try testing.expect(std.mem.startsWith(u8, bytes, "%PDF-1.7\n"));
    try testing.expect(std.mem.endsWith(u8, bytes, "%%EOF\n"));
    try testing.expect(std.mem.find(u8, bytes, "/Count 2") != null);
    try testing.expect(std.mem.find(u8, bytes, "/MediaBox [0 0 288.000 432.000]") != null);
    try testing.expect(std.mem.find(u8, bytes, "/Title (A \\(test\\) title)") != null);

    // Every offset of the table points at the start of its object.
    const object_count = object.first_page + 2 * object.per_page;
    for (1..object_count) |id| {
        var expected_buffer: [32]u8 = undefined;
        const expected = try std.mem.print(&expected_buffer, "{d} 0 obj\n", .{id});
        const offset: usize = @intCast(writer.offsets.items[id]);
        try testing.expect(std.mem.startsWith(u8, bytes[offset..], expected));
    }

    // The `startxref` value points at the table.
    const marker = "startxref\n";
    const marker_position = std.mem.findLast(u8, bytes, marker).?;
    const number_start = marker_position + marker.len;
    const number_end = std.mem.findScalarPos(u8, bytes, number_start, '\n').?;
    const xref_position = try std.fmt.parseInt(usize, bytes[number_start..number_end], 10);
    try testing.expect(std.mem.startsWith(u8, bytes[xref_position..], "xref\n"));
}

// endregion: tests
