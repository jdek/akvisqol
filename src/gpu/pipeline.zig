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
pub fn measureBatch(ga: *GpuAccel, v: *visqol.Visqol, pairs: []const visqol.Pair, sample_rate: u32, results: []anyerror!visqol.Result) !void {
    switch (v.impl) {
        inline else => |*p| switch (ga.precision) {
            inline else => |precision| return run(precision, ga, v, p, pairs, sample_rate, results),
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
    if (num_patches > 0) {
        try runModel(precision, NB, ga, lane, &scope, plans, sig, params, options, ps, sample_rate, fd, spec_len, table_len, &out);
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
            r.* = v.measure(pair.ref, pair.deg, sample_rate);
            continue;
        }
        r.* = result(T, NB, a, pl, &out, &p.cached_filters.?.center_freqs, v.mapper, ps, fd, sample_rate);
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
        try dev.dispatch1d(k, live.items.len * engine.threadsOf(k), .{ .rows = try scope.allocInit(kernels.SpecPair, specs), .raw = raw, .out = prep, .num_rows = u(live.items.len), .num_bands = NB });
    }

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

    const realigned = try scope.alloc(kernels.Realigned, .readback, num_patches);
    try dev.zero(realigned, 0, num_patches);
    if (!options.disable_realignment) {
        try realignStage(precision, NB, ga, lane, scope, plans, live.items, sig, raw, filter, window_taps, c1, c3, params, patch_size, sample_rate, fd, matches, stats, similarity, realigned, out);
    }
    try dev.download(matches, 0, out.matches);
    try dev.download(similarity, 0, out.similarity);
    try dev.download(stats, 0, out.stats);
    try dev.download(realigned, 0, out.realigned);
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
    const sr_f: f64 = @floatFromInt(sample_rate);
    const patch_dur = fd * @as(f64, @floatFromInt(patch_size));
    const items = try a.alloc(dp.Match, pl.num_patches);
    for (items) |*m| m.* = .{ .freq_band_means = &.{}, .freq_band_stddevs = &.{}, .freq_band_deg_energy = &.{} };
    var matches: dp.Matches = .{ .items = items, .num_bands = NB, .allocator = a };
    defer matches.deinit();
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
    return visqol.buildResult(a, NB, &matches, fd, mapper, center_freqs, pl.lag_s);
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
            try measureBatch(ga, &v, &.{.{ .ref = ref.samples, .deg = deg.samples }}, ref.sample_rate, &got);
            var g = try got[0];
            defer g.deinit();
            try expectResult(precision == .exact, want, g);
        }
        std.debug.print("device pipeline: {t} {t} on {s}\n", .{ precision, b, ga.lanes[0].?.device.name() });
        ran = true;
    };
    if (!ran) return error.SkipZigTest;
}
