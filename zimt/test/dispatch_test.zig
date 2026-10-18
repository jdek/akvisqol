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
        try dev.download(dy, 0, std.mem.sliceAsBytes(&out));
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
    try std.testing.expectEqual(zimt.Access.read, K.params[0].binding.buffer.access);
    try std.testing.expectEqual(zimt.Access.read_write, K.params[1].binding.buffer.access);
    // Metal's uniform block takes buffer index 0; SPIR-V bindings start at 0.
    try std.testing.expectEqual(@as(u32, 1), K.params[0].binding.buffer.metal_index);
    try std.testing.expectEqual(@as(u32, 0), K.params[0].binding.buffer.vk_binding);
    try std.testing.expectEqual(@as(u32, 1), K.params[1].binding.buffer.vk_binding);
    try std.testing.expectEqual(@as(u32, 8), K.uniform_size);
    const words = zimt.packUniforms(K, .{ .x = undefined, .y = undefined, .a = 1.5, .n = 7 });
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 1.5))), words[0]);
    try std.testing.expectEqual(@as(u32, 7), words[1]);
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
            const dy = try dev.alloc(n * 4);
            defer dev.free(dy);
            try dev.zero(dy, 0, n * 4);
            try dev.dispatch1d(k, n, .{ .x = dx, .y = dy, .a = 3.0, .n = n });
            try dev.synchronize();
            const out = try a.alloc(f32, n);
            defer a.free(out);
            try dev.download(dy, 0, std.mem.sliceAsBytes(out));
            for (out, x) |o, xi| try std.testing.expectEqual(3.0 * xi, o);
        }
    }.f);
}

test "tiny buffers and unaligned zero" {
    try eachDevice(struct {
        fn f(dev: *zimt.Device) !void {
            const empty = try dev.alloc(0);
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
            const dy = try dev.alloc(n * 4);
            defer dev.free(dy);
            try dev.zero(dy, 0, n * 4);
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
            try dev.download(dy, 0, std.mem.sliceAsBytes(&out));
            for (out) |v| try std.testing.expectEqual(@as(f32, fences.len), v);
        }
    }.f);
}
