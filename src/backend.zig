// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Compute-backend dispatch for the C ABI / CLI. GPU engines (`gpu/`) are
//! compiled in only with their build option.
const std = @import("std");
const build_options = @import("build_options");
const visqol = @import("visqol.zig");
const svr = @import("svr.zig");
const lattice = @import("lattice.zig");

pub const Kind = enum(u32) { cpu = 0, metal = 1, cuda = 2, vulkan = 3 };

pub const Pair = visqol.Pair;

pub const Error = error{BackendUnavailable};

pub fn availableMask() u32 {
    var m: u32 = 1 << @backingInt(Kind.cpu);
    if (build_options.metal) {
        if (@import("gpu/engine.zig").available(.metal)) m |= 1 << @backingInt(Kind.metal);
    }
    if (build_options.cuda) {
        if (@import("gpu/engine.zig").available(.cuda)) m |= 1 << @backingInt(Kind.cuda);
    }
    if (build_options.vulkan) {
        if (@import("gpu/engine.zig").available(.vulkan)) m |= 1 << @backingInt(Kind.vulkan);
    }
    return m;
}

/// `model` is the SVR model text in audio mode and the TFLite lattice
/// model in speech mode with `use_lattice_model`; otherwise unused.
pub fn makeMapper(allocator: std.mem.Allocator, options: visqol.Options, model: []const u8) !?visqol.QualityMapper {
    return switch (options.mode) {
        .audio => .{ .svr = try svr.parseModel(allocator, model) },
        .speech => if (options.use_lattice_model)
            .{ .lattice = try lattice.Mapper.init(allocator, model, visqol.constants.NUM_BANDS_SPEECH) }
        else
            null,
    };
}

/// The embedded model `makeMapper` expects for `options`.
pub fn defaultModel(options: visqol.Options) []const u8 {
    const models = @import("default_model");
    return if (options.mode == .speech and options.use_lattice_model) models.lattice else models.svr;
}

pub const Engine = union(Kind) {
    cpu: CpuEngine,
    metal: GpuEngine,
    cuda: GpuEngine,
    vulkan: GpuEngine,

    pub fn init(allocator: std.mem.Allocator, kind: Kind, options: visqol.Options, model_text: []const u8) !Engine {
        return switch (kind) {
            .cpu => .{ .cpu = try CpuEngine.init(allocator, options, model_text) },
            .metal => .{ .metal = try GpuEngine.init(allocator, .metal, options, model_text) },
            .cuda => .{ .cuda = try GpuEngine.init(allocator, .cuda, options, model_text) },
            .vulkan => .{ .vulkan = try GpuEngine.init(allocator, .vulkan, options, model_text) },
        };
    }

    pub fn deinit(self: *Engine) void {
        switch (self.*) {
            inline else => |*e| e.deinit(),
        }
    }

    pub fn measure(self: *Engine, ref: []const f64, deg: []const f64, sample_rate: u32) !visqol.Result {
        return switch (self.*) {
            inline else => |*e| e.measure(ref, deg, sample_rate),
        };
    }

    /// Score every pair; per-pair failures land in `results[i]`.
    pub fn measureBatch(self: *Engine, pairs: []const Pair, sample_rate: u32, num_threads: u32, results: []anyerror!visqol.Result) !void {
        return switch (self.*) {
            inline else => |*e| e.measureBatch(pairs, sample_rate, num_threads, results),
        };
    }

    /// `refs` to score many degraded signals against (`measurePrepared`);
    /// on a device scoring the model, each one's patches, energy and
    /// spectrogram are computed once here.
    pub fn prepare(self: *Engine, refs: []const []const f64, sample_rate: u32) !visqol.Prepared {
        return switch (self.*) {
            inline else => |*e| e.prepare(refs, sample_rate),
        };
    }

    /// `degs[i]` against `prepared.refs[i]` (from this engine's `prepare`):
    /// `measureBatch`'s scores, and with `grads` `measureBatchGrad`'s.
    pub fn measurePrepared(self: *Engine, prepared: *const visqol.Prepared, degs: []const []const f64, num_threads: u32, results: []anyerror!visqol.Result, grads: ?[]const []f64) !void {
        return switch (self.*) {
            inline else => |*e| e.measurePrepared(prepared, degs, num_threads, results, grads),
        };
    }

    /// `measureBatch`, with ∂moslqo/∂deg of each pair into `grads` (each as
    /// long as its deg), the discrete choices (lags, matches, realignment)
    /// held fixed. GPU backends that score on the device only (not exact
    /// without f64); `error.Unsupported` elsewhere.
    pub fn measureBatchGrad(self: *Engine, pairs: []const Pair, sample_rate: u32, num_threads: u32, results: []anyerror!visqol.Result, grads: []const []f64) !void {
        return switch (self.*) {
            .cpu => error.Unsupported,
            inline else => |*e| e.measureBatchGrad(pairs, sample_rate, num_threads, results, grads),
        };
    }
};

const GpuEngine = if (build_options.metal or build_options.cuda or build_options.vulkan)
    @import("gpu/engine.zig").Engine
else
    struct {
        pub fn init(_: std.mem.Allocator, _: Kind, _: visqol.Options, _: []const u8) !GpuEngine {
            return Error.BackendUnavailable;
        }
        pub fn deinit(_: *GpuEngine) void {}
        pub fn measure(_: *GpuEngine, _: []const f64, _: []const f64, _: u32) !visqol.Result {
            return Error.BackendUnavailable;
        }
        pub fn measureBatch(_: *GpuEngine, _: []const Pair, _: u32, _: u32, _: []anyerror!visqol.Result) !void {
            return Error.BackendUnavailable;
        }
        pub fn measureBatchGrad(_: *GpuEngine, _: []const Pair, _: u32, _: u32, _: []anyerror!visqol.Result, _: []const []f64) !void {
            return Error.BackendUnavailable;
        }
        pub fn prepare(_: *GpuEngine, _: []const []const f64, _: u32) !visqol.Prepared {
            return Error.BackendUnavailable;
        }
        pub fn measurePrepared(_: *GpuEngine, _: *const visqol.Prepared, _: []const []const f64, _: u32, _: []anyerror!visqol.Result, _: ?[]const []f64) !void {
            return Error.BackendUnavailable;
        }
    };

pub const CpuEngine = struct {
    allocator: std.mem.Allocator,
    options: visqol.Options,
    model_text: []const u8,
    main: visqol.Visqol,

    pub fn init(allocator: std.mem.Allocator, options: visqol.Options, model_text: []const u8) !CpuEngine {
        return .{
            .allocator = allocator,
            .options = options,
            .model_text = model_text,
            .main = try visqol.Visqol.init(allocator, options, try makeMapper(allocator, options, model_text)),
        };
    }

    pub fn deinit(self: *CpuEngine) void {
        self.main.deinit();
    }

    pub fn measure(self: *CpuEngine, ref: []const f64, deg: []const f64, sample_rate: u32) !visqol.Result {
        return self.main.measure(ref, deg, sample_rate);
    }

    /// Copies only: the CPU model computes per pair.
    pub fn prepare(self: *CpuEngine, refs: []const []const f64, sample_rate: u32) !visqol.Prepared {
        return visqol.Prepared.init(self.allocator, refs, sample_rate, self.options.precision, self.options.mode);
    }

    pub fn measurePrepared(self: *CpuEngine, prepared: *const visqol.Prepared, degs: []const []const f64, num_threads: u32, results: []anyerror!visqol.Result, grads: ?[]const []f64) !void {
        if (grads != null) return error.Unsupported;
        const pairs = try self.allocator.alloc(Pair, degs.len);
        defer self.allocator.free(pairs);
        for (pairs, prepared.refs, degs) |*p, r, d| p.* = .{ .ref = r.samples, .deg = d };
        return self.measureBatch(pairs, prepared.sample_rate, num_threads, results);
    }

    const Shared = struct {
        engine: *CpuEngine,
        pairs: []const Pair,
        results: []anyerror!visqol.Result,
        sample_rate: u32,
        next: std.atomic.Value(usize) = .init(0),
    };

    fn worker(shared: *Shared) void {
        const e = shared.engine;
        const mapper = makeMapper(e.allocator, e.options, e.model_text) catch |err| return drain(shared, err);
        var v = visqol.Visqol.init(e.allocator, e.options, mapper) catch |err| return drain(shared, err);
        defer v.deinit();
        while (true) {
            const i = shared.next.fetchAdd(1, .monotonic);
            if (i >= shared.pairs.len) return;
            shared.results[i] = v.measure(shared.pairs[i].ref, shared.pairs[i].deg, shared.sample_rate);
        }
    }

    /// Claim and fail every remaining pair (a worker could not start).
    fn drain(shared: *Shared, err: anyerror) void {
        while (true) {
            const i = shared.next.fetchAdd(1, .monotonic);
            if (i >= shared.pairs.len) return;
            shared.results[i] = err;
        }
    }

    pub fn measureBatch(self: *CpuEngine, pairs: []const Pair, sample_rate: u32, num_threads: u32, results: []anyerror!visqol.Result) !void {
        const cpus = std.Thread.getCpuCount() catch 1;
        const want: usize = if (num_threads == 0) cpus else num_threads;
        const n_threads = @max(1, @min(want, pairs.len));
        var shared: Shared = .{ .engine = self, .pairs = pairs, .results = results, .sample_rate = sample_rate };
        if (n_threads == 1) {
            for (pairs, results) |p, *r| r.* = self.main.measure(p.ref, p.deg, sample_rate);
            return;
        }
        const threads = try self.allocator.alloc(std.Thread, n_threads - 1);
        defer self.allocator.free(threads);
        var spawned: usize = 0;
        defer for (threads[0..spawned]) |t| t.join();
        for (threads) |*t| {
            t.* = std.Thread.spawn(.{}, worker, .{&shared}) catch break;
            spawned += 1;
        }
        worker(&shared);
    }
};
