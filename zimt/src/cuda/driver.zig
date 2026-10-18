// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! CUDA Driver API from cuda.h and cudaTypedefs.h (translate-c); libcuda is
//! loaded at run time and entry points resolved with cuGetProcAddress.
const std = @import("std");
const builtin = @import("builtin");
const dynlib = @import("../dynlib.zig");
pub const c = @import("cuda_c");

fn Pfn(comptime name: []const u8) type {
    return @typeInfo(@field(c, "PFN_" ++ name)).optional.child;
}

/// By unversioned API name, as cuGetProcAddress takes them. Functions with
/// per-thread-stream variants name their default ABI's typedef: cudaTypedefs.h
/// picks it with a macro translate-c can't evaluate.
pub const Api = struct {
    cuInit: Pfn("cuInit"),
    cuGetErrorName: Pfn("cuGetErrorName"),
    cuDeviceGet: Pfn("cuDeviceGet"),
    cuDeviceGetCount: Pfn("cuDeviceGetCount"),
    cuDeviceGetName: Pfn("cuDeviceGetName"),
    cuDevicePrimaryCtxRetain: Pfn("cuDevicePrimaryCtxRetain"),
    cuDevicePrimaryCtxRelease: Pfn("cuDevicePrimaryCtxRelease"),
    cuCtxSetCurrent: Pfn("cuCtxSetCurrent"),
    cuStreamCreate: Pfn("cuStreamCreate"),
    cuStreamDestroy: Pfn("cuStreamDestroy"),
    cuEventCreate: Pfn("cuEventCreate"),
    cuEventDestroy: Pfn("cuEventDestroy"),
    cuEventRecord: Pfn("cuEventRecord_v2000"),
    cuEventQuery: Pfn("cuEventQuery"),
    cuEventSynchronize: Pfn("cuEventSynchronize"),
    cuModuleLoadData: Pfn("cuModuleLoadData"),
    cuModuleUnload: Pfn("cuModuleUnload"),
    cuModuleGetFunction: Pfn("cuModuleGetFunction"),
    cuMemAlloc: Pfn("cuMemAlloc"),
    cuMemFree: Pfn("cuMemFree"),
    cuMemcpyHtoD: Pfn("cuMemcpyHtoD_v3020"),
    cuMemcpyDtoH: Pfn("cuMemcpyDtoH_v3020"),
    cuMemsetD8: Pfn("cuMemsetD8_v3020"),
    cuLaunchKernel: Pfn("cuLaunchKernel_v4000"),
};

pub var api: Api = undefined;

/// The soname, which every driver install has; NixOS keeps it off the
/// loader's search path.
const lib_names: []const [*:0]const u8 = if (builtin.os.tag == .windows)
    &.{"nvcuda.dll"}
else
    &.{ "libcuda.so.1", "/run/opengl-driver/lib/libcuda.so.1" };

/// Needs a CUDA 12 driver (cuGetProcAddress_v2).
fn load() bool {
    var lib, const name = dynlib.openFirst(lib_names) orelse return false;
    const get = lib.lookup(Pfn("cuGetProcAddress"), "cuGetProcAddress_v2") orelse {
        std.log.debug("CUDA driver {s} predates CUDA 12", .{name});
        lib.close();
        return false;
    };
    inline for (@typeInfo(Api).@"struct".field_names) |sym| {
        var p: ?*anyopaque = null;
        var found: c.CUdriverProcAddressQueryResult = undefined;
        if (get(sym, &p, c.CUDA_VERSION, c.CU_GET_PROC_ADDRESS_DEFAULT, &found) != c.CUDA_SUCCESS or p == null) {
            std.log.err("CUDA driver {s} lacks {s}", .{ name, sym });
            lib.close();
            return false;
        }
        @field(api, sym) = @ptrCast(p.?);
    }
    return true;
}

pub const Error = error{
    DriverError,
    /// libcuda is missing or too old.
    DriverNotFound,
};

pub fn init() Error!void {
    if (!dynlib.Once(load).call()) return Error.DriverNotFound;
    try check(api.cuInit(0));
}

pub fn check(r: c.CUresult) Error!void {
    if (r == c.CUDA_SUCCESS) return;
    var s: [*c]const u8 = null;
    _ = api.cuGetErrorName(r, &s);
    std.log.err("CUDA driver error: {s} ({d})", .{ if (s != null) std.mem.span(s) else "unknown", r });
    return Error.DriverError;
}
