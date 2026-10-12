//! What the operating system knows about this process.

const std = @import("std");
const Io = std.Io;

const status_path = "/proc/self/status";
const peak_memory_key = "VmHWM:";
const bytes_per_kilobyte = 1024;
/// The file is about 1.5 kB, and the line with the peak is in its first third.
const status_buffer_bytes = 4096;

/// The largest amount of memory that this process had in use at one time, in bytes.
/// The value does not include the `ffmpeg` processes. Null on a system that is not
/// Linux.
pub fn peakMemoryBytes(io: Io) ?u64 {
    var buffer: [status_buffer_bytes]u8 = undefined;
    const file = Io.Dir.cwd().openFile(io, status_path, .{}) catch return null;
    defer file.close(io);
    const count = file.readPositionalAll(io, &buffer, 0) catch return null;
    return parsePeakMemory(buffer[0..count]);
}

fn parsePeakMemory(status: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, peak_memory_key)) continue;
        var fields = std.mem.tokenizeAny(u8, line[peak_memory_key.len..], " \t");
        const kilobytes = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
        return kilobytes * bytes_per_kilobyte;
    }
    return null;
}

test "the peak memory comes from the line VmHWM" {
    const status = "Name:\tfastest-scan\nVmPeak:\t  900000 kB\nVmHWM:\t  123456 kB\nVmRSS:\t  100000 kB\n";
    try std.testing.expectEqual(@as(?u64, 123456 * 1024), parsePeakMemory(status));
    try std.testing.expectEqual(@as(?u64, null), parsePeakMemory("Name:\tx\n"));
}
