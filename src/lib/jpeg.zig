//! A baseline JPEG encoder (ITU T.81, sequential DCT, 8-bit, Huffman).
//!
//! The encoder builds its Huffman tables from the statistics of the image, as
//! libjpeg does with `optimize_coding`. The files are 5 to 10 % smaller than with
//! the standard tables and every decoder reads them.
//!
//! Sources:
//! - ITU-T Recommendation T.81 (1992), "Digital compression and coding of
//!   continuous-tone still images": the format, the example quantization tables of
//!   Annex K.1, and the Huffman table procedure of Annex K.2.
//! - Y. Arai, T. Agui, and M. Nakajima, "A fast DCT-SQ scheme for images",
//!   Transactions of the IEICE E71(11), 1988: the forward DCT.
//! - libjpeg of the Independent JPEG Group (T. G. Lane and others): the float form
//!   of that DCT (`jfdctflt.c`), the quality scale (`jcparam.c`), and the order of
//!   the steps of the Huffman table procedure (`jchuff.c`). This software is based
//!   in part on the work of the Independent JPEG Group.
//! - E. Hamilton, "JPEG File Interchange Format, version 1.02", 1992: the header
//!   and the colour conversion.

const std = @import("std");
const Allocator = std.mem.Allocator;
const image = @import("image.zig");

// region: options

pub const Subsampling = enum {
    /// Full-resolution chroma. The best choice for coloured text and thin lines.
    s444,
    /// Chroma at half the width and half the height. Smaller files.
    s420,
};

pub const Options = struct {
    /// The libjpeg quality scale, 1 (worst) to 100 (best).
    quality: u8 = default_quality,
    subsampling: Subsampling = .s444,
    /// Pixels per inch, written into the JFIF header.
    dpi: u16 = default_dpi,

    pub const default_quality = 85;
    pub const default_dpi = 300;
};

pub const Error = Allocator.Error || error{
    /// A side of the image is zero or above 65535 pixels.
    UnsupportedDimensions,
};

// endregion: options

// region: constants

const block_side = 8;
const block_len = block_side * block_side;
const max_dimension = 65535;

const marker = struct {
    const soi = 0xD8;
    const eoi = 0xD9;
    const app0 = 0xE0;
    const dqt = 0xDB;
    const sof0 = 0xC0;
    const dht = 0xC4;
    const sos = 0xDA;
    const prefix = 0xFF;
};

/// The order in which the encoder writes the coefficients of a block: the index is
/// the position in the zigzag scan, the value is the position in the 8x8 block.
const zigzag = [block_len]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

/// The example quantization tables of T.81 Annex K, in block order.
const base_luma_quant = [block_len]u8{
    16, 11, 10, 16, 24,  40,  51,  61,
    12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,
    14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,
    24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};

const base_chroma_quant = [block_len]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

/// The output of the AAN forward DCT is the real DCT times these factors per row and
/// per column, times 8.
const aan_scale = [block_side]f32{
    1.0, 1.387039845, 1.306562965, 1.175875602,
    1.0, 0.785694958, 0.541196100, 0.275899379,
};
const aan_gain = 8.0;

const max_code_length = 16;
const symbol_count = 256;
/// The run-length symbol for 16 zero coefficients.
const zero_run_symbol = 0xF0;
const end_of_block_symbol = 0x00;
const max_zero_run = 15;

/// JFIF uses the BT.601 matrix with full-range luma and chroma.
const ycbcr = struct {
    const kr = 0.299;
    const kg = 0.587;
    const kb = 0.114;
    const cb_scale = 0.5 / (1.0 - kb);
    const cr_scale = 0.5 / (1.0 - kr);
    const chroma_offset = 128.0;
};
const level_shift = 128.0;

// endregion: constants

// region: byte sink

/// A growing byte buffer with a bit writer on top. The bit writer does the JPEG byte
/// stuffing: a zero byte follows every 0xFF of the entropy-coded data.
const Sink = struct {
    allocator: Allocator,
    bytes: []u8,
    len: usize = 0,
    bit_buffer: u32 = 0,
    bit_count: u5 = 0,

    const initial_capacity = 64 * 1024;

    fn init(allocator: Allocator, capacity_hint: usize) Allocator.Error!Sink {
        const bytes = try allocator.alloc(u8, @max(capacity_hint, initial_capacity));
        return .{ .allocator = allocator, .bytes = bytes };
    }

    fn deinit(self: *Sink) void {
        self.allocator.free(self.bytes);
    }

    fn reserve(self: *Sink, extra: usize) Allocator.Error!void {
        if (self.len + extra <= self.bytes.len) return;
        var capacity = self.bytes.len * 2;
        while (capacity < self.len + extra) capacity *= 2;
        self.bytes = try self.allocator.realloc(self.bytes, capacity);
    }

    fn byte(self: *Sink, value: u8) Allocator.Error!void {
        try self.reserve(1);
        self.bytes[self.len] = value;
        self.len += 1;
    }

    fn slice(self: *Sink, values: []const u8) Allocator.Error!void {
        try self.reserve(values.len);
        @memcpy(self.bytes[self.len .. self.len + values.len], values);
        self.len += values.len;
    }

    fn word(self: *Sink, value: u16) Allocator.Error!void {
        try self.byte(@intCast(value >> 8));
        try self.byte(@intCast(value & 0xFF));
    }

    fn markerOnly(self: *Sink, code: u8) Allocator.Error!void {
        try self.byte(marker.prefix);
        try self.byte(code);
    }

    /// Write the low `count` bits of `value`, most significant bit first.
    fn bits(self: *Sink, value: u32, count: u5) Allocator.Error!void {
        std.debug.assert(count <= max_code_length);
        if (count == 0) return;
        const mask = (@as(u32, 1) << count) - 1;
        self.bit_buffer = (self.bit_buffer << count) | (value & mask);
        var filled: u6 = @as(u6, self.bit_count) + count;
        while (filled >= 8) {
            const shift: u5 = @intCast(filled - 8);
            const out: u8 = @intCast((self.bit_buffer >> shift) & 0xFF);
            try self.reserve(2);
            self.bytes[self.len] = out;
            self.len += 1;
            if (out == marker.prefix) {
                self.bytes[self.len] = 0;
                self.len += 1;
            }
            filled -= 8;
        }
        self.bit_count = @intCast(filled);
    }

    /// Fill the last byte of the entropy-coded data with one bits.
    fn flushBits(self: *Sink) Allocator.Error!void {
        if (self.bit_count == 0) return;
        const padding: u5 = @intCast(8 - @as(u6, self.bit_count));
        try self.bits((@as(u32, 1) << padding) - 1, padding);
    }

    fn toOwned(self: *Sink) Allocator.Error![]u8 {
        const owned = try self.allocator.realloc(self.bytes, self.len);
        self.bytes = &.{};
        return owned;
    }
};

// endregion: byte sink

// region: Huffman tables

const HuffmanTable = struct {
    /// `counts[n]` is the number of codes with a length of `n` bits; `counts[0]` is unused.
    counts: [max_code_length + 1]u8,
    /// The symbols in order of increasing code length.
    values: [symbol_count]u8,
    value_count: u16,
    codes: [symbol_count]u16,
    lengths: [symbol_count]u5,

    /// Build the table with the smallest coded size for these symbol frequencies,
    /// with the procedure of T.81 Annex K.2.
    fn optimal(frequencies: *const [symbol_count]u32) HuffmanTable {
        const reserved = symbol_count;
        const no_link = -1;
        // A long input can give a code of more than 16 bits before the length limit runs.
        const max_unlimited_length = 32;

        var freq: [symbol_count + 1]u64 = undefined;
        for (frequencies, 0..) |f, i| freq[i] = f;
        // The reserved symbol takes the code of all one bits, which JPEG does not allow.
        freq[reserved] = 1;

        var code_size: [symbol_count + 1]u8 = @splat(0);
        var others: [symbol_count + 1]i16 = @splat(no_link);

        while (true) {
            // The two least frequent symbols. Ties go to the larger index.
            var c1: i16 = no_link;
            var c2: i16 = no_link;
            var least: u64 = std.math.maxInt(u64);
            for (freq, 0..) |f, i| {
                if (f != 0 and f <= least) {
                    least = f;
                    c1 = @intCast(i);
                }
            }
            least = std.math.maxInt(u64);
            for (freq, 0..) |f, i| {
                if (f != 0 and f <= least and @as(i16, @intCast(i)) != c1) {
                    least = f;
                    c2 = @intCast(i);
                }
            }
            if (c2 == no_link) break;

            var a: usize = @intCast(c1);
            var b: usize = @intCast(c2);
            freq[a] += freq[b];
            freq[b] = 0;

            code_size[a] += 1;
            while (others[a] != no_link) {
                a = @intCast(others[a]);
                code_size[a] += 1;
            }
            others[a] = @intCast(b);

            code_size[b] += 1;
            while (others[b] != no_link) {
                b = @intCast(others[b]);
                code_size[b] += 1;
            }
        }

        var bit_counts: [max_unlimited_length + 1]u16 = @splat(0);
        for (code_size) |size| {
            if (size != 0) bit_counts[size] += 1;
        }

        // Limit the code lengths to 16 bits (T.81 Figure K.3).
        var length: usize = max_unlimited_length;
        while (length > max_code_length) : (length -= 1) {
            while (bit_counts[length] > 0) {
                var shorter = length - 2;
                while (bit_counts[shorter] == 0) shorter -= 1;
                bit_counts[length] -= 2;
                bit_counts[length - 1] += 1;
                bit_counts[shorter + 1] += 2;
                bit_counts[shorter] -= 1;
            }
        }
        // Remove the reserved symbol: it has the longest code.
        length = max_code_length;
        while (bit_counts[length] == 0) length -= 1;
        bit_counts[length] -= 1;

        var table: HuffmanTable = .{
            .counts = @splat(0),
            .values = @splat(0),
            .value_count = 0,
            .codes = @splat(0),
            .lengths = @splat(0),
        };
        for (1..max_code_length + 1) |n| table.counts[n] = @intCast(bit_counts[n]);

        // The symbols sorted by code length. The reserved symbol is not in the list.
        var next: u16 = 0;
        for (1..max_unlimited_length + 1) |size| {
            for (0..symbol_count) |symbol| {
                if (code_size[symbol] == size) {
                    table.values[next] = @intCast(symbol);
                    next += 1;
                }
            }
        }
        table.value_count = next;
        table.assignCodes();
        return table;
    }

    /// Canonical codes from the counts and the sorted symbols (T.81 Annex C).
    fn assignCodes(self: *HuffmanTable) void {
        var code: u32 = 0;
        var index: usize = 0;
        for (1..max_code_length + 1) |length| {
            for (0..self.counts[length]) |_| {
                const symbol = self.values[index];
                self.codes[symbol] = @intCast(code);
                self.lengths[symbol] = @intCast(length);
                code += 1;
                index += 1;
            }
            code <<= 1;
        }
    }

    fn write(self: *const HuffmanTable, sink: *Sink, class: u8, id: u8) Allocator.Error!void {
        const header_bytes = 2 + 1 + max_code_length;
        try sink.markerOnly(marker.dht);
        try sink.word(@intCast(header_bytes + self.value_count));
        try sink.byte((class << 4) | id);
        try sink.slice(self.counts[1..]);
        try sink.slice(self.values[0..self.value_count]);
    }
};

const huffman_class_dc = 0;
const huffman_class_ac = 1;

// endregion: Huffman tables

// region: DCT and quantization

/// The forward DCT of Arai, Agui and Nakajima, in place. The result is scaled, see
/// `aan_scale`; the quantization step removes the scale.
fn forwardDct(data: *[block_len]f32) void {
    // Rows.
    var row: usize = 0;
    while (row < block_len) : (row += block_side) {
        dct1d(data, row, 1);
    }
    // Columns.
    for (0..block_side) |column| {
        dct1d(data, column, block_side);
    }
}

inline fn dct1d(data: *[block_len]f32, start: usize, step: usize) void {
    const c4 = 0.707106781;
    const c6 = 0.382683433;
    const c2_minus_c6 = 0.541196100;
    const c2_plus_c6 = 1.306562965;

    const d0 = data[start];
    const d1 = data[start + step];
    const d2 = data[start + 2 * step];
    const d3 = data[start + 3 * step];
    const d4 = data[start + 4 * step];
    const d5 = data[start + 5 * step];
    const d6 = data[start + 6 * step];
    const d7 = data[start + 7 * step];

    const tmp0 = d0 + d7;
    const tmp7 = d0 - d7;
    const tmp1 = d1 + d6;
    const tmp6 = d1 - d6;
    const tmp2 = d2 + d5;
    const tmp5 = d2 - d5;
    const tmp3 = d3 + d4;
    const tmp4 = d3 - d4;

    // Even part.
    const even10 = tmp0 + tmp3;
    const even13 = tmp0 - tmp3;
    const even11 = tmp1 + tmp2;
    const even12 = tmp1 - tmp2;
    data[start] = even10 + even11;
    data[start + 4 * step] = even10 - even11;
    const z1 = (even12 + even13) * c4;
    data[start + 2 * step] = even13 + z1;
    data[start + 6 * step] = even13 - z1;

    // Odd part.
    const odd10 = tmp4 + tmp5;
    const odd11 = tmp5 + tmp6;
    const odd12 = tmp6 + tmp7;
    const z5 = (odd10 - odd12) * c6;
    const z2 = c2_minus_c6 * odd10 + z5;
    const z4 = c2_plus_c6 * odd12 + z5;
    const z3 = odd11 * c4;
    const z11 = tmp7 + z3;
    const z13 = tmp7 - z3;
    data[start + 5 * step] = z13 + z2;
    data[start + 3 * step] = z13 - z2;
    data[start + step] = z11 + z4;
    data[start + 7 * step] = z11 - z4;
}

const QuantTable = struct {
    /// The table as the file stores it, in block order.
    values: [block_len]u8,
    /// One over (table value * DCT scale), in block order.
    reciprocals: [block_len]f32,

    fn init(base: *const [block_len]u8, quality: u8) QuantTable {
        const clamped: u32 = std.math.clamp(quality, 1, 100);
        // The quality scale of libjpeg.
        const scale: u32 = if (clamped < 50) 5000 / clamped else 200 - 2 * clamped;
        var table: QuantTable = undefined;
        for (base, 0..) |base_value, i| {
            const scaled = (@as(u32, base_value) * scale + 50) / 100;
            const value: u8 = @intCast(std.math.clamp(scaled, 1, 255));
            table.values[i] = value;
            const row = i / block_side;
            const column = i % block_side;
            table.reciprocals[i] = 1.0 / (@as(f32, @floatFromInt(value)) * aan_scale[row] * aan_scale[column] * aan_gain);
        }
        return table;
    }

    fn write(self: *const QuantTable, sink: *Sink, id: u8) Allocator.Error!void {
        const segment_bytes = 2 + 1 + block_len;
        try sink.markerOnly(marker.dqt);
        try sink.word(segment_bytes);
        try sink.byte(id);
        for (zigzag) |position| try sink.byte(self.values[position]);
    }
};

/// Transform one block of level-shifted samples and write the quantized coefficients
/// in zigzag order.
fn transformBlock(samples: *[block_len]f32, table: *const QuantTable, out: *[block_len]i16) void {
    forwardDct(samples);
    for (zigzag, 0..) |position, i| {
        const quantized = @round(samples[position] * table.reciprocals[position]);
        out[i] = @intFromFloat(quantized);
    }
}

// endregion: DCT and quantization

// region: entropy coding

/// The number of bits of the magnitude of a coefficient (the "size category").
fn magnitudeBits(value: i32) u5 {
    const magnitude: u32 = @abs(value);
    return @intCast(32 - @clz(magnitude));
}

/// The extra bits that follow the Huffman code: the value for a positive
/// coefficient, the value minus one for a negative coefficient.
fn magnitudeCode(value: i32, bit_count: u5) u32 {
    const adjusted: i32 = if (value < 0) value - 1 else value;
    const mask = (@as(u32, 1) << bit_count) - 1;
    return @as(u32, @bitCast(adjusted)) & mask;
}

const Statistics = struct {
    dc: [symbol_count]u32 = @splat(0),
    ac: [symbol_count]u32 = @splat(0),
};

/// Walk the blocks of one component and either count the symbols or write the codes.
const BlockCoder = struct {
    previous_dc: i32 = 0,

    fn count(self: *BlockCoder, block: *const [block_len]i16, stats: *Statistics) void {
        const dc: i32 = block[0];
        const difference = dc - self.previous_dc;
        self.previous_dc = dc;
        stats.dc[magnitudeBits(difference)] += 1;

        var run: u32 = 0;
        for (block[1..]) |coefficient| {
            if (coefficient == 0) {
                run += 1;
                continue;
            }
            while (run > max_zero_run) : (run -= max_zero_run + 1) {
                stats.ac[zero_run_symbol] += 1;
            }
            const size = magnitudeBits(coefficient);
            stats.ac[(run << 4) | size] += 1;
            run = 0;
        }
        if (run > 0) stats.ac[end_of_block_symbol] += 1;
    }

    fn write(
        self: *BlockCoder,
        block: *const [block_len]i16,
        dc_table: *const HuffmanTable,
        ac_table: *const HuffmanTable,
        sink: *Sink,
    ) Allocator.Error!void {
        const dc: i32 = block[0];
        const difference = dc - self.previous_dc;
        self.previous_dc = dc;
        const dc_size = magnitudeBits(difference);
        try sink.bits(dc_table.codes[dc_size], dc_table.lengths[dc_size]);
        try sink.bits(magnitudeCode(difference, dc_size), dc_size);

        var run: u32 = 0;
        for (block[1..]) |coefficient| {
            if (coefficient == 0) {
                run += 1;
                continue;
            }
            while (run > max_zero_run) : (run -= max_zero_run + 1) {
                try sink.bits(ac_table.codes[zero_run_symbol], ac_table.lengths[zero_run_symbol]);
            }
            const size = magnitudeBits(coefficient);
            const symbol = (run << 4) | size;
            try sink.bits(ac_table.codes[symbol], ac_table.lengths[symbol]);
            try sink.bits(magnitudeCode(coefficient, size), size);
            run = 0;
        }
        if (run > 0) {
            try sink.bits(ac_table.codes[end_of_block_symbol], ac_table.lengths[end_of_block_symbol]);
        }
    }
};

// endregion: entropy coding

// region: components

/// The quantized coefficients of one colour component, block after block.
const Component = struct {
    blocks: [][block_len]i16,
    blocks_wide: usize,
    blocks_high: usize,

    fn init(allocator: Allocator, blocks_wide: usize, blocks_high: usize) Allocator.Error!Component {
        return .{
            .blocks = try allocator.alloc([block_len]i16, blocks_wide * blocks_high),
            .blocks_wide = blocks_wide,
            .blocks_high = blocks_high,
        };
    }

    fn deinit(self: Component, allocator: Allocator) void {
        allocator.free(self.blocks);
    }

    /// Transform a plane of samples in the range 0..255. The plane has
    /// `blocks_wide * 8` by `blocks_high * 8` samples.
    fn transform(self: Component, samples: []const f32, table: *const QuantTable) void {
        const plane_width = self.blocks_wide * block_side;
        var work: [block_len]f32 = undefined;
        for (0..self.blocks_high) |block_y| {
            for (0..self.blocks_wide) |block_x| {
                for (0..block_side) |y| {
                    const source = samples[(block_y * block_side + y) * plane_width + block_x * block_side ..][0..block_side];
                    for (source, 0..) |sample, x| work[y * block_side + x] = sample - level_shift;
                }
                transformBlock(&work, table, &self.blocks[block_y * self.blocks_wide + block_x]);
            }
        }
    }
};

/// A float plane whose size is a multiple of the block size. The pixels past the
/// image repeat the last row and the last column.
const PaddedPlane = struct {
    data: []f32,
    width: usize,
    height: usize,

    fn init(allocator: Allocator, width: usize, height: usize) Allocator.Error!PaddedPlane {
        return .{ .data = try allocator.alloc(f32, width * height), .width = width, .height = height };
    }

    fn deinit(self: PaddedPlane, allocator: Allocator) void {
        allocator.free(self.data);
    }

    /// Repeat the samples of the `valid_width` by `valid_height` corner into the rest.
    fn pad(self: PaddedPlane, valid_width: usize, valid_height: usize) void {
        for (0..valid_height) |y| {
            const row = self.data[y * self.width .. (y + 1) * self.width];
            const last = row[valid_width - 1];
            @memset(row[valid_width..], last);
        }
        const last_row = self.data[(valid_height - 1) * self.width .. valid_height * self.width];
        for (valid_height..self.height) |y| {
            @memcpy(self.data[y * self.width .. (y + 1) * self.width], last_row);
        }
    }

    /// The plane at half the width and half the height, each sample the mean of 2x2.
    fn halved(self: PaddedPlane, allocator: Allocator) Allocator.Error!PaddedPlane {
        const out = try PaddedPlane.init(allocator, self.width / 2, self.height / 2);
        for (0..out.height) |y| {
            const top = self.data[(2 * y) * self.width ..];
            const bottom = self.data[(2 * y + 1) * self.width ..];
            for (0..out.width) |x| {
                out.data[y * out.width + x] = 0.25 * (top[2 * x] + top[2 * x + 1] + bottom[2 * x] + bottom[2 * x + 1]);
            }
        }
        return out;
    }
};

fn roundUp(value: usize, multiple: usize) usize {
    return (value + multiple - 1) / multiple * multiple;
}

// endregion: components

// region: headers

fn writeJfifHeader(sink: *Sink, dpi: u16) Allocator.Error!void {
    const segment_bytes = 16;
    const version_major = 1;
    const version_minor = 1;
    const units_dots_per_inch = 1;
    try sink.markerOnly(marker.soi);
    try sink.markerOnly(marker.app0);
    try sink.word(segment_bytes);
    try sink.slice("JFIF\x00");
    try sink.byte(version_major);
    try sink.byte(version_minor);
    try sink.byte(units_dots_per_inch);
    try sink.word(dpi);
    try sink.word(dpi);
    // No thumbnail.
    try sink.byte(0);
    try sink.byte(0);
}

const ComponentHeader = struct {
    id: u8,
    horizontal_sampling: u8,
    vertical_sampling: u8,
    quant_table: u8,
    huffman_table: u8,
};

fn writeFrameHeader(sink: *Sink, width: u32, height: u32, components: []const ComponentHeader) Allocator.Error!void {
    const sample_precision = 8;
    try sink.markerOnly(marker.sof0);
    try sink.word(@intCast(8 + 3 * components.len));
    try sink.byte(sample_precision);
    try sink.word(@intCast(height));
    try sink.word(@intCast(width));
    try sink.byte(@intCast(components.len));
    for (components) |component| {
        try sink.byte(component.id);
        try sink.byte((component.horizontal_sampling << 4) | component.vertical_sampling);
        try sink.byte(component.quant_table);
    }
}

fn writeScanHeader(sink: *Sink, components: []const ComponentHeader) Allocator.Error!void {
    const spectral_start = 0;
    const spectral_end = block_len - 1;
    try sink.markerOnly(marker.sos);
    try sink.word(@intCast(6 + 2 * components.len));
    try sink.byte(@intCast(components.len));
    for (components) |component| {
        try sink.byte(component.id);
        try sink.byte((component.huffman_table << 4) | component.huffman_table);
    }
    try sink.byte(spectral_start);
    try sink.byte(spectral_end);
    try sink.byte(0);
}

const luma_table_id = 0;
const chroma_table_id = 1;

// endregion: headers

// region: public encoders

/// Encode an 8-bit grey image. The caller owns the returned bytes, which come from
/// `allocator`. `scratch` gives the working memory: it is free again at the return.
pub fn encodeGray(allocator: Allocator, scratch: Allocator, plane: image.PlaneView, options: Options) Error![]u8 {
    if (plane.width == 0 or plane.height == 0 or plane.width > max_dimension or plane.height > max_dimension) {
        return error.UnsupportedDimensions;
    }
    const padded_width = roundUp(plane.width, block_side);
    const padded_height = roundUp(plane.height, block_side);

    const samples = try PaddedPlane.init(scratch, padded_width, padded_height);
    defer samples.deinit(scratch);
    for (0..plane.height) |y| {
        const source = plane.row(y);
        const target = samples.data[y * padded_width ..];
        for (source, 0..) |value, x| target[x] = @floatFromInt(value);
    }
    samples.pad(plane.width, plane.height);

    const quant = QuantTable.init(&base_luma_quant, options.quality);
    const component = try Component.init(scratch, padded_width / block_side, padded_height / block_side);
    defer component.deinit(scratch);
    component.transform(samples.data, &quant);

    var stats: Statistics = .{};
    var counter: BlockCoder = .{};
    for (component.blocks) |*block| counter.count(block, &stats);
    const dc_table = HuffmanTable.optimal(&stats.dc);
    const ac_table = HuffmanTable.optimal(&stats.ac);

    var sink = try Sink.init(allocator, plane.size().pixels() / 4);
    errdefer sink.deinit();
    const headers = [_]ComponentHeader{
        .{ .id = 1, .horizontal_sampling = 1, .vertical_sampling = 1, .quant_table = luma_table_id, .huffman_table = luma_table_id },
    };
    try writeJfifHeader(&sink, options.dpi);
    try quant.write(&sink, luma_table_id);
    try writeFrameHeader(&sink, plane.width, plane.height, &headers);
    try dc_table.write(&sink, huffman_class_dc, luma_table_id);
    try ac_table.write(&sink, huffman_class_ac, luma_table_id);
    try writeScanHeader(&sink, &headers);

    var coder: BlockCoder = .{};
    for (component.blocks) |*block| try coder.write(block, &dc_table, &ac_table, &sink);
    try sink.flushBits();
    try sink.markerOnly(marker.eoi);
    return sink.toOwned();
}

/// Encode an 8-bit sRGB image. The caller owns the returned bytes, which come from
/// `allocator`. `scratch` gives the working memory: it is free again at the return.
pub fn encodeRgb(allocator: Allocator, scratch: Allocator, rgb: image.Rgb8, options: Options) Error![]u8 {
    if (rgb.width == 0 or rgb.height == 0 or rgb.width > max_dimension or rgb.height > max_dimension) {
        return error.UnsupportedDimensions;
    }
    // One MCU holds 8x8 pixels with full chroma and 16x16 pixels with halved chroma.
    const mcu_side: usize = switch (options.subsampling) {
        .s444 => block_side,
        .s420 => 2 * block_side,
    };
    const padded_width = roundUp(rgb.width, mcu_side);
    const padded_height = roundUp(rgb.height, mcu_side);

    const luma = try PaddedPlane.init(scratch, padded_width, padded_height);
    defer luma.deinit(scratch);
    var cb = try PaddedPlane.init(scratch, padded_width, padded_height);
    defer cb.deinit(scratch);
    var cr = try PaddedPlane.init(scratch, padded_width, padded_height);
    defer cr.deinit(scratch);

    for (0..rgb.height) |y| {
        const source = rgb.row(y);
        const row_start = y * padded_width;
        for (0..rgb.width) |x| {
            const r: f32 = @floatFromInt(source[x * image.rgb_channels]);
            const g: f32 = @floatFromInt(source[x * image.rgb_channels + 1]);
            const b: f32 = @floatFromInt(source[x * image.rgb_channels + 2]);
            const y_value = ycbcr.kr * r + ycbcr.kg * g + ycbcr.kb * b;
            luma.data[row_start + x] = y_value;
            cb.data[row_start + x] = (b - y_value) * ycbcr.cb_scale + ycbcr.chroma_offset;
            cr.data[row_start + x] = (r - y_value) * ycbcr.cr_scale + ycbcr.chroma_offset;
        }
    }
    luma.pad(rgb.width, rgb.height);
    cb.pad(rgb.width, rgb.height);
    cr.pad(rgb.width, rgb.height);

    if (options.subsampling == .s420) {
        const cb_half = try cb.halved(scratch);
        cb.deinit(scratch);
        cb = cb_half;
        const cr_half = try cr.halved(scratch);
        cr.deinit(scratch);
        cr = cr_half;
    }

    const luma_quant = QuantTable.init(&base_luma_quant, options.quality);
    const chroma_quant = QuantTable.init(&base_chroma_quant, options.quality);

    const y_component = try Component.init(scratch, luma.width / block_side, luma.height / block_side);
    defer y_component.deinit(scratch);
    const cb_component = try Component.init(scratch, cb.width / block_side, cb.height / block_side);
    defer cb_component.deinit(scratch);
    const cr_component = try Component.init(scratch, cr.width / block_side, cr.height / block_side);
    defer cr_component.deinit(scratch);
    y_component.transform(luma.data, &luma_quant);
    cb_component.transform(cb.data, &chroma_quant);
    cr_component.transform(cr.data, &chroma_quant);

    const luma_blocks_per_mcu: usize = mcu_side / block_side;
    const mcus_wide = padded_width / mcu_side;
    const mcus_high = padded_height / mcu_side;

    // First pass: symbol statistics, in the order of the scan.
    var luma_stats: Statistics = .{};
    var chroma_stats: Statistics = .{};
    {
        var y_coder: BlockCoder = .{};
        var cb_coder: BlockCoder = .{};
        var cr_coder: BlockCoder = .{};
        for (0..mcus_high) |mcu_y| {
            for (0..mcus_wide) |mcu_x| {
                for (0..luma_blocks_per_mcu) |dy| {
                    for (0..luma_blocks_per_mcu) |dx| {
                        const index = (mcu_y * luma_blocks_per_mcu + dy) * y_component.blocks_wide + mcu_x * luma_blocks_per_mcu + dx;
                        y_coder.count(&y_component.blocks[index], &luma_stats);
                    }
                }
                const chroma_index = mcu_y * cb_component.blocks_wide + mcu_x;
                cb_coder.count(&cb_component.blocks[chroma_index], &chroma_stats);
                cr_coder.count(&cr_component.blocks[chroma_index], &chroma_stats);
            }
        }
    }
    const luma_dc = HuffmanTable.optimal(&luma_stats.dc);
    const luma_ac = HuffmanTable.optimal(&luma_stats.ac);
    const chroma_dc = HuffmanTable.optimal(&chroma_stats.dc);
    const chroma_ac = HuffmanTable.optimal(&chroma_stats.ac);

    var sink = try Sink.init(allocator, rgb.size().pixels() / 4);
    errdefer sink.deinit();
    const luma_sampling: u8 = @intCast(luma_blocks_per_mcu);
    const headers = [_]ComponentHeader{
        .{ .id = 1, .horizontal_sampling = luma_sampling, .vertical_sampling = luma_sampling, .quant_table = luma_table_id, .huffman_table = luma_table_id },
        .{ .id = 2, .horizontal_sampling = 1, .vertical_sampling = 1, .quant_table = chroma_table_id, .huffman_table = chroma_table_id },
        .{ .id = 3, .horizontal_sampling = 1, .vertical_sampling = 1, .quant_table = chroma_table_id, .huffman_table = chroma_table_id },
    };
    try writeJfifHeader(&sink, options.dpi);
    try luma_quant.write(&sink, luma_table_id);
    try chroma_quant.write(&sink, chroma_table_id);
    try writeFrameHeader(&sink, rgb.width, rgb.height, &headers);
    try luma_dc.write(&sink, huffman_class_dc, luma_table_id);
    try luma_ac.write(&sink, huffman_class_ac, luma_table_id);
    try chroma_dc.write(&sink, huffman_class_dc, chroma_table_id);
    try chroma_ac.write(&sink, huffman_class_ac, chroma_table_id);
    try writeScanHeader(&sink, &headers);

    // Second pass: the entropy-coded data.
    var y_coder: BlockCoder = .{};
    var cb_coder: BlockCoder = .{};
    var cr_coder: BlockCoder = .{};
    for (0..mcus_high) |mcu_y| {
        for (0..mcus_wide) |mcu_x| {
            for (0..luma_blocks_per_mcu) |dy| {
                for (0..luma_blocks_per_mcu) |dx| {
                    const index = (mcu_y * luma_blocks_per_mcu + dy) * y_component.blocks_wide + mcu_x * luma_blocks_per_mcu + dx;
                    try y_coder.write(&y_component.blocks[index], &luma_dc, &luma_ac, &sink);
                }
            }
            const chroma_index = mcu_y * cb_component.blocks_wide + mcu_x;
            try cb_coder.write(&cb_component.blocks[chroma_index], &chroma_dc, &chroma_ac, &sink);
            try cr_coder.write(&cr_component.blocks[chroma_index], &chroma_dc, &chroma_ac, &sink);
        }
    }
    try sink.flushBits();
    try sink.markerOnly(marker.eoi);
    return sink.toOwned();
}

// endregion: public encoders

// region: tests

const testing = std.testing;
const alloc_check = @import("alloc_check.zig");

/// The DCT by its definition, for the comparison with the fast transform.
fn referenceDct(input: *const [block_len]f32, output: *[block_len]f32) void {
    for (0..block_side) |v| {
        for (0..block_side) |u| {
            var sum: f64 = 0;
            for (0..block_side) |y| {
                for (0..block_side) |x| {
                    const cos_x = @cos((2.0 * @as(f64, @floatFromInt(x)) + 1.0) * @as(f64, @floatFromInt(u)) * std.math.pi / 16.0);
                    const cos_y = @cos((2.0 * @as(f64, @floatFromInt(y)) + 1.0) * @as(f64, @floatFromInt(v)) * std.math.pi / 16.0);
                    sum += input[y * block_side + x] * cos_x * cos_y;
                }
            }
            const cu: f64 = if (u == 0) std.math.sqrt1_2 else 1;
            const cv: f64 = if (v == 0) std.math.sqrt1_2 else 1;
            output[v * block_side + u] = @floatCast(0.25 * cu * cv * sum);
        }
    }
}

test "the fast DCT matches the definition" {
    var input: [block_len]f32 = undefined;
    var random = std.Random.DefaultPrng.init(1234);
    for (&input) |*value| value.* = @as(f32, @floatFromInt(random.random().uintLessThan(u32, 256))) - level_shift;

    var expected: [block_len]f32 = undefined;
    referenceDct(&input, &expected);

    var actual = input;
    forwardDct(&actual);
    for (0..block_len) |i| {
        const scale = aan_scale[i / block_side] * aan_scale[i % block_side] * aan_gain;
        try testing.expectApproxEqAbs(expected[i], actual[i] / scale, 1e-2);
    }
}

test "magnitude categories and codes" {
    try testing.expectEqual(@as(u5, 0), magnitudeBits(0));
    try testing.expectEqual(@as(u5, 1), magnitudeBits(1));
    try testing.expectEqual(@as(u5, 1), magnitudeBits(-1));
    try testing.expectEqual(@as(u5, 3), magnitudeBits(-5));
    try testing.expectEqual(@as(u5, 8), magnitudeBits(255));
    try testing.expectEqual(@as(u32, 0b010), magnitudeCode(-5, 3));
    try testing.expectEqual(@as(u32, 0b101), magnitudeCode(5, 3));
    try testing.expectEqual(@as(u32, 0), magnitudeCode(-1, 1));
}

test "optimal Huffman table gives prefix-free codes within 16 bits" {
    var frequencies: [symbol_count]u32 = @splat(0);
    // A steep distribution forces the length limit to run.
    var value: u32 = 1;
    for (0..40) |i| {
        frequencies[i] = value;
        value = value * 2 + 1;
        if (value > 1 << 28) value = 1 << 28;
    }
    const table = HuffmanTable.optimal(&frequencies);
    try testing.expectEqual(@as(u16, 40), table.value_count);

    var kraft: f64 = 0;
    for (0..symbol_count) |symbol| {
        if (frequencies[symbol] == 0) continue;
        const length = table.lengths[symbol];
        try testing.expect(length >= 1 and length <= max_code_length);
        kraft += std.math.pow(f64, 2, -@as(f64, @floatFromInt(length)));
        // No code is a prefix of another code.
        for (0..symbol_count) |other| {
            if (other == symbol or frequencies[other] == 0) continue;
            const other_length = table.lengths[other];
            if (other_length < length) continue;
            const shift: u4 = @intCast(other_length - length);
            try testing.expect((table.codes[other] >> shift) != table.codes[symbol]);
        }
    }
    // The reserved all-ones code keeps the sum below one.
    try testing.expect(kraft < 1.0);
}

test "bit writer stuffs a zero after 0xFF" {
    var sink = try Sink.init(testing.allocator, 16);
    defer sink.deinit();
    try sink.bits(0xFF, 8);
    try sink.bits(0b101, 3);
    try sink.flushBits();
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x00, 0b10111111 }, sink.bytes[0..sink.len]);
}

test "encoded files start and end with the JPEG markers" {
    const width = 19;
    const height = 13;
    var rgb = try image.Rgb8.init(testing.allocator, width, height);
    defer rgb.deinit(testing.allocator);
    for (rgb.data, 0..) |*value, i| value.* = @intCast((i * 7) % 256);

    for ([_]Subsampling{ .s444, .s420 }) |subsampling| {
        const bytes = try encodeRgb(testing.allocator, testing.allocator, rgb, .{ .subsampling = subsampling });
        defer testing.allocator.free(bytes);
        try testing.expectEqualSlices(u8, &.{ marker.prefix, marker.soi }, bytes[0..2]);
        try testing.expectEqualSlices(u8, &.{ marker.prefix, marker.eoi }, bytes[bytes.len - 2 ..]);
    }

    var gray = try image.Plane.init(testing.allocator, width, height);
    defer gray.deinit(testing.allocator);
    for (gray.data, 0..) |*value, i| value.* = @intCast((i * 5) % 256);
    const gray_bytes = try encodeGray(testing.allocator, testing.allocator, gray.view(), .{});
    defer testing.allocator.free(gray_bytes);
    try testing.expectEqualSlices(u8, &.{ marker.prefix, marker.soi }, gray_bytes[0..2]);
    try testing.expectEqualSlices(u8, &.{ marker.prefix, marker.eoi }, gray_bytes[gray_bytes.len - 2 ..]);
}

test "zero-sized images are an error" {
    const empty: image.PlaneView = .{ .data = &.{}, .width = 0, .height = 4, .stride = 0 };
    try testing.expectError(error.UnsupportedDimensions, encodeGray(testing.allocator, testing.allocator, empty, .{}));
}

test "the encoders free their memory when an allocation fails" {
    const width = 19;
    const height = 13;
    var rgb = try image.Rgb8.init(testing.allocator, width, height);
    defer rgb.deinit(testing.allocator);
    for (rgb.data, 0..) |*value, i| value.* = @intCast((i * 7) % 256);
    var gray = try image.Plane.init(testing.allocator, width, height);
    defer gray.deinit(testing.allocator);
    for (gray.data, 0..) |*value, i| value.* = @intCast((i * 5) % 256);

    const Check = struct {
        fn color(allocator: Allocator, picture: image.Rgb8, subsampling: Subsampling) !void {
            const bytes = try encodeRgb(allocator, allocator, picture, .{ .subsampling = subsampling });
            allocator.free(bytes);
        }
        fn grey(allocator: Allocator, picture: image.PlaneView) !void {
            const bytes = try encodeGray(allocator, allocator, picture, .{});
            allocator.free(bytes);
        }
    };
    try alloc_check.eachFailure(testing.allocator, Check.color, .{ rgb, Subsampling.s444 });
    try alloc_check.eachFailure(testing.allocator, Check.color, .{ rgb, Subsampling.s420 });
    try alloc_check.eachFailure(testing.allocator, Check.grey, .{gray.view()});
}

// endregion: tests
