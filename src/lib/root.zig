//! fastscan: turn frames of a filmed book or document into clean page images and a PDF.
//!
//! The library never opens a video or a file. The caller pushes frames and receives
//! bytes. See `docs/decisions/0001-library-and-cli.md`.

const std = @import("std");
const build_options = @import("build_options");

pub const geometry = @import("geometry.zig");
pub const image = @import("image.zig");
pub const color = @import("color.zig");
pub const raster = @import("raster.zig");
pub const detect = @import("detect.zig");
pub const observe = @import("observe.zig");
pub const timeline = @import("timeline.zig");
pub const document = @import("document.zig");
pub const resample = @import("resample.zig");
pub const enhance = @import("enhance.zig");
pub const render = @import("render.zig");
pub const register = @import("register.zig");
pub const dedup = @import("dedup.zig");
pub const finger = @import("finger.zig");
pub const fuse = @import("fuse.zig");
pub const curl = @import("curl.zig");
pub const jpeg = @import("jpeg.zig");
pub const pdf = @import("pdf.zig");
pub const memory = @import("memory.zig");

/// The version of the library, from `build.zig.zon`.
pub const version: []const u8 = build_options.version;

test {
    std.testing.refAllDecls(@This());
    // A helper for the tests of the other files, with tests of its own.
    _ = @import("alloc_check.zig");
}
