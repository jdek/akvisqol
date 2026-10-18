// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! CUDA Driver API backend: PTX kernels, one stream per device on the GPU's
//! primary context so devices in a process overlap.
const std = @import("std");
const zimt = @import("root.zig");
const driver = @import("cuda/driver.zig");
const c = driver.c;
const api = &driver.api;

const State = struct {
    device: c.CUdevice,
    context: c.CUcontext,
    stream: c.CUstream,
};

fn state(d: *zimt.Device) *State {
    return @ptrCast(@alignCast(d.state));
}

fn call(r: c.CUresult) !void {
    driver.check(r) catch return zimt.Error.DeviceError;
}

/// Contexts are per thread; bind before every call so devices work across threads.
fn bind(d: *zimt.Device) !void {
    try call(api.cuCtxSetCurrent(state(d).context));
}

pub fn open(d: *zimt.Device) !void {
    driver.init() catch return zimt.Error.BackendUnavailable;
    var n: c_int = 0;
    if (api.cuDeviceGetCount(&n) != c.CUDA_SUCCESS or n == 0) return zimt.Error.BackendUnavailable;
    const st = try d.allocator.create(State);
    errdefer d.allocator.destroy(st);
    st.* = .{ .device = 0, .context = null, .stream = null };
    if (api.cuDeviceGet(&st.device, 0) != c.CUDA_SUCCESS) return zimt.Error.BackendUnavailable;
    if (api.cuDevicePrimaryCtxRetain(&st.context, st.device) != c.CUDA_SUCCESS) return zimt.Error.BackendUnavailable;
    errdefer _ = api.cuDevicePrimaryCtxRelease(st.device);
    try call(api.cuCtxSetCurrent(st.context));
    // Non-blocking: no implicit sync with the legacy default stream.
    try call(api.cuStreamCreate(&st.stream, c.CU_STREAM_NON_BLOCKING));
    d.state = st;
    if (api.cuDeviceGetName(&d.name_buf, d.name_buf.len, st.device) == c.CUDA_SUCCESS)
        d.name_len = std.mem.indexOfScalar(u8, &d.name_buf, 0) orelse d.name_buf.len;
}

pub fn close(d: *zimt.Device) void {
    const st = state(d);
    bind(d) catch {};
    _ = api.cuStreamDestroy(st.stream);
    _ = api.cuDevicePrimaryCtxRelease(st.device);
    d.allocator.destroy(st);
}

pub fn kernel(d: *zimt.Device, comptime K: type, code: []const u8) !zimt.Kernel(K) {
    try bind(d);
    // cuModuleLoadData wants NUL-terminated PTX.
    const z = try d.allocator.alloc(u8, code.len + 1);
    defer d.allocator.free(z);
    @memcpy(z[0..code.len], code);
    z[code.len] = 0;
    var m: c.CUmodule = null;
    try call(api.cuModuleLoadData(&m, z.ptr));
    errdefer _ = api.cuModuleUnload(m);
    var f: c.CUfunction = null;
    if (api.cuModuleGetFunction(&f, m, K.symbol) != c.CUDA_SUCCESS) return zimt.Error.KernelNotFound;
    return .{ .handle = @intFromPtr(f), .module = @intFromPtr(m) };
}

pub fn release(d: *zimt.Device, _: usize, module: usize) void {
    bind(d) catch {};
    _ = api.cuModuleUnload(@ptrFromInt(module));
}

/// Not logged: zimt reclaims and retries.
fn allocCall(r: c.CUresult) !void {
    if (r == c.CUDA_ERROR_OUT_OF_MEMORY) return zimt.Error.OutOfMemory;
    try call(r);
}

/// Readback is mapped page-locked memory kernels write through its device
/// address.
pub fn blockAlloc(d: *zimt.Device, bytes: usize, kind: zimt.BlockKind) !zimt.RawBlock {
    try bind(d);
    if (kind == .device) {
        var p: c.CUdeviceptr = 0;
        try allocCall(api.cuMemAlloc(&p, bytes));
        return .{ .handle = p, .host = null };
    }
    var host: ?*anyopaque = null;
    try allocCall(api.cuMemHostAlloc(&host, bytes, if (kind == .readback) c.CU_MEMHOSTALLOC_DEVICEMAP else 0));
    const h: [*]u8 = @ptrCast(host.?);
    if (kind == .staging) return .{ .handle = @intFromPtr(h), .host = h };
    errdefer _ = api.cuMemFreeHost(host);
    var dp: c.CUdeviceptr = 0;
    try call(api.cuMemHostGetDevicePointer(&dp, host, 0));
    return .{ .handle = dp, .host = h };
}

pub fn blockFree(d: *zimt.Device, blk: *const zimt.Block) void {
    bind(d) catch {};
    _ = switch (blk.kind) {
        .device => api.cuMemFree(blk.raw.handle),
        .staging, .readback => api.cuMemFreeHost(blk.raw.host.?),
    };
}

pub fn budget(d: *zimt.Device, kind: zimt.BlockKind) ?zimt.Budget {
    if (kind != .device) return null;
    bind(d) catch return null;
    var free: usize = 0;
    var total: usize = 0;
    if (api.cuMemGetInfo(&free, &total) != c.CUDA_SUCCESS) return null;
    return .{ .used = total - free, .limit = total };
}

/// zimt copies only between staging and device blocks.
pub fn copy(d: *zimt.Device, src: zimt.Span, dst: zimt.Span) !void {
    try bind(d);
    const stream = state(d).stream;
    try call(if (src.block.kind == .staging)
        api.cuMemcpyHtoDAsync(dst.block.raw.handle + dst.offset, src.block.raw.host.? + src.offset, src.len, stream)
    else
        api.cuMemcpyDtoHAsync(dst.block.raw.host.? + dst.offset, src.block.raw.handle + src.offset, src.len, stream));
}

pub fn fill(d: *zimt.Device, dst: zimt.Span) !void {
    try bind(d);
    try call(api.cuMemsetD8Async(dst.block.raw.handle + dst.offset, 0, dst.len, state(d).stream));
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
            .buffer => {
                // `count` only feeds Slang's optional bounds checks.
                storage[i] = .{ .data = v.mem.block.raw.handle + v.mem.offset, .count = v.len };
                ptrs[i] = @ptrCast(&storage[i]);
            },
            .uniform => {
                storage[i].data = @as(u32, @bitCast(v));
                ptrs[i] = @ptrCast(&storage[i].data);
            },
        }
    }
    const t = K.threads;
    try call(api.cuLaunchKernel(@ptrFromInt(handle), groups[0], groups[1], groups[2], t[0], t[1], t[2], 0, state(d).stream, &ptrs, null));
}

/// A submission is an event recorded on the stream.
pub fn submit(d: *zimt.Device) !usize {
    try bind(d);
    var e: c.CUevent = null;
    try call(api.cuEventCreate(&e, c.CU_EVENT_DISABLE_TIMING));
    errdefer _ = api.cuEventDestroy(e);
    try call(api.cuEventRecord(e, state(d).stream));
    return @intFromPtr(e);
}

/// Destroys the event once complete or failed.
pub fn finish(d: *zimt.Device, handle: usize, block: bool) !bool {
    try bind(d);
    const e: c.CUevent = @ptrFromInt(handle);
    const r = if (block) api.cuEventSynchronize(e) else api.cuEventQuery(e);
    if (r == c.CUDA_ERROR_NOT_READY) return false;
    _ = api.cuEventDestroy(e);
    try call(r);
    return true;
}
