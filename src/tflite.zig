// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Minimal TFLite interpreter for the ops in upstream's lattice speech model.
//! Unsupported ops fail at load with `UnsupportedOp`. Dot products use
//! TFLite's builtin order (sequential f32 FMA) to match it within a few ulps.
const std = @import("std");

pub const Error = error{ InvalidModel, UnsupportedOp, UnsupportedType, ShapeMismatch, OutOfMemory };

// =============================================================================
// Flatbuffer access
// =============================================================================

const Table = struct {
    buf: []const u8,
    pos: usize,

    fn readAt(buf: []const u8, comptime T: type, pos: usize) Error!T {
        if (pos > buf.len or buf.len - pos < @sizeOf(T)) return error.InvalidModel;
        return std.mem.readInt(T, buf[pos..][0..@sizeOf(T)], .little);
    }

    /// Absolute position of field `id`, or null when absent.
    fn field(self: Table, id: u16) Error!?usize {
        const soff = try readAt(self.buf, i32, self.pos);
        const vt_i = @as(i64, @intCast(self.pos)) - soff;
        if (vt_i < 0) return error.InvalidModel;
        const vt: usize = @intCast(vt_i);
        const vt_size = try readAt(self.buf, u16, vt);
        const slot = 4 + 2 * @as(usize, id);
        if (slot + 2 > vt_size) return null;
        const off = try readAt(self.buf, u16, vt + slot);
        return if (off == 0) null else self.pos + off;
    }

    fn scalar(self: Table, comptime T: type, id: u16, default: T) Error!T {
        const p = (try self.field(id)) orelse return default;
        if (T == bool) return (try readAt(self.buf, u8, p)) != 0;
        return readAt(self.buf, T, p);
    }

    fn deref(buf: []const u8, p: usize) Error!usize {
        return p + try readAt(buf, u32, p);
    }

    fn table(self: Table, id: u16) Error!?Table {
        const p = (try self.field(id)) orelse return null;
        return .{ .buf = self.buf, .pos = try deref(self.buf, p) };
    }

    fn vector(self: Table, id: u16) Error!?Vector {
        const p = (try self.field(id)) orelse return null;
        const v = try deref(self.buf, p);
        return .{ .buf = self.buf, .start = v + 4, .len = try readAt(self.buf, u32, v) };
    }

    fn string(self: Table, id: u16) Error!?[]const u8 {
        const v = (try self.vector(id)) orelse return null;
        return try v.bytes();
    }
};

const Vector = struct {
    buf: []const u8,
    start: usize,
    len: usize,

    fn table(self: Vector, i: usize) Error!Table {
        const p = self.start + 4 * i;
        return .{ .buf = self.buf, .pos = try Table.deref(self.buf, p) };
    }

    fn int(self: Vector, comptime T: type, i: usize) Error!T {
        return Table.readAt(self.buf, T, self.start + @sizeOf(T) * i);
    }

    fn bytes(self: Vector) Error![]const u8 {
        if (self.start > self.buf.len or self.buf.len - self.start < self.len) return error.InvalidModel;
        return self.buf[self.start..][0..self.len];
    }
};

// =============================================================================
// Tensors
// =============================================================================

pub const DType = enum { f32, i32, bool };

pub const MAX_RANK = 6;

pub const Shape = struct {
    rank: u8 = 0,
    dims: [MAX_RANK]usize = @splat(0),

    pub fn init(dims: []const usize) Error!Shape {
        if (dims.len > MAX_RANK) return error.UnsupportedType;
        var s: Shape = .{ .rank = @intCast(dims.len) };
        @memcpy(s.dims[0..dims.len], dims);
        return s;
    }

    pub fn slice(self: *const Shape) []const usize {
        return self.dims[0..self.rank];
    }

    pub fn count(self: Shape) usize {
        var n: usize = 1;
        for (self.slice()) |d| n *= d;
        return n;
    }
};

pub const Value = struct {
    shape: Shape,
    data: Data,

    pub const Data = union(DType) { f32: []const f32, i32: []const i32, bool: []const bool };

    pub fn floats(self: Value) Error![]const f32 {
        return switch (self.data) {
            .f32 => |d| d,
            else => error.UnsupportedType,
        };
    }

    pub fn ints(self: Value) Error![]const i32 {
        return switch (self.data) {
            .i32 => |d| d,
            else => error.UnsupportedType,
        };
    }

    /// An i32 scalar or one-element tensor (axis inputs).
    fn axis(self: Value) Error!i32 {
        const d = try self.ints();
        if (d.len != 1) return error.ShapeMismatch;
        return d[0];
    }
};

fn dtypeOf(tflite_type: i8) ?DType {
    return switch (tflite_type) {
        0 => .f32,
        2 => .i32,
        6 => .bool,
        else => null,
    };
}

// =============================================================================
// Ops
// =============================================================================

const Kind = enum { add, sub, mul, minimum, maximum, equal, relu, relu6, abs, cast, concatenation, fully_connected, batch_matmul, reshape, expand_dims, split, shape, fill };

fn kindOf(builtin: i32) ?Kind {
    return switch (builtin) {
        0 => .add,
        2 => .concatenation,
        9 => .fully_connected,
        18 => .mul,
        19 => .relu,
        21 => .relu6,
        22 => .reshape,
        41 => .sub,
        49 => .split,
        53 => .cast,
        55 => .maximum,
        57 => .minimum,
        70 => .expand_dims,
        71 => .equal,
        77 => .shape,
        94 => .fill,
        101 => .abs,
        126 => .batch_matmul,
        else => null,
    };
}

const Activation = enum { none, relu, relu_n1_to_1, relu6 };

fn activationOf(code: i8) Error!Activation {
    return switch (code) {
        0 => .none,
        1 => .relu,
        2 => .relu_n1_to_1,
        3 => .relu6,
        else => error.UnsupportedOp,
    };
}

fn activate(act: Activation, x: f32) f32 {
    return switch (act) {
        .none => x,
        .relu => @max(x, 0.0),
        .relu_n1_to_1 => std.math.clamp(x, -1.0, 1.0),
        .relu6 => std.math.clamp(x, 0.0, 6.0),
    };
}

const Op = struct {
    kind: Kind,
    inputs: []const i32,
    outputs: []const i32,
    act: Activation = .none,
    axis: i32 = 0,
    adj_x: bool = false,
    adj_y: bool = false,
    keep_num_dims: bool = false,
    new_shape: ?[]const i32 = null,
};

pub const Named = struct { name: []const u8, tensor: u32 };

// =============================================================================
// Model
// =============================================================================

pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    /// Per tensor: its type (null if unsupported) and, for weights, its value.
    dtypes: []const ?DType,
    constants: []const ?Value,
    ops: []const Op,
    /// The "predict" signature if present, else the subgraph's own inputs
    /// and outputs under their tensor names.
    inputs: []const Named,
    outputs: []const Named,

    /// Weights are copied; `bytes` need not outlive the model.
    pub fn init(gpa: std.mem.Allocator, bytes: []const u8) Error!Model {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        const root: Table = .{ .buf = bytes, .pos = try Table.readAt(bytes, u32, 0) };
        const codes_v = (try root.vector(1)) orelse return error.InvalidModel;
        const subgraphs = (try root.vector(2)) orelse return error.InvalidModel;
        const buffers = (try root.vector(4)) orelse return error.InvalidModel;
        if (subgraphs.len < 1) return error.InvalidModel;
        const g = try subgraphs.table(0);

        const codes = try a.alloc(?Kind, codes_v.len);
        for (codes, 0..) |*c, i| {
            const t = try codes_v.table(i);
            if ((try t.field(1)) != null) return error.UnsupportedOp; // custom op
            const deprecated: i32 = try t.scalar(i8, 0, 0);
            const builtin = try t.scalar(i32, 3, 0);
            c.* = kindOf(@max(deprecated, builtin));
        }

        const tensors_v = (try g.vector(0)) orelse return error.InvalidModel;
        const names = try a.alloc([]const u8, tensors_v.len);
        const dtypes = try a.alloc(?DType, tensors_v.len);
        const constants = try a.alloc(?Value, tensors_v.len);
        for (0..tensors_v.len) |i| {
            const t = try tensors_v.table(i);
            names[i] = (try t.string(3)) orelse "";
            dtypes[i] = dtypeOf(try t.scalar(i8, 1, 0));
            constants[i] = null;
            const buf_idx = try t.scalar(u32, 2, 0);
            if (buf_idx == 0 or buf_idx >= buffers.len) continue;
            const b = try buffers.table(buf_idx);
            var data: []const u8 = if (try b.vector(0)) |v| try v.bytes() else &.{};
            if (data.len == 0) {
                // Models over 2 GB keep weights after the flatbuffer.
                const off = try b.scalar(u64, 1, 0);
                const size = try b.scalar(u64, 2, 0);
                if (off > 1 and size > 0) {
                    if (off > bytes.len or bytes.len - off < size) return error.InvalidModel;
                    data = bytes[@intCast(off)..][0..@intCast(size)];
                }
            }
            if (data.len == 0) continue;
            var dims: [MAX_RANK]usize = undefined;
            const shape_v = (try t.vector(0)) orelse Vector{ .buf = bytes, .start = 0, .len = 0 };
            if (shape_v.len > MAX_RANK) return error.UnsupportedType;
            for (0..shape_v.len) |d| {
                const x = try shape_v.int(i32, d);
                if (x < 0) return error.InvalidModel;
                dims[d] = @intCast(x);
            }
            const shape = try Shape.init(dims[0..shape_v.len]);
            const n = shape.count();
            const dt = dtypes[i] orelse return error.UnsupportedType;
            constants[i] = .{ .shape = shape, .data = switch (dt) {
                .f32 => .{ .f32 = try copyInts(a, f32, data, n) },
                .i32 => .{ .i32 = try copyInts(a, i32, data, n) },
                .bool => .{ .bool = blk: {
                    if (data.len != n) return error.InvalidModel;
                    const out = try a.alloc(bool, n);
                    for (out, data) |*o, x| o.* = x != 0;
                    break :blk out;
                } },
            } };
        }

        const ops_v = (try g.vector(3)) orelse return error.InvalidModel;
        const ops = try a.alloc(Op, ops_v.len);
        for (ops, 0..) |*op, i| {
            const t = try ops_v.table(i);
            const code_idx = try t.scalar(u32, 0, 0);
            if (code_idx >= codes.len) return error.InvalidModel;
            const kind = codes[code_idx] orelse return error.UnsupportedOp;
            op.* = .{
                .kind = kind,
                .inputs = try tensorList(a, try t.vector(1), tensors_v.len),
                .outputs = try tensorList(a, try t.vector(2), tensors_v.len),
            };
            for (op.outputs) |o| if (o < 0) return error.InvalidModel;
            const opts = try t.table(4);
            switch (kind) {
                .add, .sub, .mul => if (opts) |o| {
                    op.act = try activationOf(try o.scalar(i8, 0, 0));
                },
                .concatenation => if (opts) |o| {
                    op.axis = try o.scalar(i32, 0, 0);
                    op.act = try activationOf(try o.scalar(i8, 1, 0));
                },
                .fully_connected => if (opts) |o| {
                    op.act = try activationOf(try o.scalar(i8, 0, 0));
                    if (try o.scalar(i8, 1, 0) != 0) return error.UnsupportedOp; // shuffled weights
                    op.keep_num_dims = try o.scalar(bool, 2, false);
                },
                .batch_matmul => if (opts) |o| {
                    op.adj_x = try o.scalar(bool, 0, false);
                    op.adj_y = try o.scalar(bool, 1, false);
                },
                .reshape => if (opts) |o| {
                    if (try o.vector(0)) |v| {
                        const s = try a.alloc(i32, v.len);
                        for (s, 0..) |*x, d| x.* = try v.int(i32, d);
                        op.new_shape = s;
                    }
                },
                else => {},
            }
        }

        var inputs: []Named = &.{};
        var outputs: []Named = &.{};
        if (try root.vector(7)) |sigs| {
            for (0..sigs.len) |i| {
                const s = try sigs.table(i);
                const key = (try s.string(2)) orelse "";
                if (!std.mem.eql(u8, key, "predict") and sigs.len > 1) continue;
                if (try s.scalar(u32, 4, 0) != 0) return error.UnsupportedOp;
                inputs = try tensorMaps(a, try s.vector(0), tensors_v.len);
                outputs = try tensorMaps(a, try s.vector(1), tensors_v.len);
                break;
            }
        }
        if (inputs.len == 0) {
            inputs = try namedList(a, try g.vector(1), names);
            outputs = try namedList(a, try g.vector(2), names);
        }

        return .{ .arena = arena, .dtypes = dtypes, .constants = constants, .ops = ops, .inputs = inputs, .outputs = outputs };
    }

    pub fn deinit(self: *Model) void {
        self.arena.deinit();
    }

    pub fn input(self: *const Model, name: []const u8) ?u32 {
        return find(self.inputs, name);
    }

    pub fn output(self: *const Model, name: []const u8) ?u32 {
        return find(self.outputs, name);
    }

    pub const Feed = struct { tensor: u32, value: Value };

    /// Intermediates come from `scratch` (use an arena). Thread-safe: the
    /// model is not modified.
    pub fn run(self: *const Model, scratch: std.mem.Allocator, feeds: []const Feed, out: u32) Error!Value {
        const values = try scratch.alloc(?Value, self.constants.len);
        @memcpy(values, self.constants);
        for (feeds) |f| {
            if (f.tensor >= values.len) return error.InvalidModel;
            values[f.tensor] = f.value;
        }
        for (self.ops) |op| try self.exec(scratch, op, values);
        if (out >= values.len) return error.InvalidModel;
        return values[out] orelse error.InvalidModel;
    }

    fn exec(self: *const Model, a: std.mem.Allocator, op: Op, values: []?Value) Error!void {
        const in = struct {
            fn get(vals: []?Value, o: Op, i: usize) Error!Value {
                if (i >= o.inputs.len or o.inputs[i] < 0) return error.InvalidModel;
                return vals[@intCast(o.inputs[i])] orelse error.InvalidModel;
            }
        }.get;
        const out0: usize = if (op.outputs.len > 0) @intCast(op.outputs[0]) else return error.InvalidModel;
        values[out0] = switch (op.kind) {
            .add, .sub, .mul, .minimum, .maximum => try binary(a, op.kind, op.act, try in(values, op, 0), try in(values, op, 1)),
            .equal => try equal(a, try in(values, op, 0), try in(values, op, 1)),
            .relu, .relu6, .abs => try unary(a, op.kind, try in(values, op, 0)),
            .cast => try cast(a, try in(values, op, 0), self.dtypes[out0] orelse return error.UnsupportedType),
            .concatenation => try concat(a, op, values),
            .fully_connected => try fullyConnected(a, op, try in(values, op, 0), try in(values, op, 1), if (op.inputs.len > 2 and op.inputs[2] >= 0) try in(values, op, 2) else null),
            .batch_matmul => try batchMatmul(a, op, try in(values, op, 0), try in(values, op, 1)),
            .reshape => try reshape(op, try in(values, op, 0), if (op.inputs.len > 1 and op.inputs[1] >= 0) try in(values, op, 1) else null),
            .expand_dims => try expandDims(try in(values, op, 0), try (try in(values, op, 1)).axis()),
            .shape => try shapeOf(a, try in(values, op, 0)),
            .fill => try fill(a, try in(values, op, 0), try in(values, op, 1)),
            .split => return split(a, op, try (try in(values, op, 0)).axis(), try in(values, op, 1), values),
        };
    }
};

fn find(list: []const Named, name: []const u8) ?u32 {
    for (list) |n| if (std.mem.eql(u8, n.name, name)) return n.tensor;
    return null;
}

fn copyInts(a: std.mem.Allocator, comptime T: type, data: []const u8, n: usize) Error![]const T {
    if (data.len != n * @sizeOf(T)) return error.InvalidModel;
    const out = try a.alloc(T, n);
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    for (out, 0..) |*o, i| o.* = @bitCast(std.mem.readInt(Bits, data[i * @sizeOf(T) ..][0..@sizeOf(T)], .little));
    return out;
}

fn tensorList(a: std.mem.Allocator, v: ?Vector, n_tensors: usize) Error![]const i32 {
    const vec = v orelse return &.{};
    const out = try a.alloc(i32, vec.len);
    for (out, 0..) |*o, i| {
        o.* = try vec.int(i32, i);
        if (o.* >= @as(i64, @intCast(n_tensors))) return error.InvalidModel;
    }
    return out;
}

fn tensorMaps(a: std.mem.Allocator, v: ?Vector, n_tensors: usize) Error![]Named {
    const vec = v orelse return &.{};
    const out = try a.alloc(Named, vec.len);
    for (out, 0..) |*o, i| {
        const t = try vec.table(i);
        o.* = .{ .name = (try t.string(0)) orelse "", .tensor = try t.scalar(u32, 1, 0) };
        if (o.tensor >= n_tensors) return error.InvalidModel;
    }
    return out;
}

fn namedList(a: std.mem.Allocator, v: ?Vector, names: []const []const u8) Error![]Named {
    const vec = v orelse return &.{};
    const out = try a.alloc(Named, vec.len);
    for (out, 0..) |*o, i| {
        const idx = try vec.int(i32, i);
        if (idx < 0 or idx >= names.len) return error.InvalidModel;
        o.* = .{ .name = names[@intCast(idx)], .tensor = @intCast(idx) };
    }
    return out;
}

// -----------------------------------------------------------------------------
// Kernels
// -----------------------------------------------------------------------------

fn broadcast(x: Shape, y: Shape) Error!Shape {
    var out: Shape = .{ .rank = @max(x.rank, y.rank) };
    for (0..out.rank) |k| {
        const dx = if (k + x.rank >= out.rank) x.dims[k + x.rank - out.rank] else 1;
        const dy = if (k + y.rank >= out.rank) y.dims[k + y.rank - out.rank] else 1;
        if (dx != dy and dx != 1 and dy != 1) return error.ShapeMismatch;
        out.dims[k] = if (dx == 1) dy else dx;
    }
    return out;
}

/// Element strides of `s` viewed in broadcast shape `out` (0 on broadcast axes).
fn strides(s: Shape, out: Shape) [MAX_RANK]usize {
    var st: [MAX_RANK]usize = @splat(0);
    var acc: usize = 1;
    var k: usize = s.rank;
    while (k > 0) {
        k -= 1;
        const ok = k + out.rank - s.rank;
        st[ok] = if (s.dims[k] == 1) 0 else acc;
        acc *= s.dims[k];
    }
    return st;
}

/// Calls f(i, ix, iy) for every element of broadcast shape `out`.
fn eachBroadcast(out: Shape, x: Shape, y: Shape, ctx: anytype, comptime f: fn (@TypeOf(ctx), usize, usize, usize) void) void {
    const sx = strides(x, out);
    const sy = strides(y, out);
    var idx: [MAX_RANK]usize = @splat(0);
    var ix: usize = 0;
    var iy: usize = 0;
    const n = out.count();
    for (0..n) |i| {
        f(ctx, i, ix, iy);
        var k: usize = out.rank;
        while (k > 0) {
            k -= 1;
            idx[k] += 1;
            ix += sx[k];
            iy += sy[k];
            if (idx[k] < out.dims[k]) break;
            ix -= sx[k] * out.dims[k];
            iy -= sy[k] * out.dims[k];
            idx[k] = 0;
        }
    }
}

fn binary(a: std.mem.Allocator, kind: Kind, act: Activation, x: Value, y: Value) Error!Value {
    const xs = try x.floats();
    const ys = try y.floats();
    const shape = try broadcast(x.shape, y.shape);
    const out = try a.alloc(f32, shape.count());
    const Ctx = struct { kind: Kind, act: Activation, xs: []const f32, ys: []const f32, out: []f32 };
    eachBroadcast(shape, x.shape, y.shape, Ctx{ .kind = kind, .act = act, .xs = xs, .ys = ys, .out = out }, struct {
        fn f(c: Ctx, i: usize, ix: usize, iy: usize) void {
            const p = c.xs[ix];
            const q = c.ys[iy];
            c.out[i] = activate(c.act, switch (c.kind) {
                .add => p + q,
                .sub => p - q,
                .mul => p * q,
                .minimum => @min(p, q),
                .maximum => @max(p, q),
                else => unreachable,
            });
        }
    }.f);
    return .{ .shape = shape, .data = .{ .f32 = out } };
}

fn equal(a: std.mem.Allocator, x: Value, y: Value) Error!Value {
    const shape = try broadcast(x.shape, y.shape);
    const out = try a.alloc(bool, shape.count());
    switch (x.data) {
        inline .f32, .i32 => |xs, tag| {
            const ys = switch (y.data) {
                tag => |d| d,
                else => return error.UnsupportedType,
            };
            const Ctx = struct { xs: @TypeOf(xs), ys: @TypeOf(xs), out: []bool };
            eachBroadcast(shape, x.shape, y.shape, Ctx{ .xs = xs, .ys = ys, .out = out }, struct {
                fn f(c: Ctx, i: usize, ix: usize, iy: usize) void {
                    c.out[i] = c.xs[ix] == c.ys[iy];
                }
            }.f);
        },
        .bool => return error.UnsupportedType,
    }
    return .{ .shape = shape, .data = .{ .bool = out } };
}

fn unary(a: std.mem.Allocator, kind: Kind, x: Value) Error!Value {
    const xs = try x.floats();
    const out = try a.alloc(f32, xs.len);
    for (out, xs) |*o, v| o.* = switch (kind) {
        .relu => @max(v, 0.0),
        .relu6 => std.math.clamp(v, 0.0, 6.0),
        .abs => @abs(v),
        else => unreachable,
    };
    return .{ .shape = x.shape, .data = .{ .f32 = out } };
}

fn cast(a: std.mem.Allocator, x: Value, to: DType) Error!Value {
    const n = x.shape.count();
    return .{ .shape = x.shape, .data = switch (to) {
        inline else => |t| blk: {
            const T = switch (t) {
                .f32 => f32,
                .i32 => i32,
                .bool => bool,
            };
            const out = try a.alloc(T, n);
            switch (x.data) {
                inline else => |xs| for (out, xs) |*o, v| {
                    o.* = convert(T, v);
                },
            }
            break :blk @unionInit(Value.Data, @tagName(t), out);
        },
    } };
}

fn convert(comptime T: type, v: anytype) T {
    const V = @TypeOf(v);
    if (T == V) return v;
    if (T == bool) return v != 0;
    if (V == bool) return if (T == f32) @floatFromInt(@intFromBool(v)) else @intFromBool(v);
    if (T == f32) return @floatFromInt(v);
    // f32 → i32 truncates toward zero, as TFLite's static_cast.
    return std.math.lossyCast(i32, @trunc(v));
}

fn normAxis(axis: i32, rank: usize) Error!usize {
    const r: i32 = @intCast(rank);
    const ax = if (axis < 0) axis + r else axis;
    if (ax < 0 or ax >= r) return error.ShapeMismatch;
    return @intCast(ax);
}

fn concat(a: std.mem.Allocator, op: Op, values: []?Value) Error!Value {
    if (op.inputs.len == 0) return error.InvalidModel;
    const first = values[@intCast(op.inputs[0])] orelse return error.InvalidModel;
    const ax = try normAxis(op.axis, first.shape.rank);
    var shape = first.shape;
    shape.dims[ax] = 0;
    for (op.inputs) |ti| {
        const v = values[@intCast(ti)] orelse return error.InvalidModel;
        if (v.shape.rank != shape.rank) return error.ShapeMismatch;
        for (0..shape.rank) |k| if (k != ax and v.shape.dims[k] != first.shape.dims[k]) return error.ShapeMismatch;
        shape.dims[ax] += v.shape.dims[ax];
    }
    var outer: usize = 1;
    for (shape.dims[0..ax]) |d| outer *= d;
    var inner: usize = 1;
    for (shape.dims[ax + 1 .. shape.rank]) |d| inner *= d;
    const out = try a.alloc(f32, shape.count());
    var pos: usize = 0;
    for (0..outer) |o| {
        for (op.inputs) |ti| {
            const v = values[@intCast(ti)].?;
            const xs = try v.floats();
            const chunk = v.shape.dims[ax] * inner;
            for (out[pos..][0..chunk], xs[o * chunk ..][0..chunk]) |*d, s| d.* = activate(op.act, s);
            pos += chunk;
        }
    }
    return .{ .shape = shape, .data = .{ .f32 = out } };
}

fn fullyConnected(a: std.mem.Allocator, op: Op, x: Value, w: Value, bias: ?Value) Error!Value {
    const xs = try x.floats();
    const ws = try w.floats();
    if (w.shape.rank != 2) return error.ShapeMismatch;
    const n_out = w.shape.dims[0];
    const n_in = w.shape.dims[1];
    if (n_in == 0 or xs.len % n_in != 0) return error.ShapeMismatch;
    const batch = xs.len / n_in;
    const bs: ?[]const f32 = if (bias) |b| try b.floats() else null;
    if (bs) |b| if (b.len != n_out) return error.ShapeMismatch;
    const out = try a.alloc(f32, batch * n_out);
    for (0..batch) |r| {
        const row = xs[r * n_in ..][0..n_in];
        for (0..n_out) |o| {
            var y = dot(row, ws[o * n_in ..][0..n_in]);
            if (bs) |b| y += b[o];
            out[r * n_out + o] = activate(op.act, y);
        }
    }
    var shape: Shape = undefined;
    if (op.keep_num_dims) {
        shape = x.shape;
        shape.dims[shape.rank - 1] = n_out;
    } else {
        shape = try Shape.init(&.{ batch, n_out });
    }
    return .{ .shape = shape, .data = .{ .f32 = out } };
}

/// Sequential f32 FMA, as TFLite's builtin kernels: summation order moves
/// lattice MOS by up to 5e-5, and this order is closest to upstream.
fn dot(x: []const f32, w: []const f32) f32 {
    var acc: f32 = 0.0;
    for (x, w) |p, q| acc = @mulAdd(f32, p, q, acc);
    return acc;
}

fn batchMatmul(a: std.mem.Allocator, op: Op, x: Value, y: Value) Error!Value {
    const xs = try x.floats();
    const ys = try y.floats();
    if (x.shape.rank < 2 or y.shape.rank < 2) return error.ShapeMismatch;
    const xr = x.shape.rank;
    const yr = y.shape.rank;
    const m = if (op.adj_x) x.shape.dims[xr - 1] else x.shape.dims[xr - 2];
    const k = if (op.adj_x) x.shape.dims[xr - 2] else x.shape.dims[xr - 1];
    const k2 = if (op.adj_y) y.shape.dims[yr - 1] else y.shape.dims[yr - 2];
    const n = if (op.adj_y) y.shape.dims[yr - 2] else y.shape.dims[yr - 1];
    if (k != k2) return error.ShapeMismatch;
    const xb = try Shape.init(x.shape.dims[0 .. xr - 2]);
    const yb = try Shape.init(y.shape.dims[0 .. yr - 2]);
    const ob = try broadcast(xb, yb);
    const out = try a.alloc(f32, ob.count() * m * n);
    const Ctx = struct { op: Op, xs: []const f32, ys: []const f32, out: []f32, m: usize, n: usize, k: usize };
    eachBroadcast(ob, xb, yb, Ctx{ .op = op, .xs = xs, .ys = ys, .out = out, .m = m, .n = n, .k = k }, struct {
        fn f(c: Ctx, bi: usize, bx: usize, by: usize) void {
            const xm = c.xs[bx * c.m * c.k ..][0 .. c.m * c.k];
            const ym = c.ys[by * c.k * c.n ..][0 .. c.k * c.n];
            const om = c.out[bi * c.m * c.n ..][0 .. c.m * c.n];
            for (0..c.m) |i| for (0..c.n) |j| {
                var acc: f32 = 0.0;
                for (0..c.k) |l| {
                    const p = if (c.op.adj_x) xm[l * c.m + i] else xm[i * c.k + l];
                    const q = if (c.op.adj_y) ym[j * c.k + l] else ym[l * c.n + j];
                    acc = @mulAdd(f32, p, q, acc);
                }
                om[i * c.n + j] = acc;
            };
        }
    }.f);
    var shape = ob;
    if (shape.rank + 2 > MAX_RANK) return error.UnsupportedType;
    shape.dims[shape.rank] = m;
    shape.dims[shape.rank + 1] = n;
    shape.rank += 2;
    return .{ .shape = shape, .data = .{ .f32 = out } };
}

fn reshape(op: Op, x: Value, shape_in: ?Value) Error!Value {
    const spec: []const i32 = if (shape_in) |s| try s.ints() else op.new_shape orelse return error.InvalidModel;
    if (spec.len > MAX_RANK) return error.UnsupportedType;
    const total = x.shape.count();
    var shape: Shape = .{ .rank = @intCast(spec.len) };
    var known: usize = 1;
    var infer: ?usize = null;
    for (spec, 0..) |d, k| {
        if (d == -1) {
            if (infer != null) return error.ShapeMismatch;
            infer = k;
        } else if (d < 0) {
            return error.ShapeMismatch;
        } else {
            shape.dims[k] = @intCast(d);
            known *= shape.dims[k];
        }
    }
    if (infer) |k| {
        if (known == 0 or total % known != 0) return error.ShapeMismatch;
        shape.dims[k] = total / known;
    }
    if (shape.count() != total) return error.ShapeMismatch;
    return .{ .shape = shape, .data = x.data };
}

fn expandDims(x: Value, axis: i32) Error!Value {
    const r: i32 = x.shape.rank;
    const ax = if (axis < 0) axis + r + 1 else axis;
    if (ax < 0 or ax > r or x.shape.rank >= MAX_RANK) return error.ShapeMismatch;
    const at: usize = @intCast(ax);
    var shape: Shape = .{ .rank = x.shape.rank + 1 };
    @memcpy(shape.dims[0..at], x.shape.dims[0..at]);
    shape.dims[at] = 1;
    @memcpy(shape.dims[at + 1 .. shape.rank], x.shape.dims[at..x.shape.rank]);
    return .{ .shape = shape, .data = x.data };
}

fn shapeOf(a: std.mem.Allocator, x: Value) Error!Value {
    const out = try a.alloc(i32, x.shape.rank);
    for (out, x.shape.slice()) |*o, d| o.* = std.math.cast(i32, d) orelse return error.ShapeMismatch;
    return .{ .shape = try Shape.init(&.{x.shape.rank}), .data = .{ .i32 = out } };
}

fn fill(a: std.mem.Allocator, dims: Value, v: Value) Error!Value {
    const ds = try dims.ints();
    if (ds.len > MAX_RANK) return error.UnsupportedType;
    var shape: Shape = .{ .rank = @intCast(ds.len) };
    for (ds, 0..) |d, k| {
        if (d < 0) return error.ShapeMismatch;
        shape.dims[k] = @intCast(d);
    }
    const n = shape.count();
    return .{ .shape = shape, .data = switch (v.data) {
        inline else => |xs, tag| blk: {
            if (xs.len != 1) return error.ShapeMismatch;
            const out = try a.alloc(@TypeOf(xs[0]), n);
            @memset(out, xs[0]);
            break :blk @unionInit(Value.Data, @tagName(tag), out);
        },
    } };
}

fn split(a: std.mem.Allocator, op: Op, axis: i32, x: Value, values: []?Value) Error!void {
    const xs = try x.floats();
    const ax = try normAxis(axis, x.shape.rank);
    const parts = op.outputs.len;
    if (parts == 0 or x.shape.dims[ax] % parts != 0) return error.ShapeMismatch;
    var shape = x.shape;
    shape.dims[ax] /= parts;
    var outer: usize = 1;
    for (x.shape.dims[0..ax]) |d| outer *= d;
    var inner: usize = 1;
    for (x.shape.dims[ax + 1 .. x.shape.rank]) |d| inner *= d;
    const chunk = shape.dims[ax] * inner;
    for (op.outputs, 0..) |ti, p| {
        const out = try a.alloc(f32, outer * chunk);
        for (0..outer) |o| @memcpy(out[o * chunk ..][0..chunk], xs[(o * parts + p) * chunk ..][0..chunk]);
        values[@intCast(ti)] = .{ .shape = shape, .data = .{ .f32 = out } };
    }
}

// =============================================================================
// Tests
// =============================================================================

test "broadcast binary ops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x: Value = .{ .shape = try Shape.init(&.{ 2, 1 }), .data = .{ .f32 = &.{ 1, 2 } } };
    const y: Value = .{ .shape = try Shape.init(&.{3}), .data = .{ .f32 = &.{ 10, 20, 30 } } };
    const r = try binary(a, .sub, .none, x, y);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, r.shape.slice());
    try std.testing.expectEqualSlices(f32, &.{ -9, -19, -29, -8, -18, -28 }, try r.floats());
    const e = try equal(a, x, .{ .shape = .{}, .data = .{ .f32 = &.{2} } });
    try std.testing.expectEqualSlices(bool, &.{ false, true }, e.data.bool);
}

test "batch matmul outer product and reshape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x: Value = .{ .shape = try Shape.init(&.{ 1, 2, 1 }), .data = .{ .f32 = &.{ 1, 2 } } };
    const y: Value = .{ .shape = try Shape.init(&.{ 1, 1, 2 }), .data = .{ .f32 = &.{ 3, 4 } } };
    const r = try batchMatmul(a, .{ .kind = .batch_matmul, .inputs = &.{}, .outputs = &.{} }, x, y);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 2 }, r.shape.slice());
    try std.testing.expectEqualSlices(f32, &.{ 3, 4, 6, 8 }, try r.floats());
    const s = try reshape(.{ .kind = .reshape, .inputs = &.{}, .outputs = &.{}, .new_shape = &.{ -1, 4, 1 } }, r, null);
    try std.testing.expectEqualSlices(usize, &.{ 1, 4, 1 }, s.shape.slice());
}

test "rejects truncated models" {
    try std.testing.expectError(error.InvalidModel, Model.init(std.testing.allocator, &.{ 1, 2 }));
    try std.testing.expectError(error.InvalidModel, Model.init(std.testing.allocator, &.{ 8, 0, 0, 0, 0, 0, 0, 0 }));
}
