//! Run a list of jobs on several threads.

const std = @import("std");
const Io = std.Io;

/// Call `job(context, index)` for each index below `job_count`, on `worker_count`
/// threads. The function returns the first error of a job; the other jobs that did
/// not start yet are skipped.
pub fn forEach(
    io: Io,
    worker_count: usize,
    job_count: usize,
    context: anytype,
    comptime job: fn (@TypeOf(context), usize) anyerror!void,
) anyerror!void {
    const Context = @TypeOf(context);
    const Shared = struct {
        context: Context,
        job_count: usize,
        next: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        mutex: Io.Mutex = .init,
        first_error: ?anyerror = null,
        io: Io,

        fn work(shared: *@This()) void {
            while (!shared.failed.load(.acquire)) {
                const index = shared.next.fetchAdd(1, .monotonic);
                if (index >= shared.job_count) return;
                job(shared.context, index) catch |err| {
                    shared.mutex.lockUncancelable(shared.io);
                    defer shared.mutex.unlock(shared.io);
                    if (shared.first_error == null) shared.first_error = err;
                    shared.failed.store(true, .release);
                };
            }
        }
    };

    var shared: Shared = .{ .context = context, .job_count = job_count, .io = io };
    var group: Io.Group = .init;
    const extra_workers = @max(1, @min(worker_count, job_count)) - 1;
    for (0..extra_workers) |_| {
        // When the system gives no more threads, the calling thread does the rest.
        group.concurrent(io, Shared.work, .{&shared}) catch break;
    }
    shared.work();
    group.await(io) catch {};
    if (shared.first_error) |err| return err;
}

const testing = std.testing;

test "every job runs one time" {
    const job_count = 100;
    var done: [job_count]std.atomic.Value(u32) = @splat(.init(0));
    const Context = struct {
        done: []std.atomic.Value(u32),
        fn job(self: @This(), index: usize) anyerror!void {
            _ = self.done[index].fetchAdd(1, .monotonic);
        }
    };
    try forEach(testing.io, 4, job_count, Context{ .done = &done }, Context.job);
    for (&done) |*count| try testing.expectEqual(@as(u32, 1), count.load(.monotonic));
}

test "the first error comes back" {
    const Context = struct {
        fn job(_: @This(), index: usize) anyerror!void {
            if (index == 3) return error.JobFailed;
        }
    };
    try testing.expectError(error.JobFailed, forEach(testing.io, 2, 8, Context{}, Context.job));
}
