// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! End-to-end dispatch on every compiled-in backend with a device.
const std = @import("std");
const zimt = @import("zimt");
const kernels = @import("test_kernels");

test "saxpy through generated bindings" {
    const allocator = std.testing.allocator;
    var ran = false;
    for ([_]zimt.Backend{ .metal, .cuda }) |b| {
        const dev = zimt.Device.open(allocator, b) catch continue;
        defer dev.close();
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
    try std.testing.expectEqual(@as(u32, 8), K.uniform_size);
    const words = zimt.packUniforms(K, .{ .x = undefined, .y = undefined, .a = 1.5, .n = 7 });
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 1.5))), words[0]);
    try std.testing.expectEqual(@as(u32, 7), words[1]);
}
