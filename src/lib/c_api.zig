//! The C interface of the library. `include/fastscan.h` declares these functions.

const std = @import("std");
const build_options = @import("build_options");

const version_z: [:0]const u8 = build_options.version ++ "";

/// The version of the library as a C string. The string lives as long as the program.
export fn fastscan_version() callconv(.c) [*:0]const u8 {
    return version_z.ptr;
}

test "the version string is not empty" {
    try std.testing.expect(std.mem.len(fastscan_version()) > 0);
}
