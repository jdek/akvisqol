// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Per-patch fine alignment and rescoring (upstream
//! `ComparisonPatchesSelector::FinelyAlignAndRecreatePatches`).
const std = @import("std");
const envelope = @import("envelope.zig");
const xcorr = @import("xcorr.zig");
const gammatone = @import("gammatone.zig");
const spectrogram = @import("spectrogram.zig");
const nsim = @import("nsim.zig");
const dp = @import("dp.zig");
const accel = @import("accel.zig");

pub const Error = error{
    OutOfMemory,
    AlignmentFailed,
    SpectrogramTooShort,
};

/// Slice `[start_time .. end_time]`, zero-padding out-of-range parts.
/// Upstream quirks kept: the end index is clamped to `len - 1` and used
/// exclusively (drops the last sample), and all padding is prepended.
pub fn sliceAudio(
    allocator: std.mem.Allocator,
    signal: []const f64,
    sample_rate: u32,
    start_time: f64,
    end_time: f64,
) ![]f64 {
    const l = sliceLayout(signal.len, sample_rate, start_time, end_time);
    const out = try allocator.alloc(f64, l.pad + l.len);
    @memset(out[0..l.pad], 0.0);
    @memcpy(out[l.pad..], signal[l.base .. l.base + l.len]);
    return out;
}

/// `sliceAudio` result shape: `pad` zeros, then `signal[base .. base + len]`.
pub const SliceLayout = struct { pad: usize, base: usize, len: usize };

pub fn sliceLayout(signal_len: usize, sample_rate: u32, start_time: f64, end_time: f64) SliceLayout {
    const sr_f: f64 = @floatFromInt(sample_rate);
    const n: i64 = @intCast(signal_len);
    const start_idx: i64 = @max(0, @as(i64, @intFromFloat(start_time * sr_f)));
    const end_idx: i64 = @min(n - 1, @as(i64, @intFromFloat(end_time * sr_f)));
    const real_len: usize = if (end_idx > start_idx) @intCast(end_idx - start_idx) else 0;
    const end_diff = end_time * sr_f - @as(f64, @floatFromInt(signal_len));
    const post_pad: usize = if (end_diff > 0.0) @intFromFloat(end_diff) else 0;
    const pre_pad: usize = if (start_time < 0.0) @intFromFloat(-start_time * sr_f) else 0;
    return .{ .pad = pre_pad + post_pad, .base = if (real_len > 0) @intCast(start_idx) else 0, .len = real_len };
}

pub const Aligned = struct {
    deg: []f64,
    lag_seconds: f64,
    deg_owned: bool,
    /// `deg_out[i] = deg_in[i - lag_samples]`, zero when out of range.
    lag_samples: i64 = 0,
};

/// Align `deg` to `ref` by envelope cross-correlation. The batched
/// pipeline runs the same phases separately to offload the lag search.
pub fn globallyAlign(
    allocator: std.mem.Allocator,
    cache: *xcorr.Cache,
    ref: []const f64,
    deg: []const f64,
    sample_rate: u32,
) !Aligned {
    if (ref.len == 0 or deg.len == 0) return applyLag(allocator, ref.len, deg, 0, sample_rate);
    const env = try alignmentEnvelopes(allocator, ref, deg);
    defer allocator.free(env.ref);
    defer allocator.free(env.deg);
    const lag = try xcorr.bestLagCached(cache, env.ref, env.deg);
    return applyLag(allocator, ref.len, deg, lag, sample_rate);
}

pub const Envelopes = struct { ref: []f64, deg: []f64 };

/// Upper envelopes of `ref` and `deg`; both caller-owned.
pub fn alignmentEnvelopes(allocator: std.mem.Allocator, ref: []const f64, deg: []const f64) !Envelopes {
    const env_ref = try allocator.alloc(f64, ref.len);
    errdefer allocator.free(env_ref);
    const env_deg = try allocator.alloc(f64, deg.len);
    envelope.upperEnvelope(ref, env_ref);
    envelope.upperEnvelope(deg, env_deg);
    return .{ .ref = env_ref, .deg = env_deg };
}

/// Shift `deg` by `lag`. Lags beyond half the reference are ignored, as upstream.
pub fn applyLag(allocator: std.mem.Allocator, ref_len: usize, deg: []const f64, lag: i64, sample_rate: u32) !Aligned {
    const half_ref: i64 = @intCast(ref_len / 2);
    if (lag == 0 or @abs(lag) > half_ref) {
        return .{ .deg = try allocator.dupe(f64, deg), .lag_seconds = 0.0, .deg_owned = true };
    }

    const sr_f: f64 = @floatFromInt(sample_rate);
    const lag_seconds: f64 = @as(f64, @floatFromInt(lag)) / sr_f;
    if (lag < 0) {
        const k: usize = @min(@as(usize, @intCast(-lag)), deg.len);
        const out = try allocator.dupe(f64, deg[k..]);
        return .{ .deg = out, .lag_seconds = lag_seconds, .deg_owned = true, .lag_samples = lag };
    } else {
        const k: usize = @intCast(lag);
        const out = try allocator.alloc(f64, k + deg.len);
        @memset(out[0..k], 0.0);
        @memcpy(out[k .. k + deg.len], deg);
        return .{ .deg = out, .lag_seconds = lag_seconds, .deg_owned = true, .lag_samples = lag };
    }
}

/// Both buffers are caller-owned.
pub const Trimmed = struct {
    ref: []f64,
    deg: []f64,
    lag_seconds: f64,
    /// `ref[i] = ref_in[ref_off + i]`.
    ref_off: usize = 0,
    /// `deg[i] = deg_in[deg_off + i]` (negative: leading lag zeros).
    deg_off: i64 = 0,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Trimmed) void {
        self.allocator.free(self.ref);
        self.allocator.free(self.deg);
    }
};

/// Align `deg` to `ref` and truncate both to a shared length.
pub fn alignAndTruncate(
    allocator: std.mem.Allocator,
    cache: *xcorr.Cache,
    ref: []const f64,
    deg: []const f64,
    sample_rate: u32,
) !Trimmed {
    var lag: i64 = 0;
    if (ref.len > 0 and deg.len > 0) {
        const env = try alignmentEnvelopes(allocator, ref, deg);
        defer allocator.free(env.ref);
        defer allocator.free(env.deg);
        lag = try xcorr.bestLagCached(cache, env.ref, env.deg);
    }
    return truncateAligned(allocator, ref, deg, lag, sample_rate);
}

pub fn truncateAligned(
    allocator: std.mem.Allocator,
    ref: []const f64,
    deg: []const f64,
    lag: i64,
    sample_rate: u32,
) !Trimmed {
    var aligned = try applyLag(allocator, ref.len, deg, lag, sample_rate);
    errdefer if (aligned.deg_owned) allocator.free(aligned.deg);

    const ref_len = ref.len;
    const deg_len = aligned.deg.len;
    const sr_f: f64 = @floatFromInt(sample_rate);

    var ref_out: []f64 = undefined;
    var deg_out: []f64 = undefined;
    var head: usize = 0; // samples dropped from the front of both

    if (ref_len > deg_len) {
        ref_out = try allocator.dupe(f64, ref[0..deg_len]);
        deg_out = aligned.deg; // takes ownership
    } else if (ref_len < deg_len) {
        const lag_samples_i: i64 = @intFromFloat(aligned.lag_seconds * sr_f);
        if (lag_samples_i > 0) {
            const ls: usize = @intCast(lag_samples_i);
            head = ls;
            const r_view = ref[ls..];
            ref_out = try allocator.dupe(f64, r_view);
            const d_take = @min(ls + ref_out.len, aligned.deg.len);
            deg_out = try allocator.dupe(f64, aligned.deg[ls..d_take]);
            allocator.free(aligned.deg);
            aligned.deg_owned = false;
        } else {
            deg_out = try allocator.dupe(f64, aligned.deg[0..ref_len]);
            allocator.free(aligned.deg);
            aligned.deg_owned = false;
            ref_out = try allocator.dupe(f64, ref);
        }
    } else {
        ref_out = try allocator.dupe(f64, ref);
        deg_out = aligned.deg;
    }

    const min_len = @min(ref_out.len, deg_out.len);
    if (ref_out.len > min_len) {
        const tr = try allocator.dupe(f64, ref_out[0..min_len]);
        allocator.free(ref_out);
        ref_out = tr;
    }
    if (deg_out.len > min_len) {
        const td = try allocator.dupe(f64, deg_out[0..min_len]);
        allocator.free(deg_out);
        deg_out = td;
    }

    return .{
        .ref = ref_out,
        .deg = deg_out,
        .lag_seconds = aligned.lag_seconds,
        .ref_off = head,
        .deg_off = @as(i64, @intCast(head)) - aligned.lag_samples,
        .allocator = allocator,
    };
}

/// `truncateAligned` without the copies: `ref_out[i] = ref[ref_off + i]`
/// and `deg_out[i] = deg[deg_off + i]` (zero outside `deg`), `len` long.
pub const Geometry = struct {
    len: usize,
    ref_off: usize,
    deg_off: i64,
    lag_seconds: f64,
};

/// `lag` samples to seconds and back, truncating: lag - 1 for some lags
/// (27 at 48 kHz), which upstream's head trim keeps.
pub fn lagSamplesBack(lag: i64, sample_rate: u32) i64 {
    const sr_f: f64 = @floatFromInt(sample_rate);
    const seconds: f64 = @as(f64, @floatFromInt(lag)) / sr_f;
    return @intFromFloat(seconds * sr_f);
}

pub fn trimGeometry(ref_len: usize, deg_len: usize, lag: i64, sample_rate: u32) Geometry {
    const r: i64 = @intCast(ref_len);
    const d: i64 = @intCast(deg_len);
    // applyLag
    const shift: i64 = if (lag == 0 or @abs(lag) > ref_len / 2) 0 else lag;
    const dl = if (shift < 0) d - @min(-shift, d) else d + shift;
    var head: i64 = 0;
    var len = r;
    if (r > dl) {
        len = dl;
    } else if (r < dl and shift > 0) {
        head = @max(lagSamplesBack(shift, sample_rate), 0);
        len = r - head;
    }
    const sr_f: f64 = @floatFromInt(sample_rate);
    return .{
        .len = @intCast(len),
        .ref_off = @intCast(head),
        .deg_off = head - shift,
        .lag_seconds = if (shift == 0) 0.0 else @as(f64, @floatFromInt(shift)) / sr_f,
    };
}

/// Full-signal linear gammatone spectrograms, row-major `[bands][nf]`.
pub const RawSpectrograms = struct {
    ref: []const f64,
    nf_ref: usize,
    deg: []const f64,
    nf_deg: usize,

    /// Copy `nf_local` columns for a patch starting at `slice[off]` (slice
    /// layout `l`) if its frames land on the global grid; false otherwise.
    /// gammatone_patches.slang skips the same frames.
    pub fn reuse(
        num_bands: usize,
        global: []const f64,
        nf_global: usize,
        l: SliceLayout,
        off: i64,
        hop: usize,
        nf_local: usize,
        out: []f64,
    ) bool {
        if (off < @as(i64, @intCast(l.pad))) return false;
        const start = l.base + @as(usize, @intCast(off)) - l.pad;
        if (start % hop != 0) return false;
        const g0 = start / hop;
        if (g0 + nf_local > nf_global) return false;
        for (0..num_bands) |b| {
            @memcpy(out[b * nf_local ..][0..nf_local], global[b * nf_global + g0 ..][0..nf_local]);
        }
        return true;
    }
};

/// `sliceAudio` of a view.
pub fn sliceView(allocator: std.mem.Allocator, v: accel.View) ![]f64 {
    const out = try allocator.alloc(f64, v.layout.pad + v.layout.len);
    @memset(out[0..v.layout.pad], 0.0);
    @memcpy(out[v.layout.pad..], v.signal[v.layout.base..][0..v.layout.len]);
    return out;
}

/// The CPU realignment of `job`: envelope lag, trim, then spectrograms,
/// copying grid-aligned frames from `job.raw`.
pub fn realignCpu(
    allocator: std.mem.Allocator,
    cache: *xcorr.Cache,
    params: accel.SpecParams,
    sample_rate: u32,
    job: accel.RealignJob,
    frame_buf: gammatone.FrameBuf,
) !void {
    const ref_audio = try sliceView(allocator, job.ref);
    defer allocator.free(ref_audio);
    const deg_audio = try sliceView(allocator, job.deg);
    defer allocator.free(deg_audio);
    {
        const env = try alignmentEnvelopes(allocator, ref_audio, deg_audio);
        defer allocator.free(env.ref);
        defer allocator.free(env.deg);
        job.out.lag = try xcorr.bestLagCached(cache, env.ref, env.deg);
    }
    var trimmed = try truncateAligned(allocator, ref_audio, deg_audio, job.out.lag, sample_rate);
    defer trimmed.deinit();
    const nb = params.bands.len;
    const nf = gammatone.numFrames(trimmed.ref.len, params.window_size, params.hop_size);
    job.out.num_frames = nf;
    if (nf == 0) return;
    const sides = [_]struct { signal: []const f64, layout: SliceLayout, off: i64, out: []f64, raw: ?[]const f64, nf_raw: usize }{
        .{ .signal = trimmed.ref, .layout = job.ref.layout, .off = @intCast(trimmed.ref_off), .out = job.out.ref_spec, .raw = if (job.raw) |r| r.ref else null, .nf_raw = if (job.raw) |r| r.nf_ref else 0 },
        .{ .signal = trimmed.deg, .layout = job.deg.layout, .off = trimmed.deg_off, .out = job.out.deg_spec, .raw = if (job.raw) |r| r.deg else null, .nf_raw = if (job.raw) |r| r.nf_deg else 0 },
    };
    for (sides) |s| {
        // Frames on the full-signal grid are bit-identical; reuse them.
        if (s.raw) |raw| if (RawSpectrograms.reuse(nb, raw, s.nf_raw, s.layout, s.off, params.hop_size, nf, s.out)) continue;
        _ = try gammatone.buildSpectrogramBands(params.bands, s.signal, params.window_size, params.hop_size, params.hann, frame_buf, s.out);
    }
}

pub const Patch = struct {
    match_index: usize,
    ref_len: usize,
    deg_len: usize,
    out: accel.RealignOut,
};

pub const RealignPlan = struct {
    patches: std.ArrayList(Patch) = .empty,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RealignPlan) void {
        for (self.patches.items) |p| {
            self.allocator.free(p.out.ref_spec);
            self.allocator.free(p.out.deg_spec);
        }
        self.patches.deinit(self.allocator);
    }
};

/// Queues each valid match's realignment in `jobs`, which point into the
/// returned plan, so batches across pairs reach the accelerator.
pub fn planRealign(
    num_bands: usize,
    allocator: std.mem.Allocator,
    matches: *const dp.Matches,
    ref_signal: []const f64,
    deg_signal: []const f64,
    sample_rate: u32,
    window_size: usize,
    hop_size: usize,
    raw: ?RawSpectrograms,
    jobs: *std.ArrayList(accel.RealignJob),
) !RealignPlan {
    var plan: RealignPlan = .{ .allocator = allocator };
    errdefer plan.deinit();
    // Reserved up front: jobs point into `plan.patches`.
    try plan.patches.ensureTotalCapacity(allocator, matches.items.len);
    try jobs.ensureUnusedCapacity(allocator, matches.items.len);
    for (matches.items, 0..) |*m, mi| {
        if (!m.valid) continue;
        const rl = sliceLayout(ref_signal.len, sample_rate, m.ref_patch_start_time, m.ref_patch_end_time);
        const dl = sliceLayout(deg_signal.len, sample_rate, m.deg_patch_start_time, m.deg_patch_end_time);
        const ref_len = rl.pad + rl.len;
        const deg_len = dl.pad + dl.len;
        if (ref_len < window_size or deg_len < window_size) continue;
        // Trimming keeps at most the reference.
        const max_frames = gammatone.numFrames(ref_len, window_size, hop_size);
        const ref_spec = try allocator.alloc(f64, num_bands * max_frames);
        errdefer allocator.free(ref_spec);
        const deg_spec = try allocator.alloc(f64, num_bands * max_frames);
        plan.patches.appendAssumeCapacity(.{
            .match_index = mi,
            .ref_len = ref_len,
            .deg_len = deg_len,
            .out = .{ .ref_spec = ref_spec, .deg_spec = deg_spec },
        });
        const p = &plan.patches.items[plan.patches.items.len - 1];
        jobs.appendAssumeCapacity(.{
            .ref = .{ .signal = ref_signal, .layout = rl },
            .deg = .{ .signal = deg_signal, .layout = dl },
            .raw = raw,
            .out = &p.out,
        });
    }
    return plan;
}

/// Rescore each realigned patch; keep the result unless strictly worse.
pub fn finishRealign(
    num_bands: usize,
    allocator: std.mem.Allocator,
    plan: *RealignPlan,
    matches: *dp.Matches,
    sample_rate: u32,
) !void {
    const cmp = nsim.Comparator.init(1.0);
    var scratch: ?nsim.Scratch = null;
    defer if (scratch) |*sc| sc.deinit();

    for (plan.patches.items) |*p| {
        const nf = p.out.num_frames;
        if (nf == 0) continue;
        const m = &matches.items[p.match_index];
        const geo = trimGeometry(p.ref_len, p.deg_len, p.out.lag, sample_rate);
        const ref_spec = p.out.ref_spec[0 .. num_bands * nf];
        const deg_spec = p.out.deg_spec[0 .. num_bands * nf];
        spectrogram.prepareForComparison(ref_spec, deg_spec, num_bands, nf, nf);

        if (scratch == null or scratch.?.nrows != num_bands or scratch.?.ncols != nf) {
            if (scratch) |*sc| sc.deinit();
            scratch = null;
            scratch = try nsim.Scratch.init(allocator, num_bands, nf);
        }

        const new_means = try allocator.alloc(f64, num_bands);
        errdefer allocator.free(new_means);
        const new_stddevs = try allocator.alloc(f64, num_bands);
        errdefer allocator.free(new_stddevs);
        const new_deg_energy = try allocator.alloc(f64, num_bands);
        var ps = nsim.PatchSimilarity{
            .freq_band_means = new_means,
            .freq_band_stddevs = new_stddevs,
            .freq_band_deg_energy = new_deg_energy,
            .mean_freq_band_means = 0.0,
            .allocator = allocator,
        };
        cmp.measurePatchSimilarity(&scratch.?, ref_spec, deg_spec, &ps);

        if (!(ps.mean_freq_band_means < m.similarity)) {
            allocator.free(m.freq_band_means);
            allocator.free(m.freq_band_stddevs);
            allocator.free(m.freq_band_deg_energy);
            m.freq_band_means = new_means;
            m.freq_band_stddevs = new_stddevs;
            m.freq_band_deg_energy = new_deg_energy;
            m.similarity = ps.mean_freq_band_means;

            const sr_f: f64 = @floatFromInt(sample_rate);
            const new_dur: f64 = @as(f64, @floatFromInt(geo.len)) / sr_f;
            if (geo.lag_seconds > 0.0) {
                m.ref_patch_start_time += geo.lag_seconds;
            } else {
                m.deg_patch_start_time -= geo.lag_seconds;
            }
            m.ref_patch_end_time = m.ref_patch_start_time + new_dur;
            m.deg_patch_end_time = m.deg_patch_start_time + new_dur;
        } else {
            ps.deinit();
        }
    }
}

test "sliceAudio: in-range slice copies samples" {
    const allocator = std.testing.allocator;
    const sig = [_]f64{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0 };
    const out = try sliceAudio(allocator, &sig, 10, 0.2, 0.6);
    defer allocator.free(out);
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), out[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), out[3], 1e-12);
}

test "sliceAudio: out-of-range zero-pads" {
    const allocator = std.testing.allocator;
    const sig = try allocator.alloc(f64, 48000);
    defer allocator.free(sig);
    @memset(sig, 0.0);
    sig[16000] = 1.0;
    const out = try sliceAudio(allocator, sig, 16000, 0.5, 2.5);
    defer allocator.free(out);
    try std.testing.expectEqual(@as(usize, 32000), out.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), out[8000], 1e-12);
}

test "globallyAlign: identical signals → lag 0" {
    const allocator = std.testing.allocator;
    var sig: [1024]f64 = undefined;
    var i: usize = 0;
    while (i < 1024) : (i += 1) sig[i] = @sin(@as(f64, @floatFromInt(i)) * 0.1) * 0.5;
    var cache = xcorr.Cache.init(allocator);
    defer cache.deinit();
    const a = try globallyAlign(allocator, &cache, &sig, &sig, 16000);
    defer if (a.deg_owned) allocator.free(a.deg);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), a.lag_seconds, 1e-9);
}

test "trimGeometry: where truncateAligned takes its samples" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(5);
    const r = prng.random();
    for (0..3000) |it| {
        const sr: u32 = ([_]u32{ 16000, 44100, 48000 })[it % 3];
        const ref_len = r.intRangeAtMost(usize, 0, 400);
        const deg_len = r.intRangeAtMost(usize, 0, 400);
        // Lags past half the reference are ignored; 27 comes back from seconds as 26 at 48 kHz.
        const lag: i64 = switch (it % 4) {
            0 => 27,
            1 => -55,
            else => r.intRangeAtMost(i64, -@as(i64, @intCast(ref_len)), @intCast(ref_len)),
        };
        const ref = try allocator.alloc(f64, ref_len);
        defer allocator.free(ref);
        const deg = try allocator.alloc(f64, deg_len);
        defer allocator.free(deg);
        for (ref, 0..) |*x, i| x.* = @floatFromInt(i + 1);
        for (deg, 0..) |*x, i| x.* = -@as(f64, @floatFromInt(i + 1));
        var t = try truncateAligned(allocator, ref, deg, lag, sr);
        defer t.deinit();
        const g = trimGeometry(ref_len, deg_len, lag, sr);
        try std.testing.expectEqual(t.ref.len, g.len);
        try std.testing.expectEqual(t.deg.len, g.len);
        try std.testing.expectEqual(t.lag_seconds, g.lag_seconds);
        for (t.ref, 0..) |x, i| try std.testing.expectEqual(ref[g.ref_off + i], x);
        for (t.deg, 0..) |x, i| {
            const j = g.deg_off + @as(i64, @intCast(i));
            try std.testing.expectEqual(if (j >= 0 and j < deg_len) deg[@intCast(j)] else 0.0, x);
        }
    }
    try std.testing.expectEqual(@as(i64, 26), lagSamplesBack(27, 48000));
}
