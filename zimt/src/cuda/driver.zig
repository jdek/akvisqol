// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! CUDA Driver API wrapper. Declares the needed symbols directly instead of
//! `@cImport(cuda.h)` so the CUDA headers are not a build dependency.
const std = @import("std");

pub const Device = c_int;
pub const Context = ?*anyopaque;
pub const Module = ?*anyopaque;
pub const Function = ?*anyopaque;
pub const Stream = ?*anyopaque;
pub const Event = ?*anyopaque;
pub const DevicePtr = c_ulonglong;

/// Subset of `CUresult`; other codes print numerically.
pub const Result = enum(c_int) {
    success = 0,
    invalid_value = 1,
    out_of_memory = 2,
    not_initialized = 3,
    deinitialized = 4,
    no_device = 100,
    invalid_device = 101,
    invalid_image = 200,
    invalid_context = 201,
    invalid_handle = 400,
    not_found = 500,
    not_ready = 600,
    launch_failed = 700,
    launch_out_of_resources = 701,
    launch_timeout = 702,
    _,

    pub fn name(self: Result) []const u8 {
        return @tagName(self);
    }
};

pub const Error = error{
    DriverError,
};

fn check(r: Result) !void {
    if (r != .success) {
        std.log.err("CUDA driver error: {s} ({d})", .{ r.name(), @backingInt(r) });
        return Error.DriverError;
    }
}

extern fn cuInit(flags: c_uint) Result;
extern fn cuDeviceGet(out: *Device, ordinal: c_int) Result;
extern fn cuDeviceGetCount(out: *c_int) Result;
extern fn cuDeviceGetName(name: [*]u8, len: c_int, dev: Device) Result;
extern fn cuCtxCreate_v2(out: *Context, flags: c_uint, dev: Device) Result;
extern fn cuCtxDestroy_v2(ctx: Context) Result;
extern fn cuCtxSetCurrent(ctx: Context) Result;
extern fn cuCtxGetCurrent(out: *Context) Result;
extern fn cuStreamCreate(out: *Stream, flags: c_uint) Result;
extern fn cuStreamDestroy_v2(stream: Stream) Result;
extern fn cuStreamSynchronize(stream: Stream) Result;
extern fn cuEventCreate(out: *Event, flags: c_uint) Result;
extern fn cuEventDestroy_v2(event: Event) Result;
extern fn cuEventRecord(event: Event, stream: Stream) Result;
extern fn cuEventQuery(event: Event) Result;
extern fn cuEventSynchronize(event: Event) Result;
extern fn cuModuleLoadData(out: *Module, image: *const anyopaque) Result;
extern fn cuModuleUnload(module: Module) Result;
extern fn cuModuleGetFunction(out: *Function, module: Module, name: [*:0]const u8) Result;
extern fn cuMemAlloc_v2(out: *DevicePtr, bytesize: usize) Result;
extern fn cuMemFree_v2(dptr: DevicePtr) Result;
extern fn cuMemcpyHtoD_v2(dst: DevicePtr, src: *const anyopaque, bytes: usize) Result;
extern fn cuMemcpyDtoH_v2(dst: *anyopaque, src: DevicePtr, bytes: usize) Result;
extern fn cuMemcpyDtoD_v2(dst: DevicePtr, src: DevicePtr, bytes: usize) Result;
extern fn cuMemcpyHtoDAsync_v2(dst: DevicePtr, src: *const anyopaque, bytes: usize, stream: Stream) Result;
extern fn cuMemcpyDtoHAsync_v2(dst: *anyopaque, src: DevicePtr, bytes: usize, stream: Stream) Result;
extern fn cuMemsetD8_v2(dst: DevicePtr, val: u8, n: usize) Result;
extern fn cuLaunchKernel(
    f: Function,
    grid_dim_x: c_uint,
    grid_dim_y: c_uint,
    grid_dim_z: c_uint,
    block_dim_x: c_uint,
    block_dim_y: c_uint,
    block_dim_z: c_uint,
    shared_mem_bytes: c_uint,
    stream: Stream,
    kernel_params: ?[*]?*anyopaque,
    extra: ?[*]?*anyopaque,
) Result;

pub fn init() !void {
    try check(cuInit(0));
}

pub fn deviceGet(ordinal: c_int) !Device {
    var d: Device = 0;
    try check(cuDeviceGet(&d, ordinal));
    return d;
}

pub fn deviceCount() !c_int {
    var n: c_int = 0;
    try check(cuDeviceGetCount(&n));
    return n;
}

pub fn deviceName(d: Device, buf: []u8) ![]u8 {
    try check(cuDeviceGetName(buf.ptr, @intCast(buf.len), d));
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

pub fn ctxCreate(d: Device, flags: c_uint) !Context {
    var c: Context = null;
    try check(cuCtxCreate_v2(&c, flags, d));
    return c;
}

pub fn ctxDestroy(c: Context) void {
    _ = cuCtxDestroy_v2(c);
}

/// A context is only current on the thread that created it.
pub fn ctxSetCurrent(c: Context) !void {
    try check(cuCtxSetCurrent(c));
}

pub fn streamCreate() !Stream {
    var s: Stream = null;
    try check(cuStreamCreate(&s, 0));
    return s;
}

pub fn streamDestroy(s: Stream) void {
    _ = cuStreamDestroy_v2(s);
}

pub fn streamSynchronize(s: Stream) !void {
    try check(cuStreamSynchronize(s));
}

/// CU_EVENT_DISABLE_TIMING.
const event_disable_timing: c_uint = 0x2;

pub fn eventRecordNew(s: Stream) !Event {
    var e: Event = null;
    try check(cuEventCreate(&e, event_disable_timing));
    errdefer eventDestroy(e);
    try check(cuEventRecord(e, s));
    return e;
}

pub fn eventDestroy(e: Event) void {
    _ = cuEventDestroy_v2(e);
}

pub fn eventQuery(e: Event) !bool {
    const r = cuEventQuery(e);
    if (r == .not_ready) return false;
    try check(r);
    return true;
}

pub fn eventSynchronize(e: Event) !void {
    try check(cuEventSynchronize(e));
}

/// PTX must be NUL-terminated.
pub fn moduleLoadData(ptx_with_nul: []const u8) !Module {
    var m: Module = null;
    try check(cuModuleLoadData(&m, ptx_with_nul.ptr));
    return m;
}

pub fn moduleUnload(m: Module) void {
    _ = cuModuleUnload(m);
}

pub fn moduleGetFunction(m: Module, name: [*:0]const u8) !Function {
    var f: Function = null;
    try check(cuModuleGetFunction(&f, m, name));
    return f;
}

pub fn memAlloc(bytes: usize) !DevicePtr {
    var p: DevicePtr = 0;
    try check(cuMemAlloc_v2(&p, bytes));
    return p;
}

pub fn memFree(p: DevicePtr) void {
    _ = cuMemFree_v2(p);
}

pub fn memcpyHtoD(dst: DevicePtr, src: []const u8) !void {
    try check(cuMemcpyHtoD_v2(dst, src.ptr, src.len));
}

pub fn memcpyDtoH(dst: []u8, src: DevicePtr) !void {
    try check(cuMemcpyDtoH_v2(dst.ptr, src, dst.len));
}

pub fn memcpyDtoD(dst: DevicePtr, src: DevicePtr, bytes: usize) !void {
    try check(cuMemcpyDtoD_v2(dst, src, bytes));
}

pub fn memsetD8(dst: DevicePtr, val: u8, n: usize) !void {
    try check(cuMemsetD8_v2(dst, val, n));
}

pub fn memcpyHtoDAsync(dst: DevicePtr, src: []const u8, stream: Stream) !void {
    try check(cuMemcpyHtoDAsync_v2(dst, src.ptr, src.len, stream));
}

pub fn memcpyDtoHAsync(dst: []u8, src: DevicePtr, stream: Stream) !void {
    try check(cuMemcpyDtoHAsync_v2(dst.ptr, src, dst.len, stream));
}

/// `params`: pointers to each kernel argument.
pub fn launchKernel(
    f: Function,
    grid: [3]c_uint,
    block: [3]c_uint,
    shared_mem_bytes: c_uint,
    stream: Stream,
    params: []?*anyopaque,
) !void {
    try check(cuLaunchKernel(
        f,
        grid[0],
        grid[1],
        grid[2],
        block[0],
        block[1],
        block[2],
        shared_mem_bytes,
        stream,
        if (params.len == 0) null else params.ptr,
        null,
    ));
}

/// `args`: tuple of pointers to kernel arguments.
pub fn launch(
    f: Function,
    grid: [3]c_uint,
    block: [3]c_uint,
    shared_mem_bytes: c_uint,
    stream: Stream,
    args: anytype,
) !void {
    var ptrs: [args.len]?*anyopaque = undefined;
    inline for (args, 0..) |arg, i| {
        ptrs[i] = @ptrCast(@constCast(arg));
    }
    try launchKernel(f, grid, block, shared_mem_bytes, stream, &ptrs);
}
