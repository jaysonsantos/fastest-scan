//! A test helper: make each allocation of a function fail one time, and check that
//! the function then frees all of its memory.
//!
//! `std.testing.checkAllAllocationFailures` does the same, but it needs the same
//! number of allocations in each run. A list that grows gets its memory in place
//! or as a new block, and which one depends on what the allocator did before. So
//! the number of allocations of one function can change from run to run: the
//! duplicate search makes 184 allocations in its first run and 183 in each later
//! one. The check of the standard library then reports
//! `error.NondeterministicMemoryUsage`. This helper has no fixed number: it goes on
//! until a run has no allocation left to fail.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Call `run(allocator, extra_args...)` again and again. In run number N, the
/// allocation number N fails. Such a run must return `error.OutOfMemory`, and it
/// must free all of its memory. The check ends with the first run in which no
/// allocation was left to fail: that run must succeed.
///
/// `backing` gives the memory. When memory stays after an error, the function
/// prints which allocation failed and returns `error.MemoryLeakDetected`.
pub fn eachFailure(backing: Allocator, comptime run: anytype, extra_args: anytype) !void {
    return check(backing, run, extra_args, true);
}

fn check(backing: Allocator, comptime run: anytype, extra_args: anytype, report: bool) !void {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        if (@call(.auto, run, .{failing.allocator()} ++ extra_args)) |_| {
            // The function went on after an allocation failed.
            if (failing.has_induced_failure) return error.SwallowedOutOfMemoryError;
            return;
        } else |err| switch (@as(anyerror, err)) {
            // `anyerror`: the function can have `error.OutOfMemory` as its only error.
            error.OutOfMemory => {
                if (failing.allocated_bytes == failing.freed_bytes) continue;
                if (report) {
                    std.debug.print("\nallocation {d} failed, and {d} bytes stayed. The allocation that failed: {f}", .{
                        fail_index,
                        failing.allocated_bytes - failing.freed_bytes,
                        std.debug.FormatStackTrace{ .stack_trace = failing.getStackTrace() },
                    });
                }
                return error.MemoryLeakDetected;
            },
            else => |other| return other,
        }
    }
}

const testing = std.testing;

const block_bytes = 16;

test "a function that frees its memory on each error passes" {
    const Case = struct {
        fn run(allocator: Allocator, count: usize) !void {
            var blocks: std.ArrayList([]u8) = .empty;
            defer {
                for (blocks.items) |block| allocator.free(block);
                blocks.deinit(allocator);
            }
            for (0..count) |_| {
                const block = try allocator.alloc(u8, block_bytes);
                errdefer allocator.free(block);
                try blocks.append(allocator, block);
            }
        }
    };
    try eachFailure(testing.allocator, Case.run, .{@as(usize, 5)});
}

test "a function that keeps memory after an error is found" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            const first = try allocator.alloc(u8, block_bytes);
            // No `errdefer` for `first`: it stays when the second allocation fails.
            const second = try allocator.alloc(u8, block_bytes);
            allocator.free(second);
            allocator.free(first);
        }
    };
    // The arena takes the memory that the function keeps.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.MemoryLeakDetected, check(arena.allocator(), Case.run, .{}, false));
}

test "a function that goes on after a failed allocation is found" {
    const Case = struct {
        fn run(allocator: Allocator) !void {
            const block = allocator.alloc(u8, block_bytes) catch return;
            allocator.free(block);
        }
    };
    try testing.expectError(error.SwallowedOutOfMemoryError, check(testing.allocator, Case.run, .{}, false));
}

test "the number of allocations can change from run to run" {
    const Case = struct {
        var runs: usize = 0;

        fn run(allocator: Allocator) !void {
            // The first run makes one allocation more than the runs after it.
            const count: usize = if (runs == 0) 3 else 2;
            runs += 1;
            for (0..count) |_| allocator.free(try allocator.alloc(u8, block_bytes));
        }
    };
    try eachFailure(testing.allocator, Case.run, .{});
    try testing.expect(Case.runs > 2);
}
