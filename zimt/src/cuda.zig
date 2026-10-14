// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! CUDA Driver API backend: one context and stream per device, kernels from PTX.
const std = @import("std");
const zimt = @import("root.zig");
const driver = @import("cuda/driver.zig");

const State = struct {
    device: driver.Device,
    context: driver.Context,
    stream: driver.Stream,
};

fn state(d: *zimt.Device) *State {
    return @ptrCast(@alignCast(d.state));
}

/// Contexts are per thread; bind before every call so devices work across threads.
fn bind(d: *zimt.Device) !void {
    driver.ctxSetCurrent(state(d).context) catch return zimt.Error.DeviceError;
}

pub fn open(d: *zimt.Device) !void {
    driver.init() catch return zimt.Error.BackendUnavailable;
    const n = driver.deviceCount() catch return zimt.Error.BackendUnavailable;
    if (n == 0) return zimt.Error.BackendUnavailable;
    const st = try d.allocator.create(State);
    errdefer d.allocator.destroy(st);
    st.device = driver.deviceGet(0) catch return zimt.Error.BackendUnavailable;
    st.context = driver.ctxCreate(st.device, 0) catch return zimt.Error.BackendUnavailable;
    errdefer driver.ctxDestroy(st.context);
    st.stream = driver.streamCreate() catch return zimt.Error.DeviceError;
    d.state = st;
    const nm = driver.deviceName(st.device, &d.name_buf) catch d.name_buf[0..0];
    d.name_len = nm.len;
}

pub fn close(d: *zimt.Device) void {
    const st = state(d);
    bind(d) catch {};
    driver.streamDestroy(st.stream);
    driver.ctxDestroy(st.context);
    d.allocator.destroy(st);
}

pub fn kernel(d: *zimt.Device, comptime K: type, code: []const u8) !zimt.Kernel(K) {
    try bind(d);
    // cuModuleLoadData wants NUL-terminated PTX.
    const z = try d.allocator.alloc(u8, code.len + 1);
    defer d.allocator.free(z);
    @memcpy(z[0..code.len], code);
    z[code.len] = 0;
    const m = driver.moduleLoadData(z) catch return zimt.Error.DeviceError;
    errdefer driver.moduleUnload(m);
    const f = driver.moduleGetFunction(m, K.name) catch return zimt.Error.KernelNotFound;
    return .{ .handle = @intFromPtr(f), .module = @intFromPtr(m) };
}

pub fn release(d: *zimt.Device, _: usize, module: usize) void {
    bind(d) catch {};
    driver.moduleUnload(@ptrFromInt(module));
}

pub fn alloc(d: *zimt.Device, bytes: usize) !zimt.Buffer {
    try bind(d);
    const p = driver.memAlloc(@max(bytes, 4)) catch return zimt.Error.OutOfMemory;
    return .{ .handle = p, .size = bytes };
}

pub fn free(d: *zimt.Device, buf: zimt.Buffer) void {
    bind(d) catch {};
    driver.memFree(buf.handle);
}

pub fn upload(d: *zimt.Device, buf: zimt.Buffer, offset: usize, data: []const u8) !void {
    try bind(d);
    driver.memcpyHtoD(buf.handle + offset, data) catch return zimt.Error.DeviceError;
}

pub fn download(d: *zimt.Device, buf: zimt.Buffer, offset: usize, out: []u8) !void {
    try bind(d);
    driver.memcpyDtoH(out, buf.handle + offset) catch return zimt.Error.DeviceError;
}

pub fn zero(d: *zimt.Device, buf: zimt.Buffer, offset: usize, bytes: usize) !void {
    try bind(d);
    driver.memsetD8(buf.handle + offset, 0, bytes) catch return zimt.Error.DeviceError;
}

/// Slang's CUDA `StructuredBuffer<T>` parameter: `{ T* data; size_t count; }`.
const SlangBuffer = extern struct { data: u64, count: usize };

/// Kernel params in declaration order: buffers as `SlangBuffer`, uniforms by value.
pub fn dispatch(d: *zimt.Device, comptime K: type, handle: usize, groups: [3]u32, args: K.Args) !void {
    try bind(d);
    var storage: [K.params.len]SlangBuffer = undefined;
    var ptrs: [K.params.len]?*anyopaque = undefined;
    inline for (K.params, 0..) |p, i| {
        const v = @field(args, p.name);
        switch (p.binding) {
            .buffer => |b| {
                // `count` only feeds Slang's optional bounds checks.
                storage[i] = .{ .data = v.handle, .count = v.size / b.elem_size };
                ptrs[i] = @ptrCast(&storage[i]);
            },
            .uniform => {
                storage[i].data = @as(u32, @bitCast(v));
                ptrs[i] = @ptrCast(&storage[i].data);
            },
        }
    }
    driver.launchKernel(
        @ptrFromInt(handle),
        groups,
        K.threads,
        0,
        state(d).stream,
        &ptrs,
    ) catch return zimt.Error.DeviceError;
}

/// A submission is an event recorded on the stream.
pub fn submit(d: *zimt.Device) !usize {
    try bind(d);
    const e = driver.eventRecordNew(state(d).stream) catch return zimt.Error.DeviceError;
    return @intFromPtr(e);
}

/// Destroys the event once complete or failed.
pub fn finish(d: *zimt.Device, handle: usize, block: bool) !bool {
    try bind(d);
    const e: driver.Event = @ptrFromInt(handle);
    const result: anyerror!void = if (block) driver.eventSynchronize(e) else blk: {
        const finished = driver.eventQuery(e) catch |err| break :blk err;
        if (!finished) return false;
        break :blk {};
    };
    driver.eventDestroy(e);
    result catch return zimt.Error.DeviceError;
    return true;
}
