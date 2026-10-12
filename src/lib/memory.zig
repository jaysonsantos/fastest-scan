//! Working memory for a thread that does the same kind of job many times.
//!
//! The render of a page takes many large blocks: the frames, the page of each
//! frame, the planes for the registration. A general allocator takes each large
//! block from the system and gives it back when the caller frees it. The system
//! clears the pages of a block before the first write, and it does that again for
//! each new block. On the benchmark video, that was 5.8 million page faults and
//! 21 s of system time.
//!
//! `BlockCache` keeps the large blocks that the caller frees and gives them to the
//! next requests of the same size. The pages of one document have one size, so the
//! same sizes come again and again.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// An allocator on top of `child` that keeps each large block that the caller
/// frees, for the next request of the same size and alignment. A smaller request
/// goes to `child` with no change.
///
/// One thread uses one cache: the cache has no lock. Free a block with the cache
/// that gave it. The content of a block from the cache is that of its last use,
/// which agrees with the contract of `Allocator.alloc`: new memory is undefined.
pub const BlockCache = struct {
    child: Allocator,
    blocks: [max_blocks]Block = undefined,
    count: usize = 0,
    /// The number of blocks that came into the cache. It gives each block its age.
    clock: u64 = 0,
    stats: Stats = .{},

    /// A request of fewer bytes than this goes to the child allocator. The value is
    /// the size at which `std.heap.smp_allocator` starts to take each block from
    /// the system; below it, that allocator has lists of its own.
    pub const min_cached_bytes = 64 * 1024;
    /// The largest number of blocks that wait in the cache. One render job with
    /// nine donor frames has fewer than 100 large blocks.
    pub const max_blocks = 256;

    pub const Stats = struct {
        /// Large blocks from the child allocator, and their bytes.
        fresh_blocks: u64 = 0,
        fresh_bytes: u64 = 0,
        /// Large requests that got a block of the cache.
        reused_blocks: u64 = 0,
        /// Blocks that went back to the child allocator because the cache was full.
        dropped_blocks: u64 = 0,

        pub fn add(self: *Stats, other: Stats) void {
            self.fresh_blocks += other.fresh_blocks;
            self.fresh_bytes += other.fresh_bytes;
            self.reused_blocks += other.reused_blocks;
            self.dropped_blocks += other.dropped_blocks;
        }
    };

    const Block = struct {
        memory: []u8,
        alignment: Alignment,
        /// The value of `clock` when the block came into the cache.
        freed_at: u64,
    };

    pub fn init(child: Allocator) BlockCache {
        return .{ .child = child };
    }

    /// Give all blocks that wait in the cache back to the child allocator.
    pub fn deinit(self: *BlockCache) void {
        self.release();
        self.* = undefined;
    }

    /// Give all blocks that wait in the cache back to the child allocator. The
    /// cache stays in use.
    pub fn release(self: *BlockCache) void {
        for (self.blocks[0..self.count]) |block| self.child.rawFree(block.memory, block.alignment, @returnAddress());
        self.count = 0;
    }

    pub fn allocator(self: *BlockCache) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
        const self: *BlockCache = @ptrCast(@alignCast(context));
        if (len < min_cached_bytes) return self.child.rawAlloc(len, alignment, return_address);

        // The block that was in use last is the one that the CPU cache still holds.
        var newest: ?usize = null;
        for (self.blocks[0..self.count], 0..) |block, index| {
            if (block.memory.len != len or block.alignment != alignment) continue;
            if (newest == null or block.freed_at > self.blocks[newest.?].freed_at) newest = index;
        }
        if (newest) |index| {
            const memory = self.blocks[index].memory;
            self.remove(index);
            self.stats.reused_blocks += 1;
            return memory.ptr;
        }

        const fresh = self.child.rawAlloc(len, alignment, return_address) orelse retry: {
            // The system has no more memory: give back what waits here, and try again.
            if (self.count == 0) return null;
            self.release();
            break :retry self.child.rawAlloc(len, alignment, return_address) orelse return null;
        };
        self.stats.fresh_blocks += 1;
        self.stats.fresh_bytes += len;
        return fresh;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, return_address: usize) bool {
        const self: *BlockCache = @ptrCast(@alignCast(context));
        return self.child.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *BlockCache = @ptrCast(@alignCast(context));
        return self.child.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, return_address: usize) void {
        const self: *BlockCache = @ptrCast(@alignCast(context));
        if (memory.len < min_cached_bytes) return self.child.rawFree(memory, alignment, return_address);

        if (self.count == max_blocks) {
            // The block that waits for the longest time has a size that does not come again.
            var oldest: usize = 0;
            for (self.blocks[1..self.count], 1..) |block, index| {
                if (block.freed_at < self.blocks[oldest].freed_at) oldest = index;
            }
            const dropped = self.blocks[oldest];
            self.remove(oldest);
            self.child.rawFree(dropped.memory, dropped.alignment, return_address);
            self.stats.dropped_blocks += 1;
        }
        self.blocks[self.count] = .{ .memory = memory, .alignment = alignment, .freed_at = self.clock };
        self.count += 1;
        self.clock += 1;
    }

    fn remove(self: *BlockCache, index: usize) void {
        self.count -= 1;
        self.blocks[index] = self.blocks[self.count];
    }
};

const testing = std.testing;

const test_block_bytes = 2 * BlockCache.min_cached_bytes;

test "a large block that the caller frees comes back for the next request of its size" {
    var cache: BlockCache = .init(testing.allocator);
    defer cache.deinit();
    const memory = cache.allocator();

    const first = try memory.alloc(u8, test_block_bytes);
    const address = first.ptr;
    memory.free(first);
    try testing.expectEqual(@as(usize, 1), cache.count);

    const second = try memory.alloc(u8, test_block_bytes);
    defer memory.free(second);
    try testing.expectEqual(address, second.ptr);
    try testing.expectEqual(@as(usize, 0), cache.count);
    try testing.expectEqual(@as(u64, 1), cache.stats.fresh_blocks);
    try testing.expectEqual(@as(u64, test_block_bytes), cache.stats.fresh_bytes);
    try testing.expectEqual(@as(u64, 1), cache.stats.reused_blocks);
}

test "a small block does not stay in the cache" {
    var cache: BlockCache = .init(testing.allocator);
    defer cache.deinit();
    const memory = cache.allocator();

    const small = try memory.alloc(u8, BlockCache.min_cached_bytes - 1);
    memory.free(small);
    try testing.expectEqual(@as(usize, 0), cache.count);
    try testing.expectEqual(@as(u64, 0), cache.stats.fresh_blocks);
}

test "a request of another size or another alignment gets a fresh block" {
    var cache: BlockCache = .init(testing.allocator);
    defer cache.deinit();
    const memory = cache.allocator();

    memory.free(try memory.alloc(u8, test_block_bytes));
    const other_size = try memory.alloc(u8, test_block_bytes + 1);
    defer memory.free(other_size);
    const other_alignment = try memory.alloc(u64, test_block_bytes / @sizeOf(u64));
    defer memory.free(other_alignment);

    try testing.expectEqual(@as(usize, 1), cache.count);
    try testing.expectEqual(@as(u64, 3), cache.stats.fresh_blocks);
    try testing.expectEqual(@as(u64, 0), cache.stats.reused_blocks);
}

test "of two blocks of one size, the request gets the one that the caller freed last" {
    var cache: BlockCache = .init(testing.allocator);
    defer cache.deinit();
    const memory = cache.allocator();

    const first = try memory.alloc(u8, test_block_bytes);
    const second = try memory.alloc(u8, test_block_bytes);
    const last_address = first.ptr;
    memory.free(second);
    memory.free(first);

    const again = try memory.alloc(u8, test_block_bytes);
    defer memory.free(again);
    try testing.expectEqual(last_address, again.ptr);
}

test "a full cache gives its oldest block back to the child allocator" {
    var cache: BlockCache = .init(testing.allocator);
    defer cache.deinit();
    const memory = cache.allocator();

    // Each block has its own size, so no request takes a block out of the cache.
    for (0..BlockCache.max_blocks + 1) |index| {
        memory.free(try memory.alloc(u8, test_block_bytes + index));
    }
    try testing.expectEqual(@as(usize, BlockCache.max_blocks), cache.count);
    try testing.expectEqual(@as(u64, 1), cache.stats.dropped_blocks);

    // The first size left the cache; the second size is still there.
    const first_size = try memory.alloc(u8, test_block_bytes);
    defer memory.free(first_size);
    const second_size = try memory.alloc(u8, test_block_bytes + 1);
    defer memory.free(second_size);
    try testing.expectEqual(@as(u64, BlockCache.max_blocks + 2), cache.stats.fresh_blocks);
    try testing.expectEqual(@as(u64, 1), cache.stats.reused_blocks);
}

test "a list that grows through the cache keeps its items" {
    var cache: BlockCache = .init(testing.allocator);
    defer cache.deinit();
    const memory = cache.allocator();

    // Two rounds: the second one grows through the blocks that the first one freed.
    for (0..2) |_| {
        var list: std.ArrayList(u32) = .empty;
        defer list.deinit(memory);
        const item_count = 4 * BlockCache.min_cached_bytes / @sizeOf(u32);
        for (0..item_count) |index| try list.append(memory, @intCast(index));
        for (list.items, 0..) |item, index| try testing.expectEqual(@as(u32, @intCast(index)), item);
    }
}

test "release gives all blocks back and the cache stays in use" {
    var cache: BlockCache = .init(testing.allocator);
    defer cache.deinit();
    const memory = cache.allocator();

    memory.free(try memory.alloc(u8, test_block_bytes));
    cache.release();
    try testing.expectEqual(@as(usize, 0), cache.count);
    memory.free(try memory.alloc(u8, test_block_bytes));
    try testing.expectEqual(@as(u64, 2), cache.stats.fresh_blocks);
}
