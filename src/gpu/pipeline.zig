// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! The whole model on the device, in T: f64 builds follow the CPU's
//! operation order (`exact` precision, where the device has f64), f32
//! builds serve fast and balanced (two-float where balanced has a build).
//! Signals go up once; the host reads back the global lags with the SPL
//! energies, plans sizes (frames, patches, VAD), and at the end reads each
//! patch's match and statistics to map scores.
const std = @import("std");
const zimt = @import("zimt");
const kernels = @import("visqol_kernels");
const visqol = @import("../visqol.zig");
const accel = @import("../accel.zig");
const audio = @import("../audio.zig");
const dp = @import("../dp.zig");
const vad = @import("../vad.zig");
const nsim = @import("../nsim.zig");
const gammatone = @import("../gammatone.zig");
const realign = @import("../realign.zig");
const xcorr = @import("../xcorr.zig");
const engine = @import("engine.zig");
const GpuAccel = engine.GpuAccel;
const Lane = GpuAccel.Lane;

/// Whether `ga` scores on the device: unless exact without f64 (Metal),
/// which keeps the CPU's f64 stages (`GpuAccel` as an `Accelerator`).
pub fn applies(ga: *const GpuAccel) bool {
    return ga.precision != .exact or ga.float64;
}

/// Scores `pairs` on the device; per-pair failures land in `results`.
/// With `grads` (each as long as its pair's deg), also ∂moslqo/∂deg, the
/// discrete choices (lags, matches, realignment, floors) held fixed; a
/// pair the CPU rescored fails with `error.GradientUnavailable`.
pub fn measureBatch(ga: *GpuAccel, v: *visqol.Visqol, pairs: []const visqol.Pair, sample_rate: u32, results: []anyerror!visqol.Result, grads: ?[]const []f64) !void {
    switch (v.impl) {
        inline else => |*p| switch (ga.precision) {
            inline else => |precision| return run(precision, ga, v, p, pairs, sample_rate, results, grads),
        },
    }
}

/// Samples per f32 SPL energy partial sum.
const ENERGY_BLOCK = 4096;

const u = struct {
    fn c(x: usize) u32 {
        return @intCast(x);
    }
}.c;

/// One pair through the host's plan.
const PairPlan = struct {
    failed: ?anyerror = null,
    ref: []const f64,
    deg: []const f64,
    /// In the signals buffer: ref, deg, then the aligned deg (room for
    /// deg + ref / 2 samples).
    ref_off: usize = 0,
    deg_off: usize = 0,
    al_off: usize = 0,
    lag: i64 = 0,
    lag_s: f64 = 0,
    aligned_len: usize = 0,
    zeros: usize = 0,
    skip: usize = 0,
    factor: f64 = 1,
    nf_ref: usize = 0,
    nf_deg: usize = 0,
    /// Linear spectrograms (and their prepared copies) at these offsets.
    ref_spec: usize = 0,
    deg_spec: usize = 0,
    ref_indices: []usize = &.{},
    first_patch: usize = 0,
    num_patches: usize = 0,
    /// DP and backtrace tables, num_patches × nf_deg.
    table: usize = 0,

    fn live(p: PairPlan) bool {
        return p.failed == null;
    }
};

fn run(
    comptime precision: visqol.Precision,
    ga: *GpuAccel,
    v: *visqol.Visqol,
    p: anytype,
    pairs: []const visqol.Pair,
    sample_rate: u32,
    results: []anyerror!visqol.Result,
    grads: ?[]const []f64,
) !void {
    const NB = @TypeOf(p.*).num_bands;
    const T = GpuAccel.Real(precision);
    // The CPU's serial sums; fast mode's are the device's f32 blocks.
    const host_energy = precision != .fast;
    const a = ga.allocator;
    const options = v.options;
    if (sample_rate == 0) return error.InvalidInput;
    try p.ensureCache(sample_rate);
    const window = p.cached_window_size;
    const hop = p.cached_hop_size;
    const fd = p.cached_frame_duration;
    const ps = p.patch_size;
    const params: accel.SpecParams = .{ .bands = &p.cached_filters.?.bands, .window_size = window, .hop_size = hop, .hann = p.cached_hann };

    const plans = try a.alloc(PairPlan, pairs.len);
    defer a.free(plans);
    defer for (plans) |pl| a.free(pl.ref_indices);
    var signal_len: usize = 0;
    for (plans, pairs) |*pl, pair| {
        pl.* = .{ .ref = pair.ref, .deg = pair.deg };
        pl.ref_off = signal_len;
        pl.deg_off = pl.ref_off + pair.ref.len;
        pl.al_off = pl.deg_off + pair.deg.len;
        signal_len = pl.al_off + pair.deg.len + pair.ref.len / 2;
    }
    if (signal_len > std.math.maxInt(u32)) return error.BatchTooLarge;

    // Global lags: device rows by FFT size, small ones on the CPU.
    const global = !options.disable_global_alignment;
    const order = try a.alloc(usize, pairs.len);
    defer a.free(order);
    for (order, 0..) |*o, i| o.* = i;
    const fft = struct {
        fn size(pl: PairPlan) usize {
            return GpuAccel.fftSize(pl.ref.len, pl.deg.len);
        }
        fn lt(ctx: []const PairPlan, x: usize, y: usize) bool {
            return size(ctx[x]) < size(ctx[y]);
        }
    };
    std.mem.sort(usize, order, @as([]const PairPlan, plans), fft.lt);
    const host_lags = try a.alloc(i64, pairs.len);
    defer a.free(host_lags);
    @memset(host_lags, 0);
    {
        var host: std.ArrayList(accel.LagJob) = .empty;
        defer host.deinit(a);
        for (plans, host_lags) |pl, *hl| {
            if (!global or pl.ref.len == 0 or pl.deg.len == 0 or fft.size(pl) >= GpuAccel.ENV_BLOCK) continue;
            try host.append(a, .{ .a = pl.ref, .b = pl.deg, .out = hl });
        }
        try ga.hostLags(host.items);
    }

    const lane = ga.acquire();
    defer lane.release();
    const dev = lane.device;
    var scope = dev.arena();
    defer scope.deinit();

    const sig = try uploadSignals(precision, ga, lane, &scope, plans, signal_len);
    const lags = try a.alloc(i32, pairs.len);
    defer a.free(lags);
    const status = try a.alloc(u32, pairs.len);
    defer a.free(status);
    // Fast mode's f32 block sums, added up in f64 on the host.
    var energy_blocks: usize = 1;
    for (plans) |pl| energy_blocks = @max(energy_blocks, std.math.divCeil(usize, @max(pl.ref.len, pl.deg.len), ENERGY_BLOCK) catch unreachable);
    const energy = try a.alloc(T, if (host_energy) 0 else pairs.len * 2 * energy_blocks);
    defer a.free(energy);
    {
        var gscope = dev.arena();
        defer gscope.deinit();
        // In `order`.
        const rows = try a.alloc(kernels.LagRow, pairs.len);
        defer a.free(rows);
        const sides = try a.alloc(kernels.PairSignals, pairs.len);
        defer a.free(sides);
        for (order, rows, sides, lags) |i, *r, *sd, *l| {
            const pl = plans[i];
            r.* = std.mem.zeroes(kernels.LagRow);
            r.a = .{ .start = u(pl.ref_off), .pad = 0, .len = u(pl.ref.len) };
            r.b = .{ .start = u(pl.deg_off), .pad = 0, .len = u(pl.deg.len) };
            sd.* = .{ .ref_off = u(pl.ref_off), .ref_len = u(pl.ref.len), .deg_off = u(pl.deg_off), .deg_len = u(pl.deg.len) };
            l.* = @intCast(host_lags[i]);
        }
        const d_rows = try gscope.allocInit(kernels.LagRow, rows);
        const d_lags = try gscope.allocInit(i32, lags);
        const d_status = try gscope.alloc(u32, .readback, pairs.len);
        try dev.zero(d_status, 0, pairs.len);
        var g: usize = 0;
        while (global and g < order.len) {
            const n = fft.size(plans[order[g]]);
            var e = g + 1;
            while (e < order.len and fft.size(plans[order[e]]) == n and (e - g + 1) * n <= engine.FFT_BATCH_POINTS) e += 1;
            defer g = e;
            if (n < GpuAccel.ENV_BLOCK) continue;
            const max_lags = try a.alloc(u32, e - g);
            defer a.free(max_lags);
            for (order[g..e], max_lags) |i, *m| m.* = u(@max(plans[i].ref.len, plans[i].deg.len) - 1);
            var ss = dev.arena();
            defer ss.deinit();
            try lane.searchGroup(T, &ss, sig.hi, d_rows, g, .{ .host = max_lags }, n, d_lags, d_status, precision == .exact, ga.lag_cap);
        }
        if (!host_energy) {
            const d_sides = try gscope.allocInit(kernels.PairSignals, sides);
            const d_energy = try gscope.alloc(T, .readback, energy.len);
            const k = lane.real(T, "spl_energy");
            try dev.dispatch1d(k, energy.len * engine.threadsOf(k), .{ .signals = sig.hi, .pairs = d_sides, .lags = d_lags, .energy = d_energy, .num_pairs = u(pairs.len), .block = ENERGY_BLOCK, .blocks = u(energy_blocks) });
            try dev.download(d_energy, 0, energy);
        }
        try dev.download(d_lags, 0, lags);
        try dev.download(d_status, 0, status);
    }

    // Plan: alignment, SPL factor, frames, patches.
    var num_patches: usize = 0;
    var spec_len: usize = 0;
    var table_len: usize = 0;
    for (order, 0..) |i, row| {
        const pl = &plans[i];
        pl.lag = if (global and pl.ref.len > 0 and pl.deg.len > 0) lags[row] else 0;
        var exact_energy = host_energy;
        if (status[row] != 0) {
            // More near-ties than the device rescores: the CPU's search.
            pl.lag = GpuAccel.hostLag(a, pl.ref, pl.deg) catch |err| {
                pl.failed = err;
                continue;
            };
            exact_energy = true;
        }
        var e_ref: f64 = 0;
        var e_deg: f64 = 0;
        if (exact_energy) {
            e_ref = sumSquares(pl.ref);
            e_deg = sumSquares(alignedDeg(pl.ref.len, pl.deg, pl.lag));
        } else {
            for (energy[row * 2 * energy_blocks ..][0..energy_blocks]) |x| e_ref += x;
            for (energy[(row * 2 + 1) * energy_blocks ..][0..energy_blocks]) |x| e_deg += x;
        }
        planPair(NB, pl, p, options, window, hop, sample_rate, e_ref, e_deg) catch |err| {
            pl.failed = err;
            continue;
        };
        pl.ref_spec = spec_len;
        pl.deg_spec = spec_len + NB * pl.nf_ref;
        spec_len += NB * (pl.nf_ref + pl.nf_deg);
        pl.first_patch = num_patches;
        num_patches += pl.num_patches;
        pl.table = table_len;
        table_len += pl.num_patches * pl.nf_deg;
    }
    if (spec_len > std.math.maxInt(u32) or table_len > std.math.maxInt(u32)) return error.BatchTooLarge;

    var out: Out(T) = try .init(a, num_patches, NB);
    defer out.deinit(a);
    var saved: Saved(T) = .{};
    defer saved.deinit(a);
    if (num_patches > 0) {
        try runModel(precision, NB, ga, lane, &scope, plans, sig, params, options, ps, sample_rate, fd, spec_len, table_len, &out, &saved);
    }

    // Map: the CPU's matches from the device's, then its result.
    for (plans, results, pairs) |pl, *r, pair| {
        if (pl.failed) |err| {
            r.* = err;
            continue;
        }
        var redo = false;
        for (out.status[pl.first_patch..][0..pl.num_patches]) |st| redo = redo or st == 1;
        if (redo) {
            r.* = if (grads != null) error.GradientUnavailable else v.measure(pair.ref, pair.deg, sample_rate);
            continue;
        }
        r.* = result(T, NB, a, pl, &out, &p.cached_filters.?.center_freqs, v.mapper, ps, fd, sample_rate);
    }
    if (grads) |g| {
        for (g, pairs) |x, pair| {
            std.debug.assert(x.len == pair.deg.len);
            @memset(x, 0);
        }
        if (num_patches > 0) try backward(precision, NB, ga, lane, plans, sig, params, &saved, &out, &v.mapper, ps, fd, sample_rate, results, g);
    }
}

fn sumSquares(x: []const f64) f64 {
    var e: f64 = 0;
    for (x) |s| e += s * s;
    return e;
}

/// The part of `deg` `applyLag` keeps: dropped leading samples only (its
/// zeros add nothing to sums of squares).
fn alignedDeg(ref_len: usize, deg: []const f64, lag: i64) []const f64 {
    if (lag >= 0 or @abs(lag) > ref_len / 2) return deg;
    return deg[@min(@as(usize, @intCast(-lag)), deg.len)..];
}

/// The host's part of `prepareSignals` and `planPair`.
fn planPair(comptime NB: usize, pl: *PairPlan, p: anytype, options: visqol.Options, window: usize, hop: usize, sample_rate: u32, e_ref: f64, e_deg: f64) !void {
    _ = NB;
    const sr_f: f64 = @floatFromInt(sample_rate);
    const r: i64 = @intCast(pl.ref.len);
    const d: i64 = @intCast(pl.deg.len);
    const shift: i64 = if (pl.lag == 0 or @abs(pl.lag) > @divTrunc(r, 2)) 0 else pl.lag;
    pl.zeros = @intCast(@max(shift, 0));
    pl.skip = @intCast(if (shift < 0) @min(-shift, d) else 0);
    pl.aligned_len = pl.deg.len + pl.zeros - pl.skip;
    pl.lag_s = if (shift == 0) 0.0 else @as(f64, @floatFromInt(shift)) / sr_f;
    pl.factor = audio.splFactor(audio.splOfEnergy(e_ref, pl.ref.len), audio.splOfEnergy(e_deg, pl.aligned_len));

    if (pl.ref.len <= window or pl.aligned_len <= window) return visqol.Error.SpectrogramTooShort;
    pl.nf_ref = gammatone.numFrames(pl.ref.len, window, hop);
    pl.nf_deg = gammatone.numFrames(pl.aligned_len, window, hop);
    const allocator = p.allocator;
    pl.ref_indices = switch (options.mode) {
        .audio => try dp.refPatchIndices(allocator, pl.nf_ref, p.patch_size),
        .speech => try vad.refPatchIndices(allocator, pl.ref, pl.nf_ref, p.patch_size, window, p.overlap),
    };
    if (pl.ref_indices.len == 0) return visqol.Error.NoPatches;
    pl.num_patches = try dp.searchPatches(pl.ref_indices, pl.nf_ref, pl.nf_deg, p.patch_size);
}

/// The signals buffer, and in balanced precision its lo parts.
fn Signals(comptime precision: visqol.Precision) type {
    return struct { hi: zimt.Buffer(GpuAccel.Real(precision)), lo: zimt.Buffer(f32) };
}

/// Up in the precision's type; f32 rounded on the host, balanced with what
/// that left in `lo`.
fn uploadSignals(comptime precision: visqol.Precision, ga: *GpuAccel, lane: *Lane, scope: *zimt.Arena, plans: []const PairPlan, len: usize) !Signals(precision) {
    const T = GpuAccel.Real(precision);
    const dev = lane.device;
    const out: Signals(precision) = .{
        .hi = try scope.alloc(T, .device, @max(len, 1)),
        .lo = try scope.alloc(f32, .device, if (precision == .balanced) @max(len, 1) else 1),
    };
    for (plans) |pl| {
        for ([_][]const f64{ pl.ref, pl.deg }, [_]usize{ pl.ref_off, pl.deg_off }) |x, at| {
            if (x.len == 0) continue;
            if (T == f64) {
                try dev.upload(out.hi, at, x);
                continue;
            }
            const hi = try ga.allocator.alloc(f32, x.len);
            defer ga.allocator.free(hi);
            const lo = try ga.allocator.alloc(f32, if (precision == .balanced) x.len else 0);
            defer ga.allocator.free(lo);
            GpuAccel.splitInto(f32, x, hi, if (precision == .balanced) lo else null);
            try dev.upload(out.hi, at, hi);
            if (precision == .balanced) try dev.upload(out.lo, at, lo);
        }
    }
    return out;
}

/// What the host reads back per patch.
fn Out(comptime T: type) type {
    return struct {
        const Self = @This();

        matches: []kernels.Match,
        similarity: []T,
        /// (patch, band, 3): mean, stddev, energy.
        stats: []T,
        realigned: []kernels.Realigned,
        /// Of the realignment lag search; 1: past `lag_cap`.
        status: []u32,

        fn init(a: std.mem.Allocator, n: usize, nb: usize) !Self {
            const self: Self = .{
                .matches = try a.alloc(kernels.Match, n),
                .similarity = try a.alloc(T, n),
                .stats = try a.alloc(T, n * nb * 3),
                .realigned = try a.alloc(kernels.Realigned, n),
                .status = try a.alloc(u32, n),
            };
            @memset(self.matches, std.mem.zeroes(kernels.Match));
            @memset(self.similarity, 0);
            @memset(self.stats, 0);
            @memset(self.realigned, std.mem.zeroes(kernels.Realigned));
            @memset(self.status, 0);
            return self;
        }

        fn deinit(self: *Self, a: std.mem.Allocator) void {
            a.free(self.matches);
            a.free(self.similarity);
            a.free(self.stats);
            a.free(self.realigned);
            a.free(self.status);
        }
    };
}

/// The forward's device buffers the backward reads.
fn Saved(comptime T: type) type {
    return struct {
        const Self = @This();

        specs: zimt.Buffer(kernels.SpecPair) = undefined,
        raw: zimt.Buffer(T) = undefined,
        prep: zimt.Buffer(T) = undefined,
        window_taps: zimt.Buffer(T) = undefined,
        c1: T = 0,
        c3: T = 0,
        match_pairs: zimt.Buffer(kernels.PatchPair) = undefined,
        active: zimt.Buffer(u32) = undefined,
        stats: zimt.Buffer(T) = undefined,
        realign: ?struct {
            /// Each row's patch (rows in lag-search order).
            row_patch: []u32,
            back: []u32,
            rows: zimt.Buffer(kernels.LagRow),
            lags: zimt.Buffer(i32),
            specs: zimt.Buffer(kernels.SpecPair),
            pairs: zimt.Buffer(kernels.PatchPair),
            active: zimt.Buffer(u32),
            raw: zimt.Buffer(T),
            prep: zimt.Buffer(T),
            stats: zimt.Buffer(T),
        } = null,

        fn deinit(self: *Self, a: std.mem.Allocator) void {
            if (self.realign) |r| {
                a.free(r.row_patch);
                a.free(r.back);
            }
        }
    };
}

/// Alignment, spectrograms, DP, matches and realignment, into `out`.
fn runModel(
    comptime precision: visqol.Precision,
    comptime NB: usize,
    ga: *GpuAccel,
    lane: *Lane,
    scope: *zimt.Arena,
    plans: []const PairPlan,
    sig: Signals(precision),
    params: accel.SpecParams,
    options: visqol.Options,
    patch_size: usize,
    sample_rate: u32,
    fd: f64,
    spec_len: usize,
    table_len: usize,
    out: *Out(GpuAccel.Real(precision)),
    saved: *Saved(GpuAccel.Real(precision)),
) !void {
    const T = GpuAccel.Real(precision);
    const a = ga.allocator;
    const dev = lane.device;
    const window = params.window_size;
    const hop = params.hop_size;
    const num_patches = out.matches.len;
    var live: std.ArrayList(usize) = .empty;
    defer live.deinit(a);
    for (plans, 0..) |pl, i| if (pl.live()) try live.append(a, i);

    // applyLag and scaleToMatchSpl into each aligned deg.
    {
        const aligns = try a.alloc(kernels.Alignment, live.items.len);
        defer a.free(aligns);
        // Balanced: hi and lo per pair.
        const per: usize = if (precision == .balanced) 2 else 1;
        const factors = try a.alloc(T, live.items.len * per);
        defer a.free(factors);
        var max_len: usize = 1;
        for (live.items, aligns, 0..) |i, *al, k| {
            const pl = plans[i];
            al.* = .{ .deg_off = u(pl.deg_off), .skip = u(pl.skip), .zeros = u(pl.zeros), .out_off = u(pl.al_off), .len = u(pl.aligned_len) };
            GpuAccel.splitInto(T, &.{pl.factor}, factors[k * per ..][0..1], if (precision == .balanced) factors[k * 2 + 1 ..][0..1] else null);
            max_len = @max(max_len, pl.aligned_len);
        }
        const d_aligns = try scope.allocInit(kernels.Alignment, aligns);
        const d_factors = try scope.allocInit(T, factors);
        if (precision == .balanced) {
            try dev.dispatch1d(lane.kbal.?.apply_lag_bal, live.items.len * max_len, .{ .signals = sig.hi, .alignments = d_aligns, .factors = d_factors, .out = sig.hi, .lo = sig.lo, .num_pairs = u(live.items.len), .max_len = u(max_len) });
        } else {
            try dev.dispatch1d(lane.real(T, "apply_lag"), live.items.len * max_len, .{ .signals = sig.hi, .alignments = d_aligns, .factors = d_factors, .out = sig.hi, .num_pairs = u(live.items.len), .max_len = u(max_len) });
        }
    }

    // Spectrograms of each ref and aligned deg, then their prepared copies.
    var tables = try engine.GpuAccel.FilterTables(precision).init(a, params);
    defer tables.deinit(a);
    const filter = try tables.upload(scope);
    const raw = try scope.alloc(T, .device, @max(spec_len, 1));
    const prep = try scope.alloc(T, .device, @max(spec_len, 1));
    {
        var frames: std.ArrayList(kernels.Frame) = .empty;
        defer frames.deinit(a);
        const specs = try a.alloc(kernels.SpecPair, live.items.len);
        defer a.free(specs);
        for (live.items, specs) |i, *sp| {
            const pl = plans[i];
            for (0..pl.nf_ref) |f| try frames.append(a, .{ .start = u(pl.ref_off + f * hop), .out = u(pl.ref_spec + f), .stride = u(pl.nf_ref) });
            for (0..pl.nf_deg) |f| try frames.append(a, .{ .start = u(pl.al_off + f * hop), .out = u(pl.deg_spec + f), .stride = u(pl.nf_deg) });
            sp.* = .{ .ref_off = u(pl.ref_spec), .ref_frames = u(pl.nf_ref), .deg_off = u(pl.deg_spec), .deg_frames = u(pl.nf_deg) };
        }
        const d_frames = try scope.allocInit(kernels.Frame, frames.items);
        if (precision == .balanced) {
            try dev.dispatch1d(lane.kbal.?.gammatone_frames_bal, frames.items.len * NB, .{ .signals = sig.hi, .signals_lo = sig.lo, .frames = d_frames, .coeffs = filter.coeffs, .hann = filter.hann, .out = raw, .num_frames = u(frames.items.len), .num_bands = NB, .window_size = u(window) });
        } else {
            try dev.dispatch1d(lane.real(T, "gammatone_frames"), frames.items.len * NB, .{ .signals = sig.hi, .frames = d_frames, .coeffs = filter.coeffs, .hann = filter.hann, .out = raw, .num_frames = u(frames.items.len), .num_bands = NB, .window_size = u(window) });
        }
        const k = lane.of(precision, "spec_prep");
        saved.specs = try scope.allocInit(kernels.SpecPair, specs);
        try dev.dispatch1d(k, live.items.len * engine.threadsOf(k), .{ .rows = saved.specs, .raw = raw, .out = prep, .num_rows = u(live.items.len), .num_bands = NB });
    }
    saved.raw = raw;
    saved.prep = prep;

    // DP similarities, the DP, then each match's statistics.
    const window_taps = try scope.allocInit(T, &taps(T));
    const cmp = nsim.Comparator.init(1.0);
    const c1: T = @floatCast((0.01 * cmp.intensity_range) * (0.01 * cmp.intensity_range));
    const c3: T = @floatCast((0.03 * cmp.intensity_range) * (0.03 * cmp.intensity_range) / 2.0);
    const searches = try a.alloc(kernels.PatchSearch, num_patches);
    defer a.free(searches);
    var tasks: std.ArrayList(kernels.SimTask) = .empty;
    defer tasks.deinit(a);
    const dp_pairs = try a.alloc(kernels.DpPair, live.items.len);
    defer a.free(dp_pairs);
    const tile = engine.threadsOf(lane.real(T, "nsim_table"));
    // Each deg spectrogram's plane, as wide as `nsim.DegPlane`.
    const planes = try a.alloc(kernels.DegPlane, live.items.len);
    defer a.free(planes);
    var plane_len: usize = 0;
    var max_cells: usize = 0;
    for (live.items, dp_pairs, planes) |i, *dpp, *plane| {
        const pl = plans[i];
        dpp.* = .{ .first = u(pl.first_patch), .patches = u(pl.num_patches), .deg_frames = u(pl.nf_deg), .table = u(pl.table) };
        var width = pl.nf_deg;
        for (pl.ref_indices[0..pl.num_patches]) |ri| width = @max(width, dp.searchWindow(ri, pl.nf_deg, patch_size, options.search_window_radius).hi + patch_size);
        plane.* = .{ .deg_off = u(pl.deg_spec), .deg_frames = u(pl.nf_deg), .plane = u(plane_len), .width = u(width) };
        plane_len += NB * width * 2;
        max_cells = @max(max_cells, NB * width);
        for (pl.ref_indices[0..pl.num_patches], 0..) |ri, pi| {
            const w = dp.searchWindow(ri, pl.nf_deg, patch_size, options.search_window_radius);
            const m = pl.first_patch + pi;
            searches[m] = .{
                .ref_off = u(pl.ref_spec),
                .ref_frames = u(pl.nf_ref),
                .ref_frame = u(ri),
                .deg_off = u(pl.deg_spec),
                .deg_frames = u(pl.nf_deg),
                .lo = u(w.lo),
                .hi = u(w.hi),
                .row = u(pl.table + pi * pl.nf_deg),
                .plane = plane.plane,
                .width = plane.width,
            };
            var off = w.lo;
            while (off <= w.hi) : (off += tile) try tasks.append(a, .{ .patch = u(m), .first = u(off) });
        }
    }
    const d_searches = try scope.allocInit(kernels.PatchSearch, searches);
    const deg_terms = try scope.alloc(T, .device, @max(plane_len, 1));
    const ref_terms = try scope.alloc(T, .device, num_patches * NB * patch_size * 2);
    try dev.dispatch1d(lane.real(T, "deg_plane"), live.items.len * max_cells, .{
        .deg_spec = prep,
        .window = window_taps,
        .planes = try scope.allocInit(kernels.DegPlane, planes),
        .deg_terms = deg_terms,
        .num_planes = u(live.items.len),
        .max_cells = u(max_cells),
        .num_bands = NB,
    });
    try dev.dispatch1d(lane.real(T, "ref_terms"), num_patches * NB * patch_size, .{
        .ref_spec = prep,
        .window = window_taps,
        .patches = d_searches,
        .ref_terms = ref_terms,
        .num_patches = u(num_patches),
        .num_bands = NB,
        .patch_size = u(patch_size),
    });
    const sims = try scope.alloc(T, .device, @max(table_len, 1));
    try dev.dispatch1d(lane.real(T, "nsim_table"), tasks.items.len * tile, .{
        .ref_spec = prep,
        .deg_spec = prep,
        .window = window_taps,
        .patches = d_searches,
        .tasks = try scope.allocInit(kernels.SimTask, tasks.items),
        .ref_terms = ref_terms,
        .deg_terms = deg_terms,
        .sims = sims,
        .num_tasks = u(tasks.items.len),
        .num_bands = NB,
        .patch_size = u(patch_size),
        .c1 = c1,
        .c3 = c3,
    });
    const dp_table = try scope.alloc(T, .device, @max(table_len, 1));
    const bt = try scope.alloc(u32, .device, @max(table_len, 1));
    const matches = try scope.alloc(kernels.Match, .readback, num_patches);
    try dev.zero(dp_table, 0, dp_table.len);
    try dev.zero(bt, 0, bt.len);
    try dev.zero(matches, 0, num_patches);
    const dp_k = lane.real(T, "dp_search");
    try dev.dispatch1d(dp_k, live.items.len * engine.threadsOf(dp_k), .{
        .pairs = try scope.allocInit(kernels.DpPair, dp_pairs),
        .patches = d_searches,
        .sims = sims,
        .dp = dp_table,
        .bt = bt,
        .matches = matches,
        .num_pairs = u(live.items.len),
    });
    const match_pairs = try scope.alloc(kernels.PatchPair, .device, num_patches);
    const active = try scope.alloc(u32, .device, num_patches);
    const stats = try scope.alloc(T, .readback, num_patches * NB * 3);
    const similarity = try scope.alloc(T, .readback, num_patches);
    try dev.zero(stats, 0, stats.len);
    try dev.zero(similarity, 0, num_patches);
    try dev.dispatch1d(lane.real(T, "match_rows"), num_patches, .{ .patches = d_searches, .matches = matches, .rows = match_pairs, .active = active, .num_patches = u(num_patches), .patch_size = u(patch_size) });
    try dev.dispatch1d(lane.of(precision, "nsim_bands"), num_patches * NB, .{
        .ref_spec = prep,
        .deg_spec = prep,
        .window = window_taps,
        .rows = match_pairs,
        .active = active,
        .stats = stats,
        .num_rows = u(num_patches),
        .num_bands = NB,
        .c1 = c1,
        .c3 = c3,
    });
    try dev.dispatch1d(lane.real(T, "match_finalize"), num_patches, .{ .matches = matches, .stats = stats, .similarity = similarity, .num_patches = u(num_patches), .num_bands = NB });
    saved.window_taps = window_taps;
    saved.c1 = c1;
    saved.c3 = c3;
    saved.match_pairs = match_pairs;
    saved.active = active;
    saved.stats = stats;

    const realigned = try scope.alloc(kernels.Realigned, .readback, num_patches);
    try dev.zero(realigned, 0, num_patches);
    if (!options.disable_realignment) {
        try realignStage(precision, NB, ga, lane, scope, plans, live.items, sig, raw, filter, window_taps, c1, c3, params, patch_size, sample_rate, fd, matches, stats, similarity, realigned, out, saved);
    }
    try dev.download(matches, 0, out.matches);
    try dev.download(similarity, 0, out.similarity);
    try dev.download(stats, 0, out.stats);
    try dev.download(realigned, 0, out.realigned);
}

/// `trim.slang`'s `trim`: the applied lag, where the ref starts (the deg at
/// head - lag) and the length both keep.
const Trim = struct {
    lag: i32,
    head: i32,
    len: i32,

    fn of(r: kernels.LagRow, lag_in: i32, back: []const u32) Trim {
        const ra: i32 = @intCast(r.a.pad + r.a.len);
        const d: i32 = @intCast(r.b.pad + r.b.len);
        const lag: i32 = if (lag_in == 0 or @abs(lag_in) > @divTrunc(ra, 2)) 0 else lag_in;
        const dl = if (lag < 0) d - @min(-lag, d) else d + lag;
        var t: Trim = .{ .lag = lag, .head = 0, .len = ra };
        if (ra > dl) {
            t.len = dl;
        } else if (ra < dl and lag > 0) {
            const l: u32 = @intCast(lag);
            t.head = lag - @as(i32, @intCast((back[l / 32] >> @intCast(l % 32)) & 1));
            if (t.head > 0) t.len = ra - t.head else t.head = 0;
        }
        return t;
    }

    fn frames(t: Trim, window: usize, hop: usize) usize {
        return if (t.len < window) 0 else 1 + (@as(usize, @intCast(t.len)) - window) / hop;
    }
};

/// ∂moslqo/∂deg into `grads`: the stats' gradients on the host, back
/// through NSIM, spectrogram preparation and the gammatone filters on the
/// device, then the lag and SPL scaling on the host.
fn backward(
    comptime precision: visqol.Precision,
    comptime NB: usize,
    ga: *GpuAccel,
    lane: *Lane,
    plans: []const PairPlan,
    sig: Signals(precision),
    params: accel.SpecParams,
    saved: *const Saved(GpuAccel.Real(precision)),
    out: *const Out(GpuAccel.Real(precision)),
    mapper: *const visqol.QualityMapper,
    patch_size: usize,
    fd: f64,
    sample_rate: u32,
    results: []anyerror!visqol.Result,
    grads: []const []f64,
) !void {
    const T = GpuAccel.Real(precision);
    const a = ga.allocator;
    const dev = lane.device;
    const window = params.window_size;
    const hop = params.hop_size;
    const num_patches = out.matches.len;
    if (window > 4096) return error.Unsupported;
    var scope = dev.arena();
    defer scope.deinit();

    // The pairs scored on the device.
    var live: std.ArrayList(usize) = .empty;
    defer live.deinit(a);
    for (plans, results, 0..) |pl, r, i| {
        if (!pl.live()) continue;
        _ = r catch continue;
        try live.append(a, i);
    }
    if (live.items.len == 0) return;

    // ∂moslqo/∂stats per patch: to its match row, or its realignment row
    // where that was accepted.
    const num_rows = if (saved.realign) |r| r.row_patch.len else 0;
    const row_of = try a.alloc(u32, num_patches);
    defer a.free(row_of);
    if (saved.realign) |r| for (r.row_patch, 0..) |m, row| {
        row_of[m] = u(row);
    };
    const g_match = try a.alloc(T, num_patches * NB * 3);
    defer a.free(g_match);
    const g_row = try a.alloc(T, @max(num_rows, 1) * NB * 3);
    defer a.free(g_row);
    @memset(g_match, 0);
    @memset(g_row, 0);
    for (live.items) |i| {
        const pl = plans[i];
        var matches = try pairMatches(T, NB, a, pl, out, patch_size, fd, sample_rate);
        defer matches.deinit();
        const g = try a.alloc(f64, pl.num_patches * NB * 3);
        defer a.free(g);
        try visqol.buildResultGrad(a, NB, &matches, fd, mapper, g);
        for (0..pl.num_patches) |k| {
            const m = pl.first_patch + k;
            const dst = if (out.realigned[m].accepted != 0) g_row[row_of[m] * NB * 3 ..] else g_match[m * NB * 3 ..];
            for (dst[0 .. NB * 3], g[k * NB * 3 ..][0 .. NB * 3]) |*d, x| d.* = @floatCast(x);
        }
    }

    // Spectrogram gradients: the match rows into the pairs' prepared
    // spectrograms, then through `spec_prep`.
    const spec_len = saved.prep.len;
    const g_raw = try scope.alloc(T, .device, spec_len);
    {
        var gathers: std.ArrayList(kernels.SpecGather) = .empty;
        defer gathers.deinit(a);
        var max_cells: usize = 0;
        for (live.items) |i| {
            const pl = plans[i];
            try gathers.append(a, .{ .off = u(pl.ref_spec), .frames = u(pl.nf_ref), .side = 0, .first = u(pl.first_patch), .count = u(pl.num_patches) });
            try gathers.append(a, .{ .off = u(pl.deg_spec), .frames = u(pl.nf_deg), .side = 1, .first = u(pl.first_patch), .count = u(pl.num_patches) });
            max_cells = @max(max_cells, NB * @max(pl.nf_ref, pl.nf_deg));
        }
        const g_prep = try patchGrads(T, NB, lane, &scope, saved.prep, saved.window_taps, saved.c1, saved.c3, saved.match_pairs, saved.active, saved.stats, g_match, num_patches, patch_size, gathers.items, max_cells, spec_len);
        try dev.zero(g_raw, 0, spec_len);
        const k = lane.real(T, "spec_prep_bwd");
        // `specs` lists every live pair of the forward, in plan order.
        try dev.dispatch1d(k, saved.specs.len * engine.threadsOf(k), .{ .rows = saved.specs, .raw = saved.raw, .out = saved.prep, .g_out = g_prep, .g_raw = g_raw, .num_rows = u(saved.specs.len), .num_bands = NB });
    }

    // Each degraded frame, as runs of frames per pair: its global frames,
    // then its accepted realignment rows'.
    var frames: std.ArrayList(kernels.FrameGrad) = .empty;
    defer frames.deinit(a);
    var row_frames: std.ArrayList(kernels.FrameGrad) = .empty;
    defer row_frames.deinit(a);
    var runs: std.ArrayList(kernels.FrameRun) = .empty;
    defer runs.deinit(a);
    const signals = try a.alloc(kernels.SignalGrad, live.items.len);
    defer a.free(signals);
    var g_pspec: ?zimt.Buffer(T) = null;
    var lag_rows: []kernels.LagRow = &.{};
    defer a.free(lag_rows);
    var row_lags: []i32 = &.{};
    defer a.free(row_lags);
    var rows_of_pair: []std.ArrayList(usize) = try a.alloc(std.ArrayList(usize), plans.len);
    defer {
        for (rows_of_pair) |*l| l.deinit(a);
        a.free(rows_of_pair);
    }
    for (rows_of_pair) |*l| l.* = .empty;
    if (saved.realign) |r| {
        lag_rows = try a.alloc(kernels.LagRow, num_rows);
        row_lags = try a.alloc(i32, num_rows);
        try dev.download(r.rows, 0, lag_rows);
        try dev.download(r.lags, 0, row_lags);
        const pairs = try a.alloc(kernels.PatchPair, num_rows);
        defer a.free(pairs);
        const active = try a.alloc(u32, num_rows);
        defer a.free(active);
        try dev.download(r.pairs, 0, pairs);
        try dev.download(r.active, 0, active);
        var gathers: std.ArrayList(kernels.SpecGather) = .empty;
        defer gathers.deinit(a);
        var max_cols: usize = 1;
        var max_cells: usize = 0;
        for (r.row_patch, pairs, active, 0..) |m, pp, on, row| {
            if (on == 0 or out.realigned[m].accepted == 0) continue;
            max_cols = @max(max_cols, pp.cols);
            max_cells = @max(max_cells, NB * pp.cols);
            try gathers.append(a, .{ .off = pp.ref_off, .frames = pp.ref_frames, .side = 0, .first = u(row), .count = 1 });
            try gathers.append(a, .{ .off = pp.deg_off, .frames = pp.deg_frames, .side = 1, .first = u(row), .count = 1 });
        }
        for (live.items) |i| {
            const pl = plans[i];
            for (r.row_patch, 0..) |m, row| {
                if (m >= pl.first_patch and m < pl.first_patch + pl.num_patches and active[row] != 0 and out.realigned[m].accepted != 0) try rows_of_pair[i].append(a, row);
            }
        }
        if (gathers.items.len > 0) {
            const g_prep = try patchGrads(T, NB, lane, &scope, r.prep, saved.window_taps, saved.c1, saved.c3, r.pairs, r.active, r.stats, g_row, num_rows, max_cols, gathers.items, max_cells, r.prep.len);
            const gp = try scope.alloc(T, .device, r.raw.len);
            try dev.zero(gp, 0, gp.len);
            const k = lane.real(T, "spec_prep_bwd");
            try dev.dispatch1d(k, num_rows * engine.threadsOf(k), .{ .rows = r.specs, .raw = r.raw, .out = r.prep, .g_out = g_prep, .g_raw = gp, .num_rows = u(num_rows), .num_bands = NB });
            g_pspec = gp;
        }
    }

    var grad_len: usize = 0;
    var max_len: usize = 1;
    for (live.items, signals) |i, *sg| {
        const pl = plans[i];
        sg.* = .{ .start = u(pl.al_off), .len = u(pl.aligned_len), .first_run = u(runs.items.len), .runs = 0, .out = u(grad_len) };
        grad_len += pl.aligned_len;
        max_len = @max(max_len, pl.aligned_len);
        const at = (frames.items.len + row_frames.items.len) * window;
        try runs.append(a, .{ .start = @intCast(pl.al_off), .count = u(pl.nf_deg), .out = u(at) });
        for (0..pl.nf_deg) |f| try frames.append(a, .{ .start = @intCast(pl.al_off + f * hop), .lo = u(pl.al_off), .hi = u(pl.al_off + pl.aligned_len), .grad = u(pl.deg_spec + f), .stride = u(pl.nf_deg), .out = u(at + f * window) });
        if (saved.realign) |r| for (rows_of_pair[i].items) |row| {
            const lr = lag_rows[row];
            const t = Trim.of(lr, row_lags[row], r.back);
            const n = t.frames(window, hop);
            if (n == 0) continue;
            const off: i64 = t.head - t.lag;
            const sd = lr.b;
            const first: i64 = @as(i64, sd.start) - sd.pad + off;
            // Frames on the deg grid were copied from it: whole frames of the aligned deg.
            var lo: u32 = sd.start;
            var hi: u32 = sd.start + sd.len;
            if (lr.b_grid > 0 and off >= sd.pad) {
                const start: usize = @intCast(@as(i64, lr.b_base) + off - sd.pad);
                if (start % hop == 0 and start / hop + n <= lr.b_grid) {
                    lo = u(pl.al_off);
                    hi = u(pl.al_off + pl.aligned_len);
                }
            }
            const rat = (frames.items.len + row_frames.items.len) * window;
            try runs.append(a, .{ .start = @intCast(first), .count = u(n), .out = u(rat) });
            const deg_base = lr.first_slot * 2 * NB + NB * lr.slots;
            for (0..n) |f| try row_frames.append(a, .{ .start = @intCast(first + @as(i64, @intCast(f * hop))), .lo = lo, .hi = hi, .grad = u(deg_base + f), .stride = u(n), .out = u(rat + f * window) });
        };
        sg.runs = u(runs.items.len) - sg.first_run;
    }

    // Direct-form coefficients (as gammatone_common's EXACT) and the window, in T.
    const coeffs = try a.alloc(T, NB * 8);
    defer a.free(coeffs);
    for (params.bands, 0..) |band, b| {
        const gi = 1.0 / band.gain;
        const c = [8]f64{ band.a0 * gi, band.a11 * gi, band.a12, band.a13, band.a14, band.a0, band.b1, band.b2 };
        for (coeffs[b * 8 ..][0..8], c) |*d, x| d.* = @floatCast(x);
    }
    const hann = try a.alloc(T, window);
    defer a.free(hann);
    for (hann, params.hann[0..window]) |*d, x| d.* = @floatCast(x);
    const d_coeffs = try scope.allocInit(T, coeffs);
    const d_hann = try scope.allocInit(T, hann);
    const frame_grads = try scope.alloc(T, .device, @max((frames.items.len + row_frames.items.len) * window, 1));
    const gk = lane.real(T, "gammatone_bwd");
    for ([_][]const kernels.FrameGrad{ frames.items, row_frames.items }, [_]?zimt.Buffer(T){ g_raw, g_pspec }) |list, grad| {
        if (list.len == 0) continue;
        try dev.dispatch1d(gk, list.len * engine.threadsOf(gk), .{
            .signals = sig.hi,
            .frames = try scope.allocInit(kernels.FrameGrad, list),
            .coeffs = d_coeffs,
            .hann = d_hann,
            .grad = grad.?,
            .grads = frame_grads,
            .num_frames = u(list.len),
            .num_bands = NB,
            .window_size = u(window),
        });
    }
    const g_al = try scope.alloc(T, .readback, @max(grad_len, 1));
    try dev.dispatch1d(lane.real(T, "signal_grad"), live.items.len * max_len, .{
        .signals = try scope.allocInit(kernels.SignalGrad, signals),
        .runs = try scope.allocInit(kernels.FrameRun, runs.items),
        .grads = frame_grads,
        .out = g_al,
        .num_signals = u(live.items.len),
        .max_len = u(max_len),
        .window_size = u(window),
        .hop_size = u(hop),
    });
    const host = try a.alloc(T, grad_len);
    defer a.free(host);
    try dev.download(g_al, 0, host);

    // aligned[t] = factor · deg[t - zeros + skip], factor = C / sqrt(Σ deg[skip..]²).
    for (live.items, signals) |i, sg| {
        const pl = plans[i];
        const g = grads[i];
        const ga_al = host[sg.out..][0..pl.aligned_len];
        var dot: f64 = 0;
        for (ga_al[pl.zeros..], pl.zeros..) |x, t| {
            const j = t - pl.zeros + pl.skip;
            g[j] = pl.factor * @as(f64, x);
            dot += @as(f64, x) * pl.factor * pl.deg[j];
        }
        const e_ref = sumSquares(pl.ref);
        const e_deg = sumSquares(pl.deg[pl.skip..]);
        const scaled = std.math.isFinite(audio.splOfEnergy(e_ref, pl.ref.len)) and std.math.isFinite(audio.splOfEnergy(e_deg, pl.aligned_len));
        if (scaled and e_deg > 0) {
            for (g[pl.skip..], pl.deg[pl.skip..]) |*x, d| x.* -= dot * d / e_deg;
        }
    }
}

/// The prepared spectrograms' gradients from rows' ∂L/∂stats (`g_stats`,
/// host side): per cell window, per patch cell, then per spectrogram cell
/// of `gathers`; zero elsewhere.
fn patchGrads(
    comptime T: type,
    comptime NB: usize,
    lane: *Lane,
    scope: *zimt.Arena,
    prep: zimt.Buffer(T),
    window_taps: zimt.Buffer(T),
    c1: T,
    c3: T,
    rows: zimt.Buffer(kernels.PatchPair),
    active: zimt.Buffer(u32),
    stats: zimt.Buffer(T),
    g_stats: []const T,
    num_rows: usize,
    max_cols: usize,
    gathers: []const kernels.SpecGather,
    max_cells: usize,
    len: usize,
) !zimt.Buffer(T) {
    const dev = lane.device;
    const d_g = try scope.allocInit(T, g_stats);
    const cells = try scope.alloc(T, .device, num_rows * NB * max_cols * 18);
    const patch = try scope.alloc(T, .device, num_rows * 2 * NB * max_cols);
    try dev.dispatch1d(lane.real(T, "nsim_bands_bwd"), num_rows * NB * max_cols, .{
        .ref_spec = prep,
        .deg_spec = prep,
        .window = window_taps,
        .rows = rows,
        .active = active,
        .stats = stats,
        .g_stats = d_g,
        .cells = cells,
        .num_rows = u(num_rows),
        .num_bands = NB,
        .max_cols = u(max_cols),
        .c1 = c1,
        .c3 = c3,
    });
    try dev.dispatch1d(lane.real(T, "nsim_cells_bwd"), num_rows * 2 * NB * max_cols, .{ .rows = rows, .active = active, .g_stats = d_g, .cells = cells, .patch_grad = patch, .num_rows = u(num_rows), .num_bands = NB, .max_cols = u(max_cols) });
    const g_prep = try scope.alloc(T, .device, @max(len, 1));
    try dev.zero(g_prep, 0, g_prep.len);
    try dev.dispatch1d(lane.real(T, "spec_grad"), gathers.len * max_cells, .{
        .specs = try scope.allocInit(kernels.SpecGather, gathers),
        .rows = rows,
        .active = active,
        .patch_grad = patch,
        .out = g_prep,
        .num_specs = u(gathers.len),
        .max_cells = u(max_cells),
        .num_bands = NB,
        .max_cols = u(max_cols),
    });
    return g_prep;
}

/// `taps(T)[(dr + 1) * 3 + dc + 1]` weighs the neighbour at (dr, dc), as
/// `Taps.at` (the window flipped).
fn taps(comptime T: type) [9]T {
    var w: [9]T = undefined;
    for (0..3) |i| for (0..3) |j| {
        w[i * 3 + j] = @floatCast(nsim.WINDOW[2 - i][2 - j]);
    };
    return w;
}

/// `planRealign`, the lag searches, `prepareRealign` and `finishRealign`.
fn realignStage(
    comptime precision: visqol.Precision,
    comptime NB: usize,
    ga: *GpuAccel,
    lane: *Lane,
    scope: *zimt.Arena,
    plans: []const PairPlan,
    live: []const usize,
    sig: Signals(precision),
    raw: zimt.Buffer(GpuAccel.Real(precision)),
    filter: GpuAccel.FilterTables(precision).Device,
    window_taps: zimt.Buffer(GpuAccel.Real(precision)),
    c1: GpuAccel.Real(precision),
    c3: GpuAccel.Real(precision),
    params: accel.SpecParams,
    patch_size: usize,
    sample_rate: u32,
    fd: f64,
    matches: zimt.Buffer(kernels.Match),
    stats: zimt.Buffer(GpuAccel.Real(precision)),
    similarity: zimt.Buffer(GpuAccel.Real(precision)),
    realigned: zimt.Buffer(kernels.Realigned),
    out: *Out(GpuAccel.Real(precision)),
    saved: *Saved(GpuAccel.Real(precision)),
) !void {
    const T = GpuAccel.Real(precision);
    const a = ga.allocator;
    const dev = lane.device;
    const window = params.window_size;
    const hop = params.hop_size;
    const sr_f: f64 = @floatFromInt(sample_rate);
    const patch_dur = fd * @as(f64, @floatFromInt(patch_size));
    const num_patches = out.matches.len;

    // Rows by FFT size; the deg slice's length bounds it.
    const Row = struct { patch: usize, pair: usize, ri: usize, n: usize };
    const rows = try a.alloc(Row, num_patches);
    defer a.free(rows);
    const deg_bound: usize = @as(usize, @intFromFloat(patch_dur * sr_f)) + 2;
    var half: usize = 0;
    for (live) |i| {
        const pl = plans[i];
        for (pl.ref_indices[0..pl.num_patches], 0..) |ri, pi| {
            const l = refLayout(pl, ri, fd, patch_dur, sample_rate);
            rows[pl.first_patch + pi] = .{ .patch = pl.first_patch + pi, .pair = i, .ri = ri, .n = @max(GpuAccel.fftSize(l.pad + l.len, deg_bound), GpuAccel.ENV_BLOCK) };
            half = @max(half, (l.pad + l.len) / 2);
        }
    }
    const Lt = struct {
        fn lt(_: void, x: Row, y: Row) bool {
            return x.n < y.n;
        }
    };
    std.mem.sort(Row, rows, {}, Lt.lt);

    // Each live pair's aligned deg `sliceLayout` per DP offset.
    var slices: std.ArrayList(kernels.Side) = .empty;
    defer slices.deinit(a);
    const slice_at = try a.alloc(usize, plans.len);
    defer a.free(slice_at);
    for (live) |i| {
        const pl = plans[i];
        slice_at[i] = slices.items.len;
        for (0..pl.nf_deg) |k| {
            const start = @as(f64, @floatFromInt(k)) * fd;
            const l = realign.sliceLayout(pl.aligned_len, sample_rate, start, start + patch_dur);
            try slices.append(a, .{ .start = u(l.base), .pad = u(l.pad), .len = u(l.len) });
        }
    }

    const lag_rows = try a.alloc(kernels.LagRow, num_patches);
    defer a.free(lag_rows);
    const patches = try a.alloc(kernels.RealignPatch, num_patches);
    defer a.free(patches);
    var num_slots: usize = 0;
    for (rows, lag_rows, patches) |r, *lr, *rp| {
        const pl = plans[r.pair];
        const l = refLayout(pl, r.ri, fd, patch_dur, sample_rate);
        const slots = gammatone.numFrames(l.pad + l.len, window, hop);
        lr.* = std.mem.zeroes(kernels.LagRow);
        lr.a = .{ .start = u(pl.ref_off + l.base), .pad = u(l.pad), .len = u(l.len) };
        lr.first_slot = u(num_slots);
        lr.slots = u(slots);
        lr.a_base = u(l.base);
        lr.a_grid = u(pl.nf_ref);
        lr.b_grid = u(pl.nf_deg);
        lr.a_raw = u(pl.ref_spec);
        lr.b_raw = u(pl.deg_spec);
        num_slots += slots;
        rp.* = .{ .patch = u(r.patch), .deg_off = u(pl.al_off), .slices = u(slice_at[r.pair]) };
    }
    if (num_slots * 2 * NB > std.math.maxInt(u32)) return error.BatchTooLarge;
    const slot_rows = try a.alloc(u32, @max(num_slots, 1));
    defer a.free(slot_rows);
    for (lag_rows, 0..) |lr, i| @memset(slot_rows[lr.first_slot..][0..lr.slots], u(i));
    const back = try GpuAccel.lagBackTable(a, half, sample_rate);
    defer a.free(back);

    const d_rows = try scope.allocInit(kernels.LagRow, lag_rows);
    const d_patches = try scope.allocInit(kernels.RealignPatch, patches);
    const d_params = try scope.alloc(kernels.LagParams, .device, num_patches);
    const d_back = try scope.allocInit(u32, back);
    try dev.dispatch1d(lane.real(T, "realign_rows"), num_patches, .{
        .patches = d_patches,
        .matches = matches,
        .slices = try scope.allocInit(kernels.Side, slices.items),
        .rows = d_rows,
        .params = d_params,
        .num_rows = u(num_patches),
    });

    const lags = try scope.alloc(i32, .device, num_patches);
    const status = try scope.alloc(u32, .readback, num_patches);
    try dev.zero(lags, 0, num_patches);
    try dev.zero(status, 0, num_patches);
    var g: usize = 0;
    while (g < rows.len) {
        var e = g + 1;
        while (e < rows.len and rows[e].n == rows[g].n and (e - g + 1) * rows[g].n <= engine.FFT_BATCH_POINTS) e += 1;
        defer g = e;
        var ss = dev.arena();
        defer ss.deinit();
        try lane.searchGroup(T, &ss, sig.hi, d_rows, g, .{ .device = d_params.sub(g, e - g) }, rows[g].n, lags, status, precision == .exact, ga.lag_cap);
    }

    const specs = try scope.alloc(kernels.SpecPair, .device, num_patches);
    const pairs = try scope.alloc(kernels.PatchPair, .device, num_patches);
    const active = try scope.alloc(u32, .device, num_patches);
    try dev.dispatch1d(lane.real(T, "realign_frames"), num_patches, .{
        .patches = d_patches,
        .matches = matches,
        .rows = d_rows,
        .lags = lags,
        .status = status,
        .back = d_back,
        .specs = specs,
        .pairs = pairs,
        .active = active,
        .realigned = realigned,
        .num_rows = u(num_patches),
        .num_bands = NB,
        .window_size = u(window),
        .hop_size = u(hop),
    });
    const pspec = try scope.alloc(T, .device, @max(num_slots * 2 * NB, 1));
    const pprep = try scope.alloc(T, .device, pspec.len);
    if (num_slots > 0) {
        const d_slots = try scope.allocInit(u32, slot_rows);
        const total = u(num_slots * 2 * NB);
        if (precision == .balanced) {
            try dev.dispatch1d(lane.kbal.?.gammatone_patches_bal, num_slots * 2 * NB, .{
                .signals = sig.hi,
                .signals_lo = sig.lo,
                .rows = d_rows,
                .slots = d_slots,
                .lags = lags,
                .status = status,
                .back = d_back,
                .coeffs = filter.coeffs,
                .hann = filter.hann,
                .raw = raw,
                .out = pspec,
                .copy_raw = 1,
                .first_slot = 0,
                .total = total,
                .num_bands = NB,
                .window_size = u(window),
                .hop_size = u(hop),
            });
        } else {
            try dev.dispatch1d(lane.real(T, "gammatone_patches"), num_slots * 2 * NB, .{
                .signals = sig.hi,
                .rows = d_rows,
                .slots = d_slots,
                .lags = lags,
                .status = status,
                .back = d_back,
                .coeffs = filter.coeffs,
                .hann = filter.hann,
                .raw = raw,
                .out = pspec,
                .copy_raw = 1,
                .first_slot = 0,
                .total = total,
                .num_bands = NB,
                .window_size = u(window),
                .hop_size = u(hop),
            });
        }
    }
    const k = lane.of(precision, "spec_prep");
    try dev.dispatch1d(k, num_patches * engine.threadsOf(k), .{ .rows = specs, .raw = pspec, .out = pprep, .num_rows = u(num_patches), .num_bands = NB });
    const rstats = try scope.alloc(T, .device, num_patches * NB * 3);
    try dev.dispatch1d(lane.of(precision, "nsim_bands"), num_patches * NB, .{
        .ref_spec = pprep,
        .deg_spec = pprep,
        .window = window_taps,
        .rows = pairs,
        .active = active,
        .stats = rstats,
        .num_rows = u(num_patches),
        .num_bands = NB,
        .c1 = c1,
        .c3 = c3,
    });
    try dev.dispatch1d(lane.real(T, "realign_accept"), num_patches, .{
        .patches = d_patches,
        .active = active,
        .rstats = rstats,
        .stats = stats,
        .similarity = similarity,
        .realigned = realigned,
        .num_rows = u(num_patches),
        .num_bands = NB,
    });
    const row_status = try a.alloc(u32, num_patches);
    defer a.free(row_status);
    try dev.download(status, 0, row_status);
    for (rows, row_status) |r, st| out.status[r.patch] = st;

    const row_patch = try a.alloc(u32, num_patches);
    errdefer a.free(row_patch);
    for (rows, row_patch) |r, *rp| rp.* = u(r.patch);
    saved.realign = .{
        .row_patch = row_patch,
        .back = try a.dupe(u32, back),
        .rows = d_rows,
        .lags = lags,
        .specs = specs,
        .pairs = pairs,
        .active = active,
        .raw = pspec,
        .prep = pprep,
        .stats = rstats,
    };
}

/// The ref slice `planRealign` cuts for the patch at frame `ri`.
fn refLayout(pl: PairPlan, ri: usize, fd: f64, patch_dur: f64, sample_rate: u32) realign.SliceLayout {
    const start = @as(f64, @floatFromInt(ri)) * fd;
    return realign.sliceLayout(pl.ref.len, sample_rate, start, start + patch_dur);
}

/// The CPU's `Matches` from the device's, then `buildResult`.
fn result(
    comptime T: type,
    comptime NB: usize,
    a: std.mem.Allocator,
    pl: PairPlan,
    out: *const Out(T),
    center_freqs: *const [NB]f64,
    mapper: visqol.QualityMapper,
    patch_size: usize,
    fd: f64,
    sample_rate: u32,
) !visqol.Result {
    var matches = try pairMatches(T, NB, a, pl, out, patch_size, fd, sample_rate);
    defer matches.deinit();
    return visqol.buildResult(a, NB, &matches, fd, mapper, center_freqs, pl.lag_s);
}

/// The CPU's `Matches` from the device's.
fn pairMatches(
    comptime T: type,
    comptime NB: usize,
    a: std.mem.Allocator,
    pl: PairPlan,
    out: *const Out(T),
    patch_size: usize,
    fd: f64,
    sample_rate: u32,
) !dp.Matches {
    const sr_f: f64 = @floatFromInt(sample_rate);
    const patch_dur = fd * @as(f64, @floatFromInt(patch_size));
    const items = try a.alloc(dp.Match, pl.num_patches);
    for (items) |*m| m.* = .{ .freq_band_means = &.{}, .freq_band_stddevs = &.{}, .freq_band_deg_energy = &.{} };
    var matches: dp.Matches = .{ .items = items, .num_bands = NB, .allocator = a };
    errdefer matches.deinit();
    for (items, 0..) |*item, i| {
        const m = pl.first_patch + i;
        item.freq_band_means = try a.alloc(f64, NB);
        item.freq_band_stddevs = try a.alloc(f64, NB);
        item.freq_band_deg_energy = try a.alloc(f64, NB);
        for (0..NB) |b| {
            const st = out.stats[(m * NB + b) * 3 ..][0..3];
            item.freq_band_means[b] = st[0];
            item.freq_band_stddevs[b] = st[1];
            item.freq_band_deg_energy[b] = st[2];
        }
        const mt = out.matches[m];
        // Not reached by the backtrack: the CPU's defaults.
        if (mt.visited == 0) continue;
        item.similarity = out.similarity[m];
        item.valid = mt.valid != 0;
        item.ref_patch_start_time = @as(f64, @floatFromInt(pl.ref_indices[i])) * fd;
        item.ref_patch_end_time = item.ref_patch_start_time + patch_dur;
        if (item.valid) {
            item.deg_patch_start_time = @as(f64, @floatFromInt(mt.deg_frame)) * fd;
            item.deg_patch_end_time = item.deg_patch_start_time + patch_dur;
        }
        const ra = out.realigned[m];
        if (ra.accepted == 0) continue;
        // finishRealign
        const l = realign.sliceLayout(pl.ref.len, sample_rate, item.ref_patch_start_time, item.ref_patch_end_time);
        const geo = realign.trimGeometry(l.pad + l.len, ra.deg_total, ra.lag, sample_rate);
        const new_dur = @as(f64, @floatFromInt(geo.len)) / sr_f;
        if (geo.lag_seconds > 0.0) {
            item.ref_patch_start_time += geo.lag_seconds;
        } else {
            item.deg_patch_start_time -= geo.lag_seconds;
        }
        item.ref_patch_end_time = item.ref_patch_start_time + new_dur;
        item.deg_patch_end_time = item.deg_patch_start_time + new_dur;
    }
    return matches;
}

const backend = @import("../backend.zig");

fn expectResult(exact: bool, want: visqol.Result, got: visqol.Result) !void {
    const tol: f64 = if (exact) 0 else 1e-4;
    const close = struct {
        fn f(e: bool, t: f64, x: f64, y: f64) !void {
            if (e) return std.testing.expectEqual(x, y);
            try std.testing.expectApproxEqAbs(x, y, t);
        }
    }.f;
    try close(exact, tol, want.moslqo, got.moslqo);
    try close(exact, tol, want.alignment_lag_s, got.alignment_lag_s);
    inline for (.{ "fvnsim", "fvnsim10", "fstdnsim", "fvdegenergy" }) |f| {
        for (@field(want, f), @field(got, f)) |x, y| try close(exact, tol, x, y);
    }
    try std.testing.expectEqual(want.patch_sims.len, got.patch_sims.len);
    for (want.patch_sims, got.patch_sims) |x, y| {
        inline for (.{ "similarity", "ref_patch_start_time", "ref_patch_end_time", "deg_patch_start_time", "deg_patch_end_time" }) |f| {
            try close(exact, if (exact) 0 else 2e-3, @field(x, f), @field(y, f));
        }
    }
}

test "device pipeline: f64 reproduces the CPU bit for bit, f32 closely" {
    const allocator = std.testing.allocator;
    const sub = "tests/data/conformance_testdata_subset/";
    const cs = "tests/data/clean_speech/";
    const cases = [_]struct { mode: visqol.Mode, ref: []const u8, deg: []const u8 }{
        .{ .mode = .audio, .ref = sub ++ "contrabassoon48_stereo.wav", .deg = sub ++ "contrabassoon48_stereo_24kbps_aac.wav" },
        .{ .mode = .audio, .ref = sub ++ "strauss48_stereo.wav", .deg = sub ++ "strauss48_stereo_lp35.wav" },
        .{ .mode = .speech, .ref = cs ++ "CA01_01.wav", .deg = cs ++ "transcoded_CA01_01.wav" },
    };
    var ran = false;
    for (std.enums.values(zimt.Backend)) |b| for ([_]visqol.Precision{ .exact, .balanced, .fast }) |precision| {
        const ga = GpuAccel.create(allocator, b, precision) catch |e| switch (e) {
            error.BackendUnavailable => continue,
            else => return e,
        };
        defer ga.destroy();
        // Without f64, exact keeps the CPU's f64 stages instead.
        if (!applies(ga)) continue;
        for (cases) |c| {
            var ref = audio.loadAsMono(allocator, c.ref) catch return error.SkipZigTest;
            defer ref.deinit();
            var deg = audio.loadAsMono(allocator, c.deg) catch return error.SkipZigTest;
            defer deg.deinit();
            const options: visqol.Options = .{ .mode = c.mode, .use_lattice_model = c.mode == .speech, .precision = precision };
            var v = try visqol.Visqol.init(allocator, options, try backend.makeMapper(allocator, options, backend.defaultModel(options)));
            defer v.deinit();
            var want = try v.measure(ref.samples, deg.samples, ref.sample_rate);
            defer want.deinit();
            var got: [1]anyerror!visqol.Result = undefined;
            try measureBatch(ga, &v, &.{.{ .ref = ref.samples, .deg = deg.samples }}, ref.sample_rate, &got, null);
            var g = try got[0];
            defer g.deinit();
            try expectResult(precision == .exact, want, g);
        }
        std.debug.print("device pipeline: {t} {t} on {s}\n", .{ precision, b, ga.lanes[0].?.device.name() });
        ran = true;
    };
    if (!ran) return error.SkipZigTest;
}

fn mosOf(ga: *GpuAccel, v: *visqol.Visqol, ref: []const f64, deg: []const f64, sample_rate: u32, grad: ?[]f64) !visqol.Result {
    var got: [1]anyerror!visqol.Result = undefined;
    try measureBatch(ga, v, &.{.{ .ref = ref, .deg = deg }}, sample_rate, &got, if (grad) |g| &.{g} else null);
    return got[0];
}

fn sameChoices(x: visqol.Result, y: visqol.Result) bool {
    if (x.patch_sims.len != y.patch_sims.len or x.alignment_lag_s != y.alignment_lag_s) return false;
    for (x.patch_sims, y.patch_sims) |p, q| {
        if (p.ref_patch_start_time != q.ref_patch_start_time or p.deg_patch_start_time != q.deg_patch_start_time or p.deg_patch_end_time != q.deg_patch_end_time) return false;
    }
    return true;
}

test "device pipeline: gradient matches central differences, f32 tracks f64" {
    const allocator = std.testing.allocator;
    const sub = "tests/data/conformance_testdata_subset/";
    const cs = "tests/data/clean_speech/";
    const cases = [_]struct { mode: visqol.Mode, lattice: bool = false, ref: []const u8, deg: []const u8 }{
        .{ .mode = .audio, .ref = sub ++ "strauss48_stereo.wav", .deg = sub ++ "strauss48_stereo_lp35.wav" },
        .{ .mode = .audio, .ref = sub ++ "contrabassoon48_stereo.wav", .deg = sub ++ "contrabassoon48_stereo_24kbps_aac.wav" },
        .{ .mode = .speech, .ref = cs ++ "CA01_01.wav", .deg = cs ++ "transcoded_CA01_01.wav" },
        .{ .mode = .speech, .lattice = true, .ref = cs ++ "CA01_01.wav", .deg = cs ++ "transcoded_CA01_01.wav" },
    };
    var ran = false;
    for ([_]zimt.Backend{ .cuda, .vulkan }) |b| {
        const exact = GpuAccel.create(allocator, b, .exact) catch |e| switch (e) {
            error.BackendUnavailable => continue,
            else => return e,
        };
        defer exact.destroy();
        if (!exact.float64) continue;
        for (cases) |c| {
            var ref = audio.loadAsMono(allocator, c.ref) catch return error.SkipZigTest;
            defer ref.deinit();
            var deg = audio.loadAsMono(allocator, c.deg) catch return error.SkipZigTest;
            defer deg.deinit();
            const options: visqol.Options = .{ .mode = c.mode, .use_lattice_model = c.lattice };
            var v = try visqol.Visqol.init(allocator, options, try backend.makeMapper(allocator, options, backend.defaultModel(options)));
            defer v.deinit();
            const sr = ref.sample_rate;
            const g = try allocator.alloc(f64, deg.samples.len);
            defer allocator.free(g);
            var base = try mosOf(exact, &v, ref.samples, deg.samples, sr, g);
            defer base.deinit();

            // Random unit directions: g·d against (mos(x + εd) - mos(x - εd)) / 2ε.
            var prng = std.Random.DefaultPrng.init(0x5eed);
            const rnd = prng.random();
            const d = try allocator.alloc(f64, deg.samples.len);
            defer allocator.free(d);
            const x = try allocator.alloc(f64, deg.samples.len);
            defer allocator.free(x);
            // The lattice is piecewise linear and evaluates in f32: its steps
            // must move it by many ulps, and differences hold to ~5%.
            const eps: f64 = if (c.lattice) 3e-3 else 1e-5;
            var g_norm: f64 = 0;
            for (g) |gi| g_norm += gi * gi;
            g_norm = @sqrt(g_norm);
            var worst: f64 = 0;
            for (0..3) |_| {
                var norm: f64 = 0;
                for (d) |*di| {
                    di.* = rnd.floatNorm(f64);
                    norm += di.* * di.*;
                }
                var want: f64 = 0;
                for (d, g) |*di, gi| {
                    di.* /= @sqrt(norm);
                    want += di.* * gi;
                }
                var mos: [2]f64 = undefined;
                for ([_]f64{ eps, -eps }, &mos) |e, *m| {
                    for (x, deg.samples, d) |*xi, s, di| xi.* = s + e * di;
                    var r = try mosOf(exact, &v, ref.samples, x, sr, null);
                    defer r.deinit();
                    try std.testing.expect(sameChoices(base, r));
                    m.* = r.moslqo;
                }
                const fd = (mos[0] - mos[1]) / (2 * eps);
                worst = @max(worst, @abs(fd - want) / @abs(fd));
                const rel: f64 = if (c.lattice) 5e-2 else 1e-3;
                try std.testing.expectApproxEqAbs(fd, want, rel * @abs(fd) + 1e-5 * g_norm);
            }

            var rels: [2]f64 = undefined;
            // f32 builds against the f64 gradient.
            inline for (.{ visqol.Precision.fast, visqol.Precision.balanced }, &rels) |precision, *rel_out| {
                const ga = try GpuAccel.create(allocator, b, precision);
                defer ga.destroy();
                const g32 = try allocator.alloc(f64, deg.samples.len);
                defer allocator.free(g32);
                var r = try mosOf(ga, &v, ref.samples, deg.samples, sr, g32);
                defer r.deinit();
                var diff: f64 = 0;
                var size: f64 = 0;
                for (g, g32) |p, q| {
                    diff += (p - q) * (p - q);
                    size += p * p;
                }
                rel_out.* = @sqrt(diff / size);
                try std.testing.expect(rel_out.* < 1e-2);
            }
            std.debug.print("gradient on {t}, {s}{s}: vs central differences {e:.1}; fast, balanced vs f64 {e:.1}, {e:.1}\n", .{ b, std.fs.path.basename(c.deg), if (c.lattice) " (lattice)" else "", worst, rels[0], rels[1] });
        }
        ran = true;
    }
    if (!ran) return error.SkipZigTest;
}

test "gammatone backward matches central differences of the CPU filterbank" {
    const allocator = std.testing.allocator;
    const sr: u32 = 48000;
    const NB = 32;
    const filters = gammatone.Filters(NB).init(sr, 50.0, 24000.0);
    const ws: usize = 3840;
    const hann = try allocator.alloc(f64, ws);
    defer allocator.free(hann);
    gammatone.hannWindow(ws, hann);
    var prng = std.Random.DefaultPrng.init(3);
    const rnd = prng.random();
    var x: [ws]f64 = undefined;
    for (&x) |*s| s.* = 0.1 * rnd.floatNorm(f64);
    var gb: [NB]f64 = undefined;
    for (&gb) |*g| g.* = rnd.floatNorm(f64);
    const loss = struct {
        fn f(fl: anytype, h: []const f64, sig: []const f64, g: []const f64) f64 {
            var w: [ws]f64 = undefined;
            for (&w, sig, h) |*o, s, hh| o.* = s * hh;
            var l: f64 = 0;
            for (fl.bands, g) |band, gi| l += gi * gammatone.filterBandRmsFresh(band, &w);
            return l;
        }
    }.f;
    const ga = GpuAccel.create(allocator, .cuda, .exact) catch return error.SkipZigTest;
    defer ga.destroy();
    if (!ga.float64) return error.SkipZigTest;
    const lane = ga.acquire();
    defer lane.release();
    const dev = lane.device;
    var scope = dev.arena();
    defer scope.deinit();
    var coeffs: [NB * 8]f64 = undefined;
    for (filters.bands, 0..) |band, b| {
        const gi = 1.0 / band.gain;
        coeffs[b * 8 ..][0..8].* = .{ band.a0 * gi, band.a11 * gi, band.a12, band.a13, band.a14, band.a0, band.b1, band.b2 };
    }
    const out = try scope.alloc(f64, .readback, ws);
    const fr = [_]kernels.FrameGrad{.{ .start = 0, .lo = 0, .hi = ws, .grad = 0, .stride = 1, .out = 0 }};
    const k = lane.real(f64, "gammatone_bwd");
    try dev.dispatch1d(k, engine.threadsOf(k), .{
        .signals = try scope.allocInit(f64, &x),
        .frames = try scope.allocInit(kernels.FrameGrad, &fr),
        .coeffs = try scope.allocInit(f64, &coeffs),
        .hann = try scope.allocInit(f64, hann),
        .grad = try scope.allocInit(f64, &gb),
        .grads = out,
        .num_frames = 1,
        .num_bands = NB,
        .window_size = ws,
    });
    var got: [ws]f64 = undefined;
    try dev.download(out, 0, &got);
    var worst: f64 = 0;
    for ([_]usize{ 0, 1, 31, 32, 63, 64, 991, 1000, 2880, 2911, 3839 }) |j| {
        var y = x;
        const h = 1e-6;
        y[j] = x[j] + h;
        const up = loss(filters, hann, &y, &gb);
        y[j] = x[j] - h;
        const down = loss(filters, hann, &y, &gb);
        const cd = (up - down) / (2 * h);
        worst = @max(worst, @abs(cd - got[j]));
    }
    var largest: f64 = 0;
    for (got) |v| largest = @max(largest, @abs(v));
    try std.testing.expect(worst < 1e-6 * largest);
}

test "nsim backward matches central differences beside a silent reference" {
    const allocator = std.testing.allocator;
    const ga = GpuAccel.create(allocator, .cuda, .exact) catch return error.SkipZigTest;
    defer ga.destroy();
    if (!ga.float64) return error.SkipZigTest;
    const lane = ga.acquire();
    defer lane.release();
    const dev = lane.device;
    var scope = dev.arena();
    defer scope.deinit();
    const NB = 7;
    const cols = 7;
    // ref (NB, cols) then deg (NB, cols): contrabassoon around band 22, frame 364.
    const spec = [2 * NB * cols]f64{
        2.96856108177539820, 3.67188762495687370, 4.75163221275552400, 5.38719267570785800, 5.44681217810485700, 4.48020995284284100, 3.84323495673001500,
        2.16903693348019300, 1.70620203480871170, 2.54008730917163900, 3.17797227061273450, 3.44683253742547900, 2.99890096590598180, 1.73913841381336450,
        0.55345063100589440, 0.18153692307269154, 0.43106553359726973, 0,                   0,                   0,                   0,
        0,                   0,                   0,                   0,                   0,                   0,                   0,
        0.12846954386578346, 0.28734778774285274, 0.22767008222064078, 0,                   0,                   0,                   0,
        0.30574495140761115, 0.25902979977644947, 0,                   0,                   0,                   0,                   0,
        0,                   0,                   0,                   0,                   0,                   0,                   0,
        3.42049712657014740, 4.17133489097896200, 5.54906142634718700, 6.21551341983749950, 6.44507205162854300, 5.75721069191466500, 4.17077133206959200,
        2.21469770025635900, 1.43181593933577030, 2.42618496219024140, 2.99547772363823840, 3.18128146171978440, 3.34061046405459900, 2.11063431705386500,
        1.76639321404701380, 0.91498238961293050, 1.18047283437498150, 1.25381597614732240, 0.37105234702722356, 0.02268735575298564, 0,
        0,                   0,                   0,                   0.00432372571879114, 0,                   0,                   0,
        0,                   0,                   0,                   0,                   0,                   0,                   0,
        0,                   0,                   0,                   0,                   0,                   0,                   0,
        0,                   0,                   0,                   0,                   0,                   0,                   0,
    };
    const pp = [_]kernels.PatchPair{.{ .ref_off = 0, .ref_frames = cols, .ref_frame = 0, .deg_off = NB * cols, .deg_frames = cols, .deg_frame = 0, .cols = cols }};
    const cmp = nsim.Comparator.init(1.0);
    const c1: f64 = (0.01 * cmp.intensity_range) * (0.01 * cmp.intensity_range);
    const c3: f64 = (0.03 * cmp.intensity_range) * (0.03 * cmp.intensity_range) / 2.0;
    const d_rows = try scope.allocInit(kernels.PatchPair, &pp);
    const d_active = try scope.allocInit(u32, &.{1});
    const d_taps = try scope.allocInit(f64, &taps(f64));
    const d_spec = try scope.alloc(f64, .device, spec.len);
    const st = try scope.alloc(f64, .readback, NB * 3);
    const fwd = struct {
        fn f(dv: *zimt.Device, ln: *Lane, sp: zimt.Buffer(f64), rows: zimt.Buffer(kernels.PatchPair), act: zimt.Buffer(u32), tp: zimt.Buffer(f64), out: zimt.Buffer(f64), cc1: f64, cc3: f64) !f64 {
            try dv.zero(out, 0, out.len);
            try dv.dispatch1d(ln.real(f64, "nsim_bands"), NB, .{ .ref_spec = sp, .deg_spec = sp, .window = tp, .rows = rows, .active = act, .stats = out, .num_rows = 1, .num_bands = NB, .c1 = cc1, .c3 = cc3 });
            var h: [NB * 3]f64 = undefined;
            try dv.download(out, 0, &h);
            var l: f64 = 0;
            for (0..NB) |b| l += h[b * 3];
            return l;
        }
    }.f;
    try dev.upload(d_spec, 0, &spec);
    _ = try fwd(dev, lane, d_spec, d_rows, d_active, d_taps, st, c1, c3);
    var g_stats: [NB * 3]f64 = @splat(0);
    for (0..NB) |b| g_stats[b * 3] = 1;
    const gathers = [_]kernels.SpecGather{ .{ .off = 0, .frames = cols, .side = 0, .first = 0, .count = 1 }, .{ .off = NB * cols, .frames = cols, .side = 1, .first = 0, .count = 1 } };
    const g = try patchGrads(f64, NB, lane, &scope, d_spec, d_taps, c1, c3, d_rows, d_active, st, &g_stats, 1, cols, &gathers, NB * cols, spec.len);
    var got: [spec.len]f64 = undefined;
    try dev.download(g, 0, &got);
    var worst: f64 = 0;
    var largest: f64 = 0;
    for (NB * cols..spec.len) |k| {
        var x = spec;
        const h = 1e-8;
        x[k] = spec[k] + h;
        try dev.upload(d_spec, 0, &x);
        const up = try fwd(dev, lane, d_spec, d_rows, d_active, d_taps, st, c1, c3);
        x[k] = spec[k] - h;
        try dev.upload(d_spec, 0, &x);
        const down = try fwd(dev, lane, d_spec, d_rows, d_active, d_taps, st, c1, c3);
        const cd = (up - down) / (2 * h);
        worst = @max(worst, @abs(cd - got[k]));
        largest = @max(largest, @abs(cd));
    }
    try std.testing.expect(worst < 1e-6 * largest);
}
