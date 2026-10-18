// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Metal backend over `metal/bridge.m`.
const std = @import("std");
const zimt = @import("root.zig");

const Bridge = opaque {};
extern fn zimt_metal_open(out: *?*Bridge, name: [*]u8, name_len: usize) c_int;
extern fn zimt_metal_close(m: *Bridge) void;
extern fn zimt_metal_library_new(m: *Bridge, bytes: [*]const u8, len: usize, err: [*]u8, err_len: usize) ?*anyopaque;
extern fn zimt_metal_release(obj: *anyopaque) void;
extern fn zimt_metal_pipeline_new(m: *Bridge, lib: *anyopaque, entry: [*:0]const u8, max_threads: *u32, err: [*]u8, err_len: usize) ?*anyopaque;
extern fn zimt_metal_memory(m: *Bridge, used: *u64, limit: *u64) void;
extern fn zimt_metal_buffer_new(m: *Bridge, bytes: usize, contents: *?[*]u8) ?*anyopaque;
extern fn zimt_metal_dispatch(
    m: *Bridge,
    pipeline: *anyopaque,
    buffers: [*]const ?*anyopaque,
    offsets: [*]const usize,
    indices: [*]const u32,
    nbuffers: u32,
    bytes: ?*const anyopaque,
    nbytes: u32,
    bytes_index: u32,
    groups: *const [3]u32,
    threads: *const [3]u32,
) c_int;
extern fn zimt_metal_commit(m: *Bridge) ?*anyopaque;
extern fn zimt_metal_finish(cmdbuf: *anyopaque, block: c_int, err: ?[*]u8, err_len: usize) c_int;

fn bridge(d: *zimt.Device) *Bridge {
    return @ptrCast(d.state);
}

pub fn open(d: *zimt.Device) !void {
    var b: ?*Bridge = null;
    if (zimt_metal_open(&b, &d.name_buf, d.name_buf.len) != 0) return zimt.Error.BackendUnavailable;
    d.state = b.?;
    d.name_len = std.mem.indexOfScalar(u8, &d.name_buf, 0) orelse 0;
}

pub fn close(d: *zimt.Device) void {
    zimt_metal_close(bridge(d));
}

/// `code` is a `.metallib` image, not MSL source.
pub fn kernel(d: *zimt.Device, comptime K: type, code: []const u8) !zimt.Kernel(K) {
    var err: [2048]u8 = @splat(0);
    if (code.len < 4 or !std.mem.eql(u8, code[0..4], "MTLB")) {
        std.log.err("zimt/metal: {s}: code is not a .metallib image", .{K.name});
        return zimt.Error.DeviceError;
    }
    const lib = zimt_metal_library_new(bridge(d), code.ptr, code.len, &err, err.len) orelse {
        std.log.err("zimt/metal: {s}: library load failed: {s}", .{ K.name, std.mem.sliceTo(&err, 0) });
        return zimt.Error.DeviceError;
    };
    errdefer zimt_metal_release(lib);
    var max_threads: u32 = 0;
    const ps = zimt_metal_pipeline_new(bridge(d), lib, K.symbol, &max_threads, &err, err.len) orelse {
        std.log.err("zimt/metal: kernel '{s}': {s}", .{ K.name, std.mem.sliceTo(&err, 0) });
        return zimt.Error.KernelNotFound;
    };
    const want = K.threads[0] * K.threads[1] * K.threads[2];
    if (want > max_threads) {
        zimt_metal_release(ps);
        std.log.err("zimt/metal: kernel '{s}' needs {d} threads/group, device allows {d}", .{ K.name, want, max_threads });
        return zimt.Error.DeviceError;
    }
    return .{ .handle = @intFromPtr(ps), .module = @intFromPtr(lib) };
}

pub fn release(_: *zimt.Device, handle: usize, module: usize) void {
    zimt_metal_release(@ptrFromInt(handle));
    zimt_metal_release(@ptrFromInt(module));
}

/// Shared storage, so zimt never needs `copy` or `fill`.
pub fn blockAlloc(d: *zimt.Device, bytes: usize, _: zimt.BlockKind) !zimt.RawBlock {
    var host: ?[*]u8 = null;
    const b = zimt_metal_buffer_new(bridge(d), bytes, &host) orelse return zimt.Error.OutOfMemory;
    return .{ .handle = @intFromPtr(b), .host = host };
}

pub fn blockFree(_: *zimt.Device, blk: *const zimt.Block) void {
    zimt_metal_release(@ptrFromInt(blk.raw.handle));
}

pub fn budget(d: *zimt.Device, _: zimt.BlockKind) ?zimt.Budget {
    var used: u64 = 0;
    var limit: u64 = 0;
    zimt_metal_memory(bridge(d), &used, &limit);
    return .{ .used = used, .limit = limit };
}

pub fn copy(_: *zimt.Device, _: zimt.Span, _: zimt.Span) !void {
    unreachable;
}

pub fn fill(_: *zimt.Device, _: zimt.Span) !void {
    unreachable;
}

/// Uniforms bind as one constant block at `K.uniform_index`.
pub fn dispatch(d: *zimt.Device, comptime K: type, handle: usize, groups: [3]u32, args: K.Args) !void {
    const n_buf = comptime zimt.bufferCount(K);
    var bufs: [@max(n_buf, 1)]?*anyopaque = undefined;
    var offsets: [@max(n_buf, 1)]usize = undefined;
    const indices = comptime blk: {
        var idx: [@max(n_buf, 1)]u32 = @splat(0);
        var i: usize = 0;
        for (K.params) |p| switch (p.binding) {
            .buffer => |b| {
                idx[i] = b.metal_index;
                i += 1;
            },
            .uniform => {},
        };
        break :blk idx;
    };
    comptime var i: usize = 0;
    inline for (K.params) |p| switch (p.binding) {
        .buffer => {
            const mem = @field(args, p.name).mem;
            bufs[i] = @ptrFromInt(mem.block.raw.handle);
            offsets[i] = mem.offset;
            i += 1;
        },
        .uniform => {},
    };
    const words = zimt.packUniforms(K, args);
    const rc = zimt_metal_dispatch(
        bridge(d),
        @ptrFromInt(handle),
        &bufs,
        &offsets,
        &indices,
        @intCast(n_buf),
        if (K.uniform_size > 0) @ptrCast(&words) else null,
        K.uniform_size,
        K.uniform_index,
        &groups,
        &K.threads,
    );
    if (rc != 0) return zimt.Error.DeviceError;
}

/// Only called after a dispatch, so a command buffer is open.
pub fn submit(d: *zimt.Device) !usize {
    const cb = zimt_metal_commit(bridge(d)) orelse return zimt.Error.DeviceError;
    return @intFromPtr(cb);
}

pub fn finish(_: *zimt.Device, handle: usize, block: bool) !bool {
    var err: [512]u8 = @splat(0);
    return switch (zimt_metal_finish(@ptrFromInt(handle), @intFromBool(block), &err, err.len)) {
        0 => false,
        1 => true,
        else => {
            std.log.err("zimt/metal: command buffer failed: {s}", .{std.mem.sliceTo(&err, 0)});
            return zimt.Error.DeviceError;
        },
    };
}
