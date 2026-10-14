// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Speech-mode TF-Lattice MOS mapping (upstream `TFLiteQualityMapper`).
//! Inputs: one f32 scalar per (feature, band) plus `tau` = 0.5. As
//! upstream, the f32 output is widened to f64 without clamping.
const std = @import("std");
const tflite = @import("tflite.zig");

pub const Error = tflite.Error || error{MissingInput};

const FEATURES = [_][]const u8{ "fvnsim", "fvnsim10_", "fstdnsim", "fvdegenergy" };

pub const Mapper = struct {
    allocator: std.mem.Allocator,
    model: tflite.Model,
    num_bands: usize,
    /// Tensor per (feature, band), feature-major.
    feature_tensors: []u32,
    tau: u32,
    output: u32,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8, num_bands: usize) Error!Mapper {
        var model = try tflite.Model.init(allocator, bytes);
        errdefer model.deinit();
        const tensors = try allocator.alloc(u32, FEATURES.len * num_bands);
        errdefer allocator.free(tensors);
        var name_buf: [32]u8 = undefined;
        for (FEATURES, 0..) |f, fi| for (0..num_bands) |b| {
            const name = std.fmt.bufPrint(&name_buf, "{s}{d}", .{ f, b }) catch unreachable;
            tensors[fi * num_bands + b] = model.input(name) orelse return error.MissingInput;
        };
        return .{
            .allocator = allocator,
            .model = model,
            .num_bands = num_bands,
            .feature_tensors = tensors,
            .tau = model.input("tau") orelse return error.MissingInput,
            .output = model.output("predictions") orelse return error.MissingInput,
        };
    }

    pub fn deinit(self: *Mapper) void {
        self.allocator.free(self.feature_tensors);
        self.model.deinit();
    }

    /// MOS for one result's per-band features (each `num_bands` long).
    pub fn predict(self: *const Mapper, fvnsim: []const f64, fvnsim10: []const f64, fstdnsim: []const f64, fvdegenergy: []const f64) Error!f64 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const n = self.num_bands;
        const feeds = try a.alloc(tflite.Model.Feed, FEATURES.len * n + 1);
        const scalars = try a.alloc(f32, feeds.len);
        const scalar_shape = try tflite.Shape.init(&.{1});
        for ([_][]const f64{ fvnsim, fvnsim10, fstdnsim, fvdegenergy }, 0..) |vals, fi| {
            if (vals.len != n) return error.ShapeMismatch;
            for (vals, 0..) |v, b| {
                const k = fi * n + b;
                scalars[k] = @floatCast(v);
                feeds[k] = .{ .tensor = self.feature_tensors[k], .value = .{ .shape = scalar_shape, .data = .{ .f32 = scalars[k..][0..1] } } };
            }
        }
        const last = feeds.len - 1;
        scalars[last] = 0.5;
        feeds[last] = .{ .tensor = self.tau, .value = .{ .shape = scalar_shape, .data = .{ .f32 = scalars[last..][0..1] } } };
        const out = try (try self.model.run(a, feeds, self.output)).floats();
        if (out.len < 1) return error.ShapeMismatch;
        return out[0];
    }
};

test "default lattice model loads and maps a perfect match high" {
    const bytes = @import("default_model").lattice;
    var m = try Mapper.init(std.testing.allocator, bytes, 21);
    defer m.deinit();
    const ones: [21]f64 = @splat(1.0);
    const zeros: [21]f64 = @splat(0.0);
    const energy: [21]f64 = @splat(50.0);
    const mos = try m.predict(&ones, &ones, &zeros, &energy);
    try std.testing.expect(mos > 4.0 and mos <= 5.5);
}
