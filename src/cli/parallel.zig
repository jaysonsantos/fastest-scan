//! Run a list of jobs on several threads.

const std = @import("std");
const Io = std.Io;

/// Call `job(context, worker, index)` for each index below `job_count`, on
/// `worker_count` threads. `worker` is below `worker_count`, and no two jobs with
/// the same `worker` run at the same time: a job can keep state for its worker, for
/// example memory that the next job uses again. The function returns the first
/// error of a job; the other jobs that did not start yet are skipped.
pub fn forEach(
    io: Io,
    worker_count: usize,
    job_count: usize,
    context: anytype,
    comptime job: fn (@TypeOf(context), usize, usize) anyerror!void,
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

        fn work(shared: *@This(), worker: usize) void {
            while (!shared.failed.load(.acquire)) {
                const index = shared.next.fetchAdd(1, .monotonic);
                if (index >= shared.job_count) return;
                job(shared.context, worker, index) catch |err| {
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
    for (0..extra_workers) |extra| {
        // When the system gives no more threads, the calling thread does the rest.
        group.concurrent(io, Shared.work, .{ &shared, extra + 1 }) catch break;
    }
    // The calling thread is worker 0.
    shared.work(0);
    group.await(io) catch {};
    if (shared.first_error) |err| return err;
}

const testing = std.testing;

test "every job runs one time" {
    const job_count = 100;
    var done: [job_count]std.atomic.Value(u32) = @splat(.init(0));
    const Context = struct {
        done: []std.atomic.Value(u32),
        fn job(self: @This(), _: usize, index: usize) anyerror!void {
            _ = self.done[index].fetchAdd(1, .monotonic);
        }
    };
    try forEach(testing.io, 4, job_count, Context{ .done = &done }, Context.job);
    for (&done) |*count| try testing.expectEqual(@as(u32, 1), count.load(.monotonic));
}

test "each worker runs one job at a time" {
    const worker_count = 4;
    const job_count = 200;
    var busy: [worker_count]std.atomic.Value(u32) = @splat(.init(0));
    const Context = struct {
        busy: []std.atomic.Value(u32),
        fn job(self: @This(), worker: usize, _: usize) anyerror!void {
            if (worker >= self.busy.len) return error.WorkerOutOfRange;
            if (self.busy[worker].fetchAdd(1, .acq_rel) != 0) return error.WorkerSharedByTwoJobs;
            // Some work, so that the jobs of the workers overlap.
            var sum: u32 = 0;
            for (0..1000) |value| sum +%= @intCast(value);
            std.mem.doNotOptimizeAway(sum);
            _ = self.busy[worker].fetchSub(1, .acq_rel);
        }
    };
    try forEach(testing.io, worker_count, job_count, Context{ .busy = &busy }, Context.job);
}

test "the first error comes back" {
    const Context = struct {
        fn job(_: @This(), _: usize, index: usize) anyerror!void {
            if (index == 3) return error.JobFailed;
        }
    };
    try testing.expectError(error.JobFailed, forEach(testing.io, 2, 8, Context{}, Context.job));
}
