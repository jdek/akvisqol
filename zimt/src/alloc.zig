// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Buddy suballocation of device memory blocks; requests larger than a
//! block get one of their own.
const std = @import("std");

/// Smallest class, so also the offset alignment: Vulkan guarantees
/// `minStorageBufferOffsetAlignment <= 256`.
pub const min_size: usize = 256;
/// At most Vulkan's guaranteed `maxStorageBufferRange` (2^27).
pub const max_block_size: usize = 64 << 20;
/// Level 0 is a whole block, the last a `min_size` node.
const max_levels = std.math.log2_int(usize, max_block_size / min_size) + 1;

comptime {
    std.debug.assert(std.math.isPowerOfTwo(min_size) and std.math.isPowerOfTwo(max_block_size));
    std.debug.assert(max_block_size <= 1 << 27);
    // Offsets in `min_size` units fit the free lists' u32.
    std.debug.assert(max_block_size / min_size <= std.math.maxInt(u32));
}

pub fn sizeClass(bytes: usize) usize {
    return std.math.ceilPowerOfTwo(usize, @max(bytes, min_size)) catch std.math.maxInt(usize);
}

/// Free nodes of one block per level, in `min_size` units. A node's buddy
/// is at its offset XOR its size; freed buddies merge.
pub const Buddy = struct {
    free: [max_levels]std.ArrayList(u32),
    block_size: usize,
    used: usize = 0,

    pub fn init(a: std.mem.Allocator, block_size: usize) !Buddy {
        std.debug.assert(std.math.isPowerOfTwo(block_size) and block_size >= min_size and block_size <= max_block_size);
        var b: Buddy = .{ .free = @splat(.empty), .block_size = block_size };
        try b.reserve(a);
        b.free[0].appendAssumeCapacity(0);
        return b;
    }

    fn levelOf(self: *const Buddy, class: usize) usize {
        return std.math.log2_int(usize, self.block_size / class);
    }

    fn nodeSize(self: *const Buddy, level: usize) usize {
        return self.block_size >> @intCast(level);
    }

    pub fn deinit(self: *Buddy, a: std.mem.Allocator) void {
        for (&self.free) |*l| l.deinit(a);
    }

    /// So `release`, which pushes at most one node, never allocates.
    fn reserve(self: *Buddy, a: std.mem.Allocator) !void {
        for (&self.free) |*l| try l.ensureUnusedCapacity(a, 2);
    }

    pub fn take(self: *Buddy, a: std.mem.Allocator, class: usize) !?usize {
        std.debug.assert(class >= min_size and class <= self.block_size and std.math.isPowerOfTwo(class));
        try self.reserve(a);
        const want = self.levelOf(class);
        var level = want + 1;
        const off = while (level > 0) {
            level -= 1;
            if (self.free[level].pop()) |o| break o;
        } else return null;
        // Split down, keeping the upper halves.
        while (level < want) {
            level += 1;
            self.free[level].appendAssumeCapacity(off + @as(u32, @intCast(self.nodeSize(level) / min_size)));
        }
        self.used += class;
        return @as(usize, off) * min_size;
    }

    pub fn release(self: *Buddy, offset: usize, class: usize) void {
        var level = self.levelOf(class);
        var off: u32 = @intCast(offset / min_size);
        self.used -= class;
        while (level > 0) : (level -= 1) {
            const buddy = off ^ @as(u32, @intCast(self.nodeSize(level) / min_size));
            const i = std.mem.indexOfScalar(u32, self.free[level].items, buddy) orelse break;
            _ = self.free[level].swapRemove(i);
            off = @min(off, buddy);
        }
        self.free[level].appendAssumeCapacity(off);
    }

    pub fn empty(self: *const Buddy) bool {
        return self.used == 0;
    }
};

test "sizeClass" {
    try std.testing.expectEqual(min_size, sizeClass(0));
    try std.testing.expectEqual(min_size, sizeClass(256));
    try std.testing.expectEqual(@as(usize, 512), sizeClass(257));
    try std.testing.expectEqual(max_block_size, sizeClass(max_block_size));
}

test "buddy: splits, aligns, merges back to one block" {
    const a = std.testing.allocator;
    for ([_]usize{ max_block_size, 8 << 20 }) |block_size| try churn(a, block_size);
}

fn churn(a: std.mem.Allocator, block_size: usize) !void {
    var b = try Buddy.init(a, block_size);
    defer b.deinit(a);
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    const Live = struct { off: usize, class: usize };
    var live: std.ArrayList(Live) = .empty;
    defer live.deinit(a);
    for (0..4000) |_| {
        if (live.items.len > 0 and r.boolean()) {
            const x = live.swapRemove(r.uintLessThan(usize, live.items.len));
            b.release(x.off, x.class);
            continue;
        }
        const class = sizeClass(r.uintLessThan(usize, block_size / 64));
        const off = (try b.take(a, class)) orelse continue;
        try std.testing.expect(off % class == 0 and off + class <= block_size);
        for (live.items) |x| try std.testing.expect(off + class <= x.off or x.off + x.class <= off);
        try live.append(a, .{ .off = off, .class = class });
    }
    for (live.items) |x| b.release(x.off, x.class);
    try std.testing.expect(b.empty());
    try std.testing.expectEqual(@as(usize, 1), b.free[0].items.len);
    try std.testing.expectEqual(@as(?usize, 0), try b.take(a, block_size));
    try std.testing.expectEqual(@as(?usize, null), try b.take(a, min_size));
}
