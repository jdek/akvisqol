// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Compute runtime for Slang kernels on Metal, CUDA and Vulkan. Kernel bindings are
//! generated from Slang reflection; argument layout is resolved at comptime.
//!
//! Dispatches run in submission order, each seeing the previous one's writes.
//! `upload`/`download`/`zero` wait for all submitted work first.
const std = @import("std");
const options = @import("zimt_options");

pub const metal = if (options.metal) @import("metal.zig") else struct {};
pub const cuda = if (options.cuda) @import("cuda.zig") else struct {};
pub const vulkan = if (options.vulkan) @import("vulkan.zig") else struct {};

pub const Backend = enum { metal, cuda, vulkan };

pub const Error = error{ BackendUnavailable, DeviceError, KernelNotFound, OutOfMemory };

pub fn compiledIn(b: Backend) bool {
    return switch (b) {
        .metal => options.metal,
        .cuda => options.cuda,
        .vulkan => options.vulkan,
    };
}

/// The only compiled-in backend, if there is exactly one.
const only: ?Backend = blk: {
    var one: ?Backend = null;
    for (std.enums.values(Backend)) |b| if (compiledIn(b)) {
        if (one != null) break :blk null;
        one = b;
    };
    break :blk one;
};

fn impl(comptime b: Backend) type {
    return switch (b) {
        .metal => metal,
        .cuda => cuda,
        .vulkan => vulkan,
    };
}

pub const Buffer = struct {
    /// Metal: retained `id<MTLBuffer>`; CUDA: `CUdeviceptr`; Vulkan: a
    /// backend record (buffer, memory, mapping).
    handle: usize,
    size: usize,
    /// Host mapping for Metal shared storage and host-visible Vulkan memory;
    /// null on CUDA and for Vulkan device-local memory.
    host: ?[*]u8 = null,
};

pub const Access = enum { read, write, read_write };

/// One entry-point parameter, as reflected by Slang.
pub const Param = struct {
    name: []const u8,
    binding: union(enum) {
        /// `access` orders Vulkan commands; `stride` must match the `Args`
        /// field's element (`checkDef`).
        buffer: struct { metal_index: u32, vk_binding: u32, access: Access, elem_size: u32 },
        uniform: struct { offset: u32, size: u32 },
    },
};

fn checkDef(comptime K: type) void {
    inline for (.{ "name", "symbol", "threads", "metal", "ptx", "spirv", "Args", "params", "uniform_size", "uniform_index" }) |decl| {
        if (!@hasDecl(K, decl)) @compileError(@typeName(K) ++ " is not a zimt kernel (missing `" ++ decl ++ "`)");
    }
}

pub fn Kernel(comptime K: type) type {
    comptime checkDef(K);
    return struct {
        pub const Def = K;
        /// Metal: retained `id<MTLComputePipelineState>`; CUDA: `CUfunction`;
        /// Vulkan: a backend record (pipeline and layouts).
        handle: usize,
        module: usize,
    };
}

/// `ZIMT_ROW_GROUPS` in zimt.slang; within Vulkan's guaranteed 65535.
pub const row_groups: u32 = 32768;

/// A point on the device's submission timeline.
pub const Fence = struct { value: u64 };

/// `handle`: retained `id<MTLCommandBuffer>` on Metal, `CUevent` on CUDA,
/// a command buffer and timeline value on Vulkan.
const Pending = struct { value: u64, handle: usize };

pub const Device = struct {
    backend: Backend,
    allocator: std.mem.Allocator,
    state: *anyopaque,
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    submitted: u64 = 0,
    completed: u64 = 0,
    /// Work enqueued since the last submit.
    dirty: bool = false,
    /// Oldest first.
    pending: std.ArrayList(Pending) = .empty,

    /// Comptime-known when only one backend is compiled in.
    inline fn which(self: *const Device) Backend {
        return only orelse self.backend;
    }

    pub fn open(allocator: std.mem.Allocator, backend: Backend) !*Device {
        if (!compiledIn(backend)) return Error.BackendUnavailable;
        const self = try allocator.create(Device);
        errdefer allocator.destroy(self);
        self.* = .{ .backend = backend, .allocator = allocator, .state = undefined };
        switch (backend) {
            inline else => |b| if (comptime compiledIn(b)) try impl(b).open(self) else unreachable,
        }
        return self;
    }

    pub fn probe(allocator: std.mem.Allocator, backend: Backend) bool {
        const d = open(allocator, backend) catch return false;
        d.close();
        return true;
    }

    pub fn close(self: *Device) void {
        self.synchronize() catch {};
        self.pending.deinit(self.allocator);
        switch (self.which()) {
            inline else => |b| if (comptime compiledIn(b)) impl(b).close(self) else unreachable,
        }
        self.allocator.destroy(self);
    }

    pub fn name(self: *const Device) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn kernel(self: *Device, comptime K: type) !Kernel(K) {
        switch (self.which()) {
            inline else => |b| {
                if (comptime !compiledIn(b)) unreachable;
                const code: []const u8 = @field(K, @tagName(code_decl.get(b)));
                if (code.len == 0) return Error.BackendUnavailable;
                return impl(b).kernel(self, K, code);
            },
        }
    }

    const code_decl = std.EnumArray(Backend, enum { metal, ptx, spirv }).init(.{ .metal = .metal, .cuda = .ptx, .vulkan = .spirv });

    pub fn release(self: *Device, k: anytype) void {
        switch (self.which()) {
            inline else => |b| if (comptime compiledIn(b)) impl(b).release(self, k.handle, k.module) else unreachable,
        }
    }

    pub fn alloc(self: *Device, bytes: usize) !Buffer {
        return switch (self.which()) {
            inline else => |b| if (comptime compiledIn(b)) impl(b).alloc(self, bytes) else unreachable,
        };
    }

    pub fn allocInit(self: *Device, comptime T: type, data: []const T) !Buffer {
        const b = try self.alloc(@max(1, data.len) * @sizeOf(T));
        errdefer self.free(b);
        try self.upload(b, 0, std.mem.sliceAsBytes(data));
        return b;
    }

    pub fn free(self: *Device, buf: Buffer) void {
        switch (self.which()) {
            inline else => |b| if (comptime compiledIn(b)) impl(b).free(self, buf) else unreachable,
        }
    }

    pub fn upload(self: *Device, buf: Buffer, offset: usize, data: []const u8) !void {
        std.debug.assert(offset + data.len <= buf.size);
        try self.synchronize();
        return switch (self.which()) {
            inline else => |b| if (comptime compiledIn(b)) impl(b).upload(self, buf, offset, data) else unreachable,
        };
    }

    pub fn download(self: *Device, buf: Buffer, offset: usize, out: []u8) !void {
        std.debug.assert(offset + out.len <= buf.size);
        try self.synchronize();
        return switch (self.which()) {
            inline else => |b| if (comptime compiledIn(b)) impl(b).download(self, buf, offset, out) else unreachable,
        };
    }

    pub fn zero(self: *Device, buf: Buffer, offset: usize, bytes: usize) !void {
        std.debug.assert(offset + bytes <= buf.size);
        try self.synchronize();
        return switch (self.which()) {
            inline else => |b| if (comptime compiledIn(b)) impl(b).zero(self, buf, offset, bytes) else unreachable,
        };
    }

    /// Enqueue `k` over `groups` thread groups of `[numthreads]`.
    pub fn dispatch(self: *Device, k: anytype, groups: [3]u32, args: @TypeOf(k).Def.Args) !void {
        if (groups[0] == 0 or groups[1] == 0 or groups[2] == 0) return;
        switch (self.which()) {
            inline else => |b| if (comptime compiledIn(b)) try impl(b).dispatch(self, @TypeOf(k).Def, k.handle, groups, args) else unreachable,
        }
        self.dirty = true;
    }

    /// Folds into rows of `row_groups` groups; kernels index with `zimt_index`.
    pub fn dispatch1d(self: *Device, k: anytype, n: usize, args: @TypeOf(k).Def.Args) !void {
        const tx = @TypeOf(k).Def.threads[0];
        const g = std.math.divCeil(usize, n, tx) catch unreachable;
        if (g <= row_groups) return self.dispatch(k, .{ @intCast(g), 1, 1 }, args);
        const rows = std.math.divCeil(usize, g, row_groups) catch unreachable;
        return self.dispatch(k, .{ row_groups, std.math.cast(u32, rows) orelse return Error.DeviceError, 1 }, args);
    }

    /// Non-blocking. Returns the latest fence if nothing new was enqueued.
    /// Retires completed submissions, so earlier errors may surface here.
    pub fn submit(self: *Device) !Fence {
        try self.retire(self.completed, false);
        if (!self.dirty) return .{ .value = self.submitted };
        try self.pending.ensureUnusedCapacity(self.allocator, 1);
        const handle = switch (self.which()) {
            inline else => |b| if (comptime compiledIn(b)) try impl(b).submit(self) else unreachable,
        };
        self.dirty = false;
        self.submitted += 1;
        self.pending.appendAssumeCapacity(.{ .value = self.submitted, .handle = handle });
        return .{ .value = self.submitted };
    }

    pub fn wait(self: *Device, fence: Fence) !void {
        std.debug.assert(fence.value <= self.submitted);
        try self.retire(fence.value, true);
    }

    pub fn done(self: *Device, fence: Fence) !bool {
        try self.retire(fence.value, false);
        return fence.value <= self.completed;
    }

    /// Retires through `upto` (blocking if `block`), then any later ones
    /// already complete. Returns the first failure.
    fn retire(self: *Device, upto: u64, block: bool) !void {
        var first_err: ?anyerror = null;
        var n: usize = 0;
        for (self.pending.items) |p| {
            const must = block and p.value <= upto;
            const finished = switch (self.which()) {
                inline else => |b| if (comptime compiledIn(b)) impl(b).finish(self, p.handle, must) else unreachable,
            } catch |e| blk: {
                if (first_err == null) first_err = e;
                break :blk true;
            };
            if (!finished) break;
            self.completed = p.value;
            n += 1;
        }
        self.pending.replaceRangeAssumeCapacity(0, n, &.{});
        if (first_err) |e| return e;
    }

    pub fn synchronize(self: *Device) !void {
        return self.wait(try self.submit());
    }
};

pub fn packUniforms(comptime K: type, args: K.Args) [@max(1, K.uniform_size / 4)]u32 {
    var words: [@max(1, K.uniform_size / 4)]u32 = @splat(0);
    inline for (K.params) |p| switch (p.binding) {
        .uniform => |u| {
            comptime std.debug.assert(u.offset % 4 == 0 and u.size == 4);
            words[u.offset / 4] = @bitCast(@field(args, p.name));
        },
        .buffer => {},
    };
    return words;
}

pub fn bufferCount(comptime K: type) usize {
    var n: usize = 0;
    for (K.params) |p| if (p.binding == .buffer) {
        n += 1;
    };
    return n;
}

test {
    _ = Device;
}
