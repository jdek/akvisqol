// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! End-to-end dispatch on every compiled-in backend with a device.
const std = @import("std");
const zimt = @import("zimt");
const kernels = @import("test_kernels");

test "saxpy through generated bindings" {
    const allocator = std.testing.allocator;
    var ran = false;
    for (std.enums.values(zimt.Backend)) |b| {
        const dev = zimt.Device.open(allocator, b) catch continue;
        defer dev.close();
        std.debug.print("saxpy: {t} on {s}\n", .{ b, dev.name() });
        const k = try dev.kernel(kernels.saxpy);
        defer dev.release(k);

        const n = 1000;
        var x: [n]f32 = undefined;
        var y: [n]f32 = undefined;
        for (&x, &y, 0..) |*xi, *yi, i| {
            xi.* = @floatFromInt(i);
            yi.* = 1.0;
        }
        const dx = try dev.allocInit(f32, &x);
        defer dev.free(dx);
        const dy = try dev.allocInit(f32, &y);
        defer dev.free(dy);
        // The second submission must see the first's writes.
        try dev.dispatch1d(k, n, .{ .x = dx, .y = dy, .a = 2.0, .n = n - 10 });
        const f1 = try dev.submit();
        try dev.dispatch1d(k, n, .{ .x = dx, .y = dy, .a = 0.5, .n = n - 10 });
        const f2 = try dev.submit();
        try std.testing.expectEqual(f1.value + 1, f2.value);
        try std.testing.expectEqual(f2, try dev.submit());
        try dev.wait(f1);
        try std.testing.expect(try dev.done(f1));
        try dev.wait(f2);
        try dev.wait(f1);
        try std.testing.expect(try dev.done(f2));
        try std.testing.expectEqual(@as(usize, 0), dev.pending.items.len);

        var out: [n]f32 = undefined;
        try dev.download(dy, 0, &out);
        for (out, 0..) |v, i| {
            const want: f32 = if (i < n - 10) 1.0 + 2.5 * @as(f32, @floatFromInt(i)) else 1.0;
            try std.testing.expectEqual(want, v);
        }
        ran = true;
    }
    if (!ran) return error.SkipZigTest;
}

test "bindings carry the reflected layout" {
    const K = kernels.saxpy;
    try std.testing.expectEqual([3]u32{ 32, 1, 1 }, K.threads);
    try std.testing.expectEqual(@as(usize, 4), K.params.len);
    try std.testing.expectEqual(zimt.Access.read, K.params[0].kind.buffer.access);
    try std.testing.expectEqual(zimt.Access.read_write, K.params[1].kind.buffer.access);
    // Two addresses, then the scalars.
    try std.testing.expectEqual(@as(u32, 8), K.params[1].offset);
    try std.testing.expectEqual(@as(u32, 16), K.params[2].offset);
    try std.testing.expectEqual(@as(u32, 20), K.params[3].offset);
    try std.testing.expectEqual(@as(usize, 24), K.arg_size);
    var blk: zimt.Block = .{ .raw = .{ .handle = 0, .host = null, .addr = 0x1000 }, .size = 1 << 20, .kind = .device, .buddy = null };
    const x: zimt.Buffer(f32) = .{ .mem = .{ .block = &blk, .offset = 256, .size = 4 }, .len = 1 };
    const y: zimt.Buffer(f32) = .{ .mem = .{ .block = &blk, .offset = 512, .size = 4 }, .len = 1 };
    const bytes = zimt.packArgs(K, .{ .x = x, .y = y, .a = 1.5, .n = 7 });
    try std.testing.expectEqual(@as(u64, 0x1100), std.mem.readInt(u64, bytes[0..8], .little));
    try std.testing.expectEqual(@as(u64, 0x1200), std.mem.readInt(u64, bytes[8..16], .little));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 1.5))), std.mem.readInt(u32, bytes[16..20], .little));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, bytes[20..24], .little));
}

/// Every compiled-in backend with a device; skips if there are none.
fn eachDevice(comptime body: fn (*zimt.Device) anyerror!void) !void {
    var ran = false;
    for (std.enums.values(zimt.Backend)) |b| {
        const dev = zimt.Device.open(std.testing.allocator, b) catch continue;
        defer dev.close();
        try body(dev);
        ran = true;
    }
    if (!ran) return error.SkipZigTest;
}

test "dispatches beyond 65535 groups" {
    // Past the 65535 groups Vulkan guarantees: dispatch1d folds into rows.
    try eachDevice(struct {
        fn f(dev: *zimt.Device) !void {
            const a = std.testing.allocator;
            const k = try dev.kernel(kernels.saxpy);
            defer dev.release(k);
            const n = 70_000 * 32 + 5;
            const x = try a.alloc(f32, n);
            defer a.free(x);
            for (x, 0..) |*v, i| v.* = @floatFromInt(i % 1024);
            const dx = try dev.allocInit(f32, x);
            defer dev.free(dx);
            const dy = try dev.alloc(f32, .device, n);
            defer dev.free(dy);
            try dev.zero(dy, 0, n);
            try dev.dispatch1d(k, n, .{ .x = dx, .y = dy, .a = 3.0, .n = n });
            try dev.synchronize();
            const out = try a.alloc(f32, n);
            defer a.free(out);
            try dev.download(dy, 0, out);
            for (out, x) |o, xi| try std.testing.expectEqual(3.0 * xi, o);
        }
    }.f);
}

test "tiny buffers and unaligned zero" {
    try eachDevice(struct {
        fn f(dev: *zimt.Device) !void {
            const empty = try dev.alloc(u8, .device, 0);
            dev.free(empty);
            const three = try dev.allocInit(u8, &.{ 1, 2, 3 });
            defer dev.free(three);
            var got3: [3]u8 = undefined;
            try dev.download(three, 0, &got3);
            try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &got3);

            var bytes: [64]u8 = undefined;
            for (&bytes, 0..) |*v, i| v.* = @intCast(i + 1);
            const buf = try dev.allocInit(u8, &bytes);
            defer dev.free(buf);
            // Unaligned ends, then a sub-word span.
            try dev.zero(buf, 3, 50);
            try dev.zero(buf, 57, 2);
            var got: [64]u8 = undefined;
            try dev.download(buf, 0, &got);
            for (got, 0..) |v, i| {
                const zeroed = (i >= 3 and i < 53) or (i >= 57 and i < 59);
                try std.testing.expectEqual(if (zeroed) 0 else bytes[i], v);
            }
        }
    }.f);
}

test "many submissions, fences waited out of order" {
    try eachDevice(struct {
        fn f(dev: *zimt.Device) !void {
            const k = try dev.kernel(kernels.saxpy);
            defer dev.release(k);
            const n = 256;
            const ones: [n]f32 = @splat(1.0);
            const dx = try dev.allocInit(f32, &ones);
            defer dev.free(dx);
            const dy = try dev.alloc(f32, .device, n);
            defer dev.free(dy);
            try dev.zero(dy, 0, n);
            var fences: [150]zimt.Fence = undefined;
            for (&fences, 0..) |*fe, i| {
                try dev.dispatch1d(k, n, .{ .x = dx, .y = dy, .a = 1.0, .n = n });
                fe.* = try dev.submit();
                // Poll and wait on older fences while newer work is queued.
                if (i % 7 == 3) _ = try dev.done(fences[i / 2]);
                if (i % 11 == 5) try dev.wait(fences[i - 3]);
            }
            try dev.wait(fences[100]);
            try std.testing.expect(try dev.done(fences[40]));
            try dev.wait(fences[fences.len - 1]);
            try dev.wait(fences[0]);
            try std.testing.expectEqual(@as(usize, 0), dev.pending.items.len);
            var out: [n]f32 = undefined;
            try dev.download(dy, 0, &out);
            for (out) |v| try std.testing.expectEqual(@as(f32, fences.len), v);
        }
    }.f);
}

test "transfers are ordered with dispatches" {
    try eachDevice(struct {
        fn f(dev: *zimt.Device) !void {
            const k = try dev.kernel(kernels.saxpy);
            defer dev.release(k);
            const n = 4096;
            const ones: [n]f32 = @splat(1.0);
            const twos: [n]f32 = @splat(2.0);
            const dx = try dev.allocInit(f32, &ones);
            defer dev.free(dx);
            const dy = try dev.alloc(f32, .device, n);
            defer dev.free(dy);
            try dev.zero(dy, 0, n);
            // No waits in between.
            try dev.dispatch1d(k, n, .{ .x = dx, .y = dy, .a = 1.0, .n = n }); // y = 1
            try dev.upload(dx, 0, &twos); // x = 2 after it
            try dev.dispatch1d(k, n, .{ .x = dx, .y = dy, .a = 1.0, .n = n }); // y = 3
            try dev.zero(dx, 0, n);
            try dev.dispatch1d(k, n, .{ .x = dx, .y = dy, .a = 1.0, .n = n }); // y = 3
            try dev.upload(dy, 0, ones[0..16]); // y[0..16] = 1
            var out: [n]f32 = undefined;
            try dev.download(dy, 0, &out);
            for (out, 0..) |v, i| try std.testing.expectEqual(@as(f32, if (i < 16) 1.0 else 3.0), v);
        }
    }.f);
}

test "pooled buffers are not reused while in flight" {
    try eachDevice(struct {
        fn f(dev: *zimt.Device) !void {
            const k = try dev.kernel(kernels.saxpy);
            defer dev.release(k);
            const n = 1 << 16;
            const a = std.testing.allocator;
            const xs = try a.alloc(f32, n);
            defer a.free(xs);
            const dy = try dev.alloc(f32, .device, n);
            defer dev.free(dy);
            try dev.zero(dy, 0, n);
            // Frees each input right after queueing the dispatch that reads it.
            for (0..20) |r| {
                @memset(xs, @floatFromInt(r));
                const dx = try dev.allocInit(f32, xs);
                try dev.dispatch1d(k, n, .{ .x = dx, .y = dy, .a = 1.0, .n = n });
                if (r % 3 == 0) _ = try dev.submit();
                dev.free(dx);
            }
            const out = try a.alloc(f32, n);
            defer a.free(out);
            try dev.download(dy, 0, out);
            for (out) |v| try std.testing.expectEqual(@as(f32, 190.0), v); // Σ 0..19
        }
    }.f);
}

test "independent dispatches, then a dependent one" {
    // On Vulkan the first two need no barrier between them.
    try eachDevice(struct {
        fn f(dev: *zimt.Device) !void {
            const k = try dev.kernel(kernels.saxpy);
            defer dev.release(k);
            const n = 2048;
            const ones: [n]f32 = @splat(1.0);
            const dx = try dev.allocInit(f32, &ones);
            defer dev.free(dx);
            const y1 = try dev.allocInit(f32, &ones);
            defer dev.free(y1);
            const y2 = try dev.allocInit(f32, &ones);
            defer dev.free(y2);
            try dev.dispatch1d(k, n, .{ .x = dx, .y = y1, .a = 2.0, .n = n }); // y1 = 3
            try dev.dispatch1d(k, n, .{ .x = dx, .y = y2, .a = 4.0, .n = n }); // y2 = 5
            try dev.dispatch1d(k, n, .{ .x = y1, .y = y2, .a = 10.0, .n = n }); // y2 = 35
            var out: [n]f32 = undefined;
            try dev.download(y2, 0, &out);
            for (out) |v| try std.testing.expectEqual(@as(f32, 35.0), v);
            try dev.download(y1, 0, &out);
            for (out) |v| try std.testing.expectEqual(@as(f32, 3.0), v);
        }
    }.f);
}

test "suballocation: small buffers share a block, big ones get their own" {
    try eachDevice(struct {
        fn f(dev: *zimt.Device) !void {
            const a = std.testing.allocator;
            var bufs: [300]zimt.Buffer(u8) = undefined;
            for (&bufs, 0..) |*b, i| b.* = try dev.alloc(u8, .device, 1000 + i);
            for (bufs[1..]) |b| try std.testing.expectEqual(bufs[0].mem.block, b.mem.block);
            for (bufs) |b| try std.testing.expect(b.mem.offset % zimt.alloc_mod.min_size == 0);

            // Larger than a block: a dedicated one, round-tripping data.
            const n = zimt.Device.blockSize(.device) / 4 + 1000;
            const data = try a.alloc(u32, n);
            defer a.free(data);
            for (data, 0..) |*v, i| v.* = @truncate(i *% 2654435761);
            const big = try dev.allocInit(u32, data);
            try std.testing.expect(big.mem.block != bufs[0].mem.block and big.mem.block.buddy == null);
            try dev.zero(big, 2, 1001);
            const back = try a.alloc(u32, n);
            defer a.free(back);
            try dev.download(big, 0, back);
            @memset(data[2..][0..1001], 0);
            try std.testing.expectEqualSlices(u32, data, back);

            dev.free(big);
            for (bufs) |b| dev.free(b);
            try dev.synchronize();
            // Freed blocks are kept for the next buffers.
            const again = try dev.alloc(u32, .device, n);
            defer dev.free(again);
            try std.testing.expectEqual(big.mem.block, again.mem.block);
            const fresh = try dev.alloc(u8, .device, 64);
            defer dev.free(fresh);
            try std.testing.expectEqual(bufs[0].mem.block, fresh.mem.block);
        }
    }.f);
}

test "idle blocks are kept up to the spare limit" {
    try eachDevice(struct {
        fn f(dev: *zimt.Device) !void {
            dev.spare_limit = zimt.Device.spare_size;
            const bs = zimt.Device.blockSize(.device);
            var bufs: [8]zimt.Buffer(u8) = undefined;
            for (&bufs) |*b| b.* = try dev.alloc(u8, .device, bs + 4096);
            for (bufs) |b| dev.free(b);
            try dev.synchronize();
            const probe = try dev.alloc(u8, .device, 64);
            defer dev.free(probe);
            var idle: usize = 0;
            for (dev.blocks.items) |blk| if (blk.kind == .device and blk.spare) {
                idle += blk.size;
            };
            try std.testing.expect(idle > 0 and idle <= zimt.Device.spare_size);
        }
    }.f);
}

test "readback buffers are host-mapped and written by kernels" {
    try eachDevice(struct {
        fn f(dev: *zimt.Device) !void {
            const k = try dev.kernel(kernels.saxpy);
            defer dev.release(k);
            const n = 3000;
            const ones: [n]f32 = @splat(1.0);
            const dx = try dev.allocInit(f32, &ones);
            defer dev.free(dx);
            const dy = try dev.alloc(f32, .readback, n);
            defer dev.free(dy);
            try std.testing.expect(dy.host() != null);
            try dev.zero(dy, 0, n);
            try dev.dispatch1d(k, n, .{ .x = dx, .y = dy, .a = 5.0, .n = n });
            var out: [n]f32 = undefined;
            try dev.download(dy, 0, &out);
            for (out) |v| try std.testing.expectEqual(@as(f32, 5.0), v);
            try std.testing.expectEqual(@as(f32, 5.0), dy.host().?[n - 1]);
        }
    }.f);
}

test "memory_limit: allocation fails cleanly, then recovers" {
    try eachDevice(struct {
        fn f(dev: *zimt.Device) !void {
            if (dev.budget(.device)) |b| std.debug.print("  budget: {d} of {d} MiB used\n", .{ b.used >> 20, b.limit >> 20 });
            const bs = zimt.Device.blockSize(.device);
            dev.memory_limit = bs + bs / 2;
            defer dev.memory_limit = null;
            const a = try dev.alloc(u8, .device, 1024); // one shared block
            try std.testing.expectError(error.OutOfMemory, dev.alloc(u8, .device, bs + 1)); // would need another
            dev.free(a);
            const big = try dev.alloc(u8, .device, bs);
            dev.free(big);
        }
    }.f);
}

test "arenas free everything together" {
    try eachDevice(struct {
        fn f(dev: *zimt.Device) !void {
            var arena = dev.arena();
            const first = try arena.alloc(u8, .device, 4096);
            _ = try arena.allocInit(u32, &.{ 1, 2, 3 });
            _ = try arena.alloc(f32, .readback, 100);
            arena.deinit();
            try dev.synchronize();
            const again = try dev.alloc(u8, .device, 4096);
            defer dev.free(again);
            try std.testing.expectEqual(first.mem.block, again.mem.block);
            try std.testing.expectEqual(first.mem.offset, again.mem.offset);
        }
    }.f);
}

test "float3 buffers share one layout on every backend" {
    try eachDevice(struct {
        fn f(dev: *zimt.Device) !void {
            const k = try dev.kernel(kernels.scale3);
            defer dev.release(k);
            const n = 1000;
            var v: [n][3]f32 = undefined;
            for (&v, 0..) |*e, i| e.* = .{ @floatFromInt(i), @floatFromInt(i + 1), @floatFromInt(i + 2) };
            const dv = try dev.allocInit([3]f32, &v);
            defer dev.free(dv);
            try dev.dispatch1d(k, n, .{ .v = dv, .s = 2.0, .n = n });
            var out: [n][3]f32 = undefined;
            try dev.download(dv, 0, &out);
            for (out, v) |o, e| try std.testing.expectEqual([3]f32{ e[0] * 2, e[1] * 4, e[2] * 6 }, o);
        }
    }.f);
}

test "indirect dispatch over a list the device built" {
    try eachDevice(struct {
        fn f(dev: *zimt.Device) !void {
            const a = std.testing.allocator;
            const compact = try dev.kernel(kernels.compact);
            defer dev.release(compact);
            const plan = try dev.kernel(kernels.plan);
            defer dev.release(plan);
            const scale = try dev.kernel(kernels.scale_listed);
            defer dev.release(scale);
            // Over 32768 groups of the list: the planned grid folds.
            const n = 4_500_000;
            const x = try a.alloc(f32, n);
            defer a.free(x);
            var prng: std.Random.DefaultPrng = .init(1);
            for (x) |*v| v.* = @floatFromInt(prng.random().intRangeAtMost(i32, -2, 3));
            const dx = try dev.allocInit(f32, x);
            defer dev.free(dx);
            const list = try dev.alloc(u32, .device, n);
            defer dev.free(list);
            const count = try dev.alloc(u32, .device, 1);
            defer dev.free(count);
            const groups = try dev.alloc([3]u32, .device, 2);
            defer dev.free(groups);
            const th = kernels.scale_listed.threads[0];
            // Nothing positive: zero groups.
            const none = try dev.allocInit(f32, &.{ -1, 0, -3 });
            defer dev.free(none);
            try dev.zero(count, 0, 1);
            try dev.dispatch1d(compact, 3, .{ .x = none, .list = list, .count = count, .n = 3 });
            try dev.dispatch(plan, .{ 1, 1, 1 }, .{ .count = count, .groups = groups, .threads_x = th });
            try dev.dispatchIndirect1d(scale, groups, 0, 3, .{ .list = list, .count = count, .x = none, .s = 10 });
            var got3: [3]f32 = undefined;
            try dev.download(none, 0, &got3);
            try std.testing.expectEqualSlices(f32, &.{ -1, 0, -3 }, &got3);

            try dev.zero(count, 0, 1);
            try dev.dispatch1d(compact, n, .{ .x = dx, .list = list, .count = count, .n = n });
            try dev.dispatch(plan, .{ 1, 1, 1 }, .{ .count = count, .groups = groups, .threads_x = th });
            try dev.dispatchIndirect1d(scale, groups, 0, n, .{ .list = list, .count = count, .x = dx, .s = 10 });
            var g: [1][3]u32 = undefined;
            try dev.download(groups, 0, &g);
            var c: [1]u32 = undefined;
            try dev.download(count, 0, &c);
            const want_groups = (c[0] + th - 1) / th;
            try std.testing.expectEqual([3]u32{ zimt.row_groups, (want_groups + zimt.row_groups - 1) / zimt.row_groups, 1 }, g[0]);
            const out = try a.alloc(f32, n);
            defer a.free(out);
            try dev.download(dx, 0, out);
            var positive: u32 = 0;
            for (out, x) |o, v| {
                positive += @intFromBool(v > 0);
                try std.testing.expectEqual(if (v > 0) v * 10 else v, o);
            }
            try std.testing.expectEqual(positive, c[0]);
        }
    }.f);
}
