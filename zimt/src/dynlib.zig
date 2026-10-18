// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Run-time loading of GPU drivers, so binaries build and load without
//! them. `dlopen` needs libc on Linux.
const std = @import("std");
const builtin = @import("builtin");

pub const Library = if (builtin.os.tag == .windows) struct {
    const HMODULE = *opaque {};
    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?HMODULE;
    extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn FreeLibrary(module: HMODULE) callconv(.winapi) c_int;

    handle: HMODULE,

    pub fn open(name: [*:0]const u8) ?Library {
        return .{ .handle = LoadLibraryA(name) orelse return null };
    }
    pub fn lookup(self: *Library, comptime T: type, name: [*:0]const u8) ?T {
        return @ptrCast(GetProcAddress(self.handle, name) orelse return null);
    }
    pub fn close(self: *Library) void {
        _ = FreeLibrary(self.handle);
    }
} else struct {
    inner: std.DynLib,

    pub fn open(name: [*:0]const u8) ?Library {
        return .{ .inner = std.DynLib.openZ(name) catch return null };
    }
    pub fn lookup(self: *Library, comptime T: type, name: [:0]const u8) ?T {
        return self.inner.lookup(T, name);
    }
    pub fn close(self: *Library) void {
        self.inner.close();
    }
};

pub fn openFirst(names: []const [*:0]const u8) ?struct { Library, [*:0]const u8 } {
    for (names) |n| if (Library.open(n)) |l| return .{ l, n };
    return null;
}

/// `init` once per process; concurrent callers wait for it.
pub fn Once(comptime init: fn () bool) type {
    return struct {
        const State = enum(u8) { unloaded, loading, loaded, failed };
        var state: std.atomic.Value(State) = .init(.unloaded);

        pub fn call() bool {
            if (state.cmpxchgStrong(.unloaded, .loading, .acquire, .acquire) == null) {
                state.store(if (init()) .loaded else .failed, .release);
            }
            while (true) switch (state.load(.acquire)) {
                .loaded => return true,
                .failed => return false,
                .unloaded, .loading => std.atomic.spinLoopHint(),
            };
        }
    };
}
