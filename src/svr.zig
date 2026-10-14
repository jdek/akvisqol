// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! libsvm `nu_svr` (RBF kernel) model reader and predictor.
const std = @import("std");

pub const Error = error{
    InvalidModelFile,
    UnsupportedSvmType,
    UnsupportedKernel,
    OutOfMemory,
    InvalidFeatureIndex,
    NoSupportVectors,
};

pub const Model = struct {
    gamma: f64,
    rho: f64,
    num_features: usize,
    /// Row-major `[total_sv][num_features]`.
    support_vectors: []f64,
    coefficients: []f64,
    allocator: std.mem.Allocator,
    /// Evaluate the RBF kernel in f32 instead of f64 (libsvm/upstream).
    f32_kernel: bool = false,

    pub fn deinit(self: *Model) void {
        self.allocator.free(self.support_vectors);
        self.allocator.free(self.coefficients);
    }

    pub fn numSupportVectors(self: Model) usize {
        return self.coefficients.len;
    }

    /// `y = Σ_i coeff[i] · exp(-gamma · ||x - sv[i]||²) - rho`, unclamped.
    pub fn predict(self: Model, observation: []const f64) f64 {
        std.debug.assert(observation.len == self.num_features);
        const n_sv = self.coefficients.len;
        var sum: f64 = 0.0;
        for (0..n_sv) |i| {
            const sv = self.support_vectors[i * self.num_features .. (i + 1) * self.num_features];
            const k: f64 = if (self.f32_kernel) blk: {
                var dist: f32 = 0.0;
                for (sv, observation) |a, b| {
                    const d = @as(f32, @floatCast(a)) - @as(f32, @floatCast(b));
                    dist += d * d;
                }
                break :blk @exp(-@as(f32, @floatCast(self.gamma)) * dist);
            } else blk: {
                var dist: f64 = 0.0;
                for (sv, observation) |a, b| {
                    const d = a - b;
                    dist += d * d;
                }
                break :blk @exp(-self.gamma * dist);
            };
            sum += self.coefficients[i] * k;
        }
        return sum - self.rho;
    }

    /// Clamped to `[1.0, 5.0]` as upstream.
    pub fn predictClamped(self: Model, observation: []const f64) f64 {
        const y = self.predict(observation);
        return std.math.clamp(y, 1.0, 5.0);
    }
};

/// `num_features` is the highest 1-indexed feature seen; SVs are zero-padded.
pub fn loadModel(allocator: std.mem.Allocator, path: []const u8) !Model {
    const io = std.Options.debug_io;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(data);
    return parseModel(allocator, data);
}

pub fn parseModel(allocator: std.mem.Allocator, data: []const u8) !Model {
    var gamma: f64 = 0.01;
    var rho: f64 = 0.0;
    var declared_num_features: usize = 0;
    var saw_sv = false;

    // Parse header, collect SV lines, and find the max feature index.
    var sv_lines: std.ArrayList([]const u8) = .empty;
    defer sv_lines.deinit(allocator);

    var max_feat: usize = 0;
    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |raw_line_in| {
        var raw_line = raw_line_in;
        if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') {
            raw_line = raw_line[0 .. raw_line.len - 1];
        }
        if (raw_line.len == 0) continue;

        if (!saw_sv) {
            if (std.mem.eql(u8, raw_line, "SV")) {
                saw_sv = true;
                continue;
            }
            const sp = std.mem.indexOfScalar(u8, raw_line, ' ') orelse continue;
            const key = raw_line[0..sp];
            const val = std.mem.trim(u8, raw_line[sp + 1 ..], " \t");
            if (std.mem.eql(u8, key, "svm_type")) {
                if (!std.mem.eql(u8, val, "nu_svr") and !std.mem.eql(u8, val, "epsilon_svr")) {
                    return Error.UnsupportedSvmType;
                }
            } else if (std.mem.eql(u8, key, "kernel_type")) {
                if (!std.mem.eql(u8, val, "rbf")) return Error.UnsupportedKernel;
            } else if (std.mem.eql(u8, key, "gamma")) {
                gamma = std.fmt.parseFloat(f64, val) catch return Error.InvalidModelFile;
            } else if (std.mem.eql(u8, key, "rho")) {
                rho = std.fmt.parseFloat(f64, val) catch return Error.InvalidModelFile;
            } else if (std.mem.eql(u8, key, "total_sv")) {
                declared_num_features = std.fmt.parseInt(usize, val, 10) catch 0;
            }
            continue;
        }

        try sv_lines.append(allocator, raw_line);
        var tok_iter = std.mem.tokenizeAny(u8, raw_line, " \t");
        _ = tok_iter.next() orelse continue;
        while (tok_iter.next()) |tok| {
            const colon = std.mem.indexOfScalar(u8, tok, ':') orelse continue;
            const idx = std.fmt.parseInt(usize, tok[0..colon], 10) catch continue;
            if (idx > max_feat) max_feat = idx;
        }
    }

    if (sv_lines.items.len == 0) return Error.NoSupportVectors;
    if (max_feat == 0) return Error.InvalidModelFile;

    const n_sv = sv_lines.items.len;
    const num_features = max_feat;
    const sv_slab = try allocator.alloc(f64, n_sv * num_features);
    errdefer allocator.free(sv_slab);
    @memset(sv_slab, 0.0);
    const coeffs = try allocator.alloc(f64, n_sv);
    errdefer allocator.free(coeffs);

    for (sv_lines.items, 0..) |line, sv_i| {
        var tok_iter = std.mem.tokenizeAny(u8, line, " \t");
        const coeff_tok = tok_iter.next() orelse return Error.InvalidModelFile;
        coeffs[sv_i] = std.fmt.parseFloat(f64, coeff_tok) catch return Error.InvalidModelFile;
        while (tok_iter.next()) |tok| {
            const colon = std.mem.indexOfScalar(u8, tok, ':') orelse continue;
            const idx = std.fmt.parseInt(usize, tok[0..colon], 10) catch continue;
            const v = std.fmt.parseFloat(f64, tok[colon + 1 ..]) catch continue;
            if (idx == 0 or idx > num_features) return Error.InvalidFeatureIndex;
            sv_slab[sv_i * num_features + (idx - 1)] = v;
        }
    }

    return .{
        .gamma = gamma,
        .rho = rho,
        .num_features = num_features,
        .support_vectors = sv_slab,
        .coefficients = coeffs,
        .allocator = allocator,
    };
}

test "parseModel: parses a synthetic 2-SV / 3-feature nu_svr model" {
    const txt =
        "svm_type nu_svr\n" ++
        "kernel_type rbf\n" ++
        "gamma 0.5\n" ++
        "nr_class 2\n" ++
        "total_sv 2\n" ++
        "rho 0.1\n" ++
        "SV\n" ++
        "0.5 1:1.0 2:2.0 3:3.0\n" ++
        "-0.25 1:0.5 2:0.0 3:1.0\n";
    var m = try parseModel(std.testing.allocator, txt);
    defer m.deinit();
    try std.testing.expectEqual(@as(f64, 0.5), m.gamma);
    try std.testing.expectEqual(@as(f64, 0.1), m.rho);
    try std.testing.expectEqual(@as(usize, 3), m.num_features);
    try std.testing.expectEqual(@as(usize, 2), m.numSupportVectors());
    try std.testing.expectEqual(@as(f64, 0.5), m.coefficients[0]);
    try std.testing.expectEqual(@as(f64, -0.25), m.coefficients[1]);
    try std.testing.expectEqual(@as(f64, 2.0), m.support_vectors[0 * 3 + 1]);
    try std.testing.expectEqual(@as(f64, 0.5), m.support_vectors[1 * 3 + 0]);
}

test "predict: matches manual RBF computation" {
    const txt =
        "svm_type nu_svr\nkernel_type rbf\ngamma 1.0\nnr_class 2\ntotal_sv 2\nrho 0.0\nSV\n" ++
        "1.0 1:0.0 2:0.0\n" ++
        "1.0 1:1.0 2:1.0\n";
    var m = try parseModel(std.testing.allocator, txt);
    defer m.deinit();
    const obs = [_]f64{ 0.5, 0.5 };
    // y = 2 · exp(-0.5)
    const y = m.predict(&obs);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2130613194), y, 5e-8);
}

test "predict: default SVR known FVNSIM observation → 4.30533" {
    const allocator = std.testing.allocator;
    var m = try parseModel(allocator, @import("default_model").svr);
    defer m.deinit();

    const obs = [_]f64{
        0.853862, 0.680331, 0.535649, 0.639760, 0.029999, 0.058591,
        0.077462, 0.012432, 0.192035, 0.389230, 0.479403, 0.419914,
        0.521414, 0.858340, 0.884218, 0.864682, 0.868514, 0.845271,
        0.850559, 0.877882, 0.903985, 0.887572, 0.920558, 0.920375,
        0.954934, 0.945048, 0.952716, 0.986600, 0.987345, 0.936462,
        0.856010, 0.829761,
    };
    const y = m.predict(&obs);
    // 4.30533 is the f32-kernel result; f64 agrees to ~1e-4.
    try std.testing.expectApproxEqAbs(@as(f64, 4.30533), y, 1e-3);
}
