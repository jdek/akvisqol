// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Compute runtime for Slang kernels on Metal, CUDA and Vulkan. Kernel bindings are
//! generated from Slang reflection; argument layout is resolved at comptime.
//!
//! Dispatches and transfers run in enqueue order, each seeing the previous
//! one's writes. `download` waits for everything before it.
//!
//! Backends provide memory blocks; `alloc` suballocates them (alloc.zig).
const std = @import("std");
const options = @import("zimt_options");
pub const alloc_mod = @import("alloc.zig");

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

/// Picks a buffer's memory at comptime.
pub const Usage = enum {
    /// Kernel data; host-mapped only where that is the device's main memory.
    device,
    /// Kernel results the host reads: host-visible memory the device writes,
    /// so `download` skips staging. Not for data kernels re-read.
    readback,
};

pub const BlockKind = enum {
    device,
    readback,
    /// Host memory for staged transfers.
    staging,
};

/// `used` may include other processes and devices.
pub const Budget = struct { used: u64, limit: u64 };

pub const RawBlock = struct {
    /// Metal: retained `id<MTLBuffer>`; CUDA: `CUdeviceptr` (device) or
    /// the host pointer (staging); Vulkan: a block record.
    handle: usize,
    host: ?[*]u8,
};

pub const Block = struct {
    raw: RawBlock,
    size: usize,
    kind: BlockKind,
    /// Null for a block holding one large buffer.
    buddy: ?alloc_mod.Buddy,
    /// A large buffer's block, freed and kept for the next.
    spare: bool = false,

    fn idle(self: *const Block) bool {
        return if (self.buddy) |*bd| bd.empty() else self.spare;
    }
};

/// At least 256-byte aligned, but for `Buffer.sub` views.
pub const Allocation = struct {
    block: *Block,
    offset: usize,
    size: usize,

    pub fn host(self: Allocation) ?[*]u8 {
        return if (self.block.raw.host) |h| h + self.offset else null;
    }

    pub fn span(self: Allocation, offset: usize, len: usize) Span {
        return .{ .block = self.block, .offset = self.offset + offset, .len = len };
    }
};

/// Kernel arguments are typed by their reflected element, so a mismatched
/// buffer doesn't compile.
pub fn Buffer(comptime T: type) type {
    return struct {
        mem: Allocation,
        len: usize,

        pub const Elem = T;

        /// Elements `first ..+ len`, the same memory.
        pub fn sub(self: @This(), first: usize, len: usize) @This() {
            std.debug.assert(first + len <= self.len);
            return .{ .mem = .{ .block = self.mem.block, .offset = self.mem.offset + first * @sizeOf(T), .size = len * @sizeOf(T) }, .len = len };
        }

        /// Valid once the device is done with the buffer.
        pub fn host(self: @This()) ?[]T {
            const p = self.mem.host() orelse return null;
            return @as([*]T, @ptrCast(@alignCast(p)))[0..self.len];
        }
    };
}

fn Elem(comptime B: type) type {
    if (!@hasDecl(B, "Elem") or B != Buffer(B.Elem)) @compileError(@typeName(B) ++ " is not a zimt.Buffer");
    return B.Elem;
}

pub const Span = struct { block: *const Block, offset: usize, len: usize };

pub const Access = enum { read, write, read_write };

/// One entry-point parameter, as reflected by Slang.
pub const Param = struct {
    name: []const u8,
    binding: union(enum) {
        /// `access` orders Vulkan commands; `stride` must match the `Args`
        /// field's element (`checkDef`).
        buffer: struct { metal_index: u32, vk_binding: u32, access: Access },
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

/// Buffers freed together.
pub const Arena = struct {
    dev: *Device,
    mems: std.ArrayList(Allocation) = .empty,

    pub fn alloc(self: *Arena, comptime T: type, comptime usage: Usage, len: usize) !Buffer(T) {
        try self.mems.ensureUnusedCapacity(self.dev.allocator, 1);
        const b = try self.dev.alloc(T, usage, len);
        self.mems.appendAssumeCapacity(b.mem);
        return b;
    }

    pub fn allocInit(self: *Arena, comptime T: type, data: []const T) !Buffer(T) {
        try self.mems.ensureUnusedCapacity(self.dev.allocator, 1);
        const b = try self.dev.allocInit(T, data);
        self.mems.appendAssumeCapacity(b.mem);
        return b;
    }

    pub fn deinit(self: *Arena) void {
        for (self.mems.items) |m| self.dev.freeBytes(m);
        self.mems.deinit(self.dev.allocator);
    }
};

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
    blocks: std.ArrayList(*Block) = .empty,
    /// Frees waiting for the work that may use them.
    deferred: std.ArrayList(Deferred) = .empty,
    staging: ?*Block = null,
    /// Owned by enqueued copies until the device idles.
    staging_used: usize = 0,

    /// Cap on kernel memory, on top of the backend's budget.
    memory_limit: ?usize = null,
    /// Idle bytes kept per kind: `spare_size`, or an eighth of the device
    /// budget if more (set on first use).
    spare_limit: ?usize = null,

    pub const staging_size: usize = 32 << 20;

    /// Minimum idle bytes kept per kind; dropped first when memory runs short.
    pub const spare_size: usize = 4 * alloc_mod.max_block_size;

    const Deferred = struct { mem: Allocation, fence: u64 };

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
        // Live buffers go with their blocks.
        self.deferred.deinit(self.allocator);
        while (self.blocks.items.len > 0) self.dropBlock(self.blocks.items[0]);
        self.blocks.deinit(self.allocator);
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

    pub fn alloc(self: *Device, comptime T: type, comptime usage: Usage, len: usize) !Buffer(T) {
        return .{ .mem = try self.allocBytes(usage, len * @sizeOf(T)), .len = len };
    }

    fn allocBytes(self: *Device, comptime usage: Usage, bytes: usize) !Allocation {
        const kind: BlockKind = comptime switch (usage) {
            .device => .device,
            .readback => .readback,
        };
        const block_size = comptime blockSize(kind);
        try self.reclaim();
        const class = alloc_mod.sizeClass(bytes);
        if (class > block_size) {
            // Whole blocks, so buffers of nearby sizes reuse them.
            const size = std.mem.alignForward(usize, bytes, block_size);
            // The smallest spare that fits, wasting at most half of it.
            var best: ?*Block = null;
            for (self.blocks.items) |blk| {
                if (blk.kind != kind or !blk.spare or blk.size < size or blk.size / 2 > size) continue;
                if (best == null or blk.size < best.?.size) best = blk;
            }
            const blk = best orelse try self.newBlock(size, kind, false);
            blk.spare = false;
            return .{ .block = blk, .offset = 0, .size = bytes };
        }
        while (true) {
            for (self.blocks.items) |blk| if (blk.kind == kind) if (blk.buddy) |*bd| {
                if (try bd.take(self.allocator, class)) |off| return .{ .block = blk, .offset = off, .size = bytes };
            };
            const blk = self.newBlock(block_size, kind, true) catch |e| {
                // Deferred frees may hold the memory.
                if (e != Error.OutOfMemory or self.deferred.items.len == 0) return e;
                try self.synchronize();
                try self.reclaim();
                continue;
            };
            return .{ .block = blk, .offset = (try blk.buddy.?.take(self.allocator, class)).?, .size = bytes };
        }
    }

    /// Readback holds results, and pinned memory is costly to map.
    pub fn blockSize(comptime kind: BlockKind) usize {
        return switch (kind) {
            .device => alloc_mod.max_block_size,
            .readback => 8 << 20,
            .staging => staging_size,
        };
    }

    /// Within budget, after reclaiming deferred frees and spare blocks.
    fn newBlock(self: *Device, size: usize, kind: BlockKind, shared: bool) !*Block {
        if (!self.fits(kind, size)) {
            try self.synchronize();
            try self.reclaim();
            self.dropEmpty(kind);
            if (!self.fits(kind, size)) return Error.OutOfMemory;
        }
        try self.blocks.ensureUnusedCapacity(self.allocator, 1);
        const blk = try self.allocator.create(Block);
        errdefer self.allocator.destroy(blk);
        var buddy: ?alloc_mod.Buddy = if (shared) try alloc_mod.Buddy.init(self.allocator, size) else null;
        errdefer if (buddy) |*bd| bd.deinit(self.allocator);
        const raw = switch (self.which()) {
            inline else => |b| if (comptime compiledIn(b)) try impl(b).blockAlloc(self, size, kind) else unreachable,
        };
        blk.* = .{ .raw = raw, .size = size, .kind = kind, .buddy = buddy };
        self.blocks.appendAssumeCapacity(blk);
        return blk;
    }

    fn fits(self: *Device, kind: BlockKind, size: usize) bool {
        if (kind != .staging) if (self.memory_limit) |limit| {
            var held: usize = 0;
            for (self.blocks.items) |b| held += if (b.kind != .staging) b.size else 0;
            if (held + size > limit) return false;
        };
        const b = self.budget(kind) orelse return true;
        return b.used + size <= b.limit;
    }

    pub fn budget(self: *Device, kind: BlockKind) ?Budget {
        return switch (self.which()) {
            inline else => |b| if (comptime compiledIn(b)) impl(b).budget(self, kind) else unreachable,
        };
    }

    fn dropEmpty(self: *Device, kind: BlockKind) void {
        var i: usize = 0;
        while (i < self.blocks.items.len) {
            const blk = self.blocks.items[i];
            if (blk.kind == kind and blk.idle()) {
                self.dropBlock(blk);
            } else i += 1;
        }
    }

    fn spareLimit(self: *Device) usize {
        if (self.spare_limit) |l| return l;
        const b = self.budget(.device);
        self.spare_limit = @max(spare_size, if (b) |x| @as(usize, @intCast(x.limit / 8)) else 0);
        return self.spare_limit.?;
    }

    fn idleBytes(self: *const Device, kind: BlockKind) usize {
        var n: usize = 0;
        for (self.blocks.items) |b| if (b.kind == kind and b.idle()) {
            n += b.size;
        };
        return n;
    }

    /// Only once nothing enqueued uses the block.
    fn dropBlock(self: *Device, blk: *Block) void {
        const i = std.mem.indexOfScalar(*Block, self.blocks.items, blk).?;
        _ = self.blocks.swapRemove(i);
        switch (self.which()) {
            inline else => |b| if (comptime compiledIn(b)) impl(b).blockFree(self, blk) else unreachable,
        }
        if (blk.buddy) |*bd| bd.deinit(self.allocator);
        if (self.staging == blk) self.staging = null;
        self.allocator.destroy(blk);
    }

    /// A `.device` buffer holding `data`.
    pub fn allocInit(self: *Device, comptime T: type, data: []const T) !Buffer(T) {
        const b = try self.alloc(T, .device, data.len);
        errdefer self.free(b);
        try self.upload(b, 0, data);
        return b;
    }

    pub fn arena(self: *Device) Arena {
        return .{ .dev = self };
    }

    /// Reused once the work enqueued so far completes.
    pub fn free(self: *Device, buf: anytype) void {
        _ = Elem(@TypeOf(buf));
        self.freeBytes(buf.mem);
    }

    fn freeBytes(self: *Device, mem: Allocation) void {
        const fence = self.submitted + @intFromBool(self.dirty);
        if (fence <= self.completed) return self.freeNow(mem);
        self.deferred.append(self.allocator, .{ .mem = mem, .fence = fence }) catch {
            self.synchronize() catch {};
            self.freeNow(mem);
        };
    }

    fn freeNow(self: *Device, mem: Allocation) void {
        const blk = mem.block;
        if (blk.buddy) |*bd| {
            bd.release(mem.offset, alloc_mod.sizeClass(mem.size));
            if (!bd.empty()) return;
        } else blk.spare = true;
        // Now idle, which `idleBytes` counts.
        if (self.idleBytes(blk.kind) > self.spareLimit()) self.dropBlock(blk);
    }

    fn reclaim(self: *Device) !void {
        if (self.deferred.items.len == 0) return;
        try self.retire(self.completed, false);
        var i: usize = 0;
        while (i < self.deferred.items.len) {
            const df = self.deferred.items[i];
            if (df.fence > self.completed) {
                i += 1;
                continue;
            }
            _ = self.deferred.swapRemove(i);
            self.freeNow(df.mem);
        }
    }

    /// Waits for the device if enqueued copies own the rest.
    fn stagingSpace(self: *Device, len: usize) !Span {
        const blk = self.staging orelse blk: {
            self.staging = try self.newBlock(staging_size, .staging, false);
            break :blk self.staging.?;
        };
        if (self.staging_used == staging_size or (self.staging_used > 0 and staging_size - self.staging_used < len)) {
            try self.synchronize();
            self.staging_used = 0;
        }
        const n = @min(len, staging_size - self.staging_used);
        defer self.staging_used += n;
        return .{ .block = blk, .offset = self.staging_used, .len = n };
    }

    fn copy(self: *Device, src: Span, dst: Span) !void {
        std.debug.assert(src.len == dst.len);
        switch (self.which()) {
            inline else => |b| if (comptime compiledIn(b)) try impl(b).copy(self, src, dst) else unreachable,
        }
        self.dirty = true;
    }

    /// Enqueued; `data` may be reused on return.
    pub fn upload(self: *Device, buf: anytype, first: usize, data: []const Elem(@TypeOf(buf))) !void {
        std.debug.assert(first + data.len <= buf.len);
        const size = @sizeOf(@TypeOf(buf).Elem);
        return self.uploadBytes(buf.mem, first * size, std.mem.sliceAsBytes(data));
    }

    /// Waits for earlier work.
    pub fn download(self: *Device, buf: anytype, first: usize, out: []Elem(@TypeOf(buf))) !void {
        std.debug.assert(first + out.len <= buf.len);
        const size = @sizeOf(@TypeOf(buf).Elem);
        return self.downloadBytes(buf.mem, first * size, std.mem.sliceAsBytes(out));
    }

    /// Enqueued.
    pub fn zero(self: *Device, buf: anytype, first: usize, count: usize) !void {
        std.debug.assert(first + count <= buf.len);
        const size = @sizeOf(Elem(@TypeOf(buf)));
        return self.zeroBytes(buf.mem, first * size, count * size);
    }

    fn uploadBytes(self: *Device, mem: Allocation, offset: usize, data: []const u8) !void {
        if (mem.host()) |h| {
            try self.synchronize();
            return @memcpy(h[offset..][0..data.len], data);
        }
        var moved: usize = 0;
        while (moved < data.len) {
            const st = try self.stagingSpace(data.len - moved);
            @memcpy(st.block.raw.host.?[st.offset..][0..st.len], data[moved..][0..st.len]);
            try self.copy(st, mem.span(offset + moved, st.len));
            moved += st.len;
        }
    }

    fn downloadBytes(self: *Device, mem: Allocation, offset: usize, out: []u8) !void {
        if (mem.host()) |h| {
            try self.synchronize();
            return @memcpy(out, h[offset..][0..out.len]);
        }
        var moved: usize = 0;
        while (moved < out.len) {
            const st = try self.stagingSpace(out.len - moved);
            try self.copy(mem.span(offset + moved, st.len), st);
            try self.synchronize();
            @memcpy(out[moved..][0..st.len], st.block.raw.host.?[st.offset..][0..st.len]);
            self.staging_used = 0;
            moved += st.len;
        }
    }

    fn zeroBytes(self: *Device, mem: Allocation, offset: usize, bytes: usize) !void {
        if (mem.host()) |h| {
            try self.synchronize();
            return @memset(h[offset..][0..bytes], 0);
        }
        // Backends fill whole words; the ragged ends are uploads.
        const zeros: [8]u8 = @splat(0);
        const start = std.mem.alignForward(usize, offset, 4);
        const end = std.mem.alignBackward(usize, offset + bytes, 4);
        if (start >= end) return self.uploadBytes(mem, offset, zeros[0..bytes]);
        if (start > offset) try self.uploadBytes(mem, offset, zeros[0 .. start - offset]);
        if (offset + bytes > end) try self.uploadBytes(mem, end, zeros[0 .. offset + bytes - end]);
        switch (self.which()) {
            inline else => |b| if (comptime compiledIn(b)) try impl(b).fill(self, mem.span(start, end - start)) else unreachable,
        }
        self.dirty = true;
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
    _ = alloc_mod;
}
