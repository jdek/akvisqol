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
    var aligned = try globallyAlign(allocator, cache, ref, deg, sample_rate);
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

/// Full-signal linear gammatone spectrograms, row-major `[bands][nf]`.
pub const RawSpectrograms = struct {
    ref: []const f64,
    nf_ref: usize,
    deg: []const f64,
    nf_deg: usize,

    /// Copy `nf_local` columns for a patch starting at `slice[off]` (slice
    /// layout `l`) if its frames land on the global grid; false otherwise.
    fn reuse(
        _: RawSpectrograms,
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

pub const RealignJob = struct {
    match_index: usize,
    trimmed: Trimmed,
    nf_ref: usize,
    nf_deg: usize,
    ref_spec: []f64,
    deg_spec: []f64,
};

pub const RealignPrep = struct {
    jobs: std.ArrayList(RealignJob) = .empty,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RealignPrep) void {
        for (self.jobs.items) |*j| {
            j.trimmed.deinit();
            self.allocator.free(j.ref_spec);
            self.allocator.free(j.deg_spec);
        }
        self.jobs.deinit(self.allocator);
    }
};

/// Slice, align and truncate each match, reusing grid-aligned frames from
/// `raw` or queueing a job in `spec_jobs`. Jobs point into the returned
/// `RealignPrep`, which must outlive them.
pub fn prepareRealign(
    num_bands: usize,
    allocator: std.mem.Allocator,
    cache: *xcorr.Cache,
    matches: *const dp.Matches,
    ref_signal: []const f64,
    deg_signal: []const f64,
    sample_rate: u32,
    window_size: usize,
    hop_size: usize,
    raw: ?RawSpectrograms,
    spec_jobs: *std.ArrayList(accel.SpecJob),
) !RealignPrep {
    var prep: RealignPrep = .{ .allocator = allocator };
    errdefer prep.deinit();

    for (matches.items, 0..) |*m, mi| {
        if (!m.valid) continue;

        const ref_layout = sliceLayout(ref_signal.len, sample_rate, m.ref_patch_start_time, m.ref_patch_end_time);
        const deg_layout = sliceLayout(deg_signal.len, sample_rate, m.deg_patch_start_time, m.deg_patch_end_time);
        const ref_audio = try sliceAudio(allocator, ref_signal, sample_rate, m.ref_patch_start_time, m.ref_patch_end_time);
        defer allocator.free(ref_audio);
        const deg_audio = try sliceAudio(allocator, deg_signal, sample_rate, m.deg_patch_start_time, m.deg_patch_end_time);
        defer allocator.free(deg_audio);
        if (ref_audio.len < window_size or deg_audio.len < window_size) continue;

        var trimmed = alignAndTruncate(allocator, cache, ref_audio, deg_audio, sample_rate) catch continue;
        if (trimmed.ref.len < window_size) {
            trimmed.deinit();
            continue;
        }
        const nf_ref = gammatone.numFrames(trimmed.ref.len, window_size, hop_size);
        const nf_deg = gammatone.numFrames(trimmed.deg.len, window_size, hop_size);
        if (nf_ref == 0 or nf_deg == 0) {
            trimmed.deinit();
            continue;
        }
        const ref_spec = allocator.alloc(f64, num_bands * nf_ref) catch |e| {
            trimmed.deinit();
            return e;
        };
        const deg_spec = allocator.alloc(f64, num_bands * nf_deg) catch |e| {
            trimmed.deinit();
            allocator.free(ref_spec);
            return e;
        };
        prep.jobs.append(allocator, .{
            .match_index = mi,
            .trimmed = trimmed,
            .nf_ref = nf_ref,
            .nf_deg = nf_deg,
            .ref_spec = ref_spec,
            .deg_spec = deg_spec,
        }) catch |e| {
            trimmed.deinit();
            allocator.free(ref_spec);
            allocator.free(deg_spec);
            return e;
        };
        const job = &prep.jobs.items[prep.jobs.items.len - 1];

        // Frames on the full-signal grid are bit-identical; reuse them.
        const ref_reused = if (raw) |r| r.reuse(num_bands, r.ref, r.nf_ref, ref_layout, @intCast(trimmed.ref_off), hop_size, nf_ref, ref_spec) else false;
        const deg_reused = if (raw) |r| r.reuse(num_bands, r.deg, r.nf_deg, deg_layout, trimmed.deg_off, hop_size, nf_deg, deg_spec) else false;
        if (!ref_reused) try spec_jobs.append(allocator, .{ .signal = job.trimmed.ref, .num_frames = nf_ref, .out = ref_spec });
        if (!deg_reused) try spec_jobs.append(allocator, .{ .signal = job.trimmed.deg, .num_frames = nf_deg, .out = deg_spec });
    }
    return prep;
}

/// Rescore each filled job; keep the realigned result unless strictly worse.
pub fn finishRealign(
    num_bands: usize,
    allocator: std.mem.Allocator,
    prep: *RealignPrep,
    matches: *dp.Matches,
    sample_rate: u32,
) !void {
    const cmp = nsim.Comparator.init(1.0);
    var scratch: ?nsim.Scratch = null;
    defer if (scratch) |*sc| sc.deinit();

    for (prep.jobs.items) |*job| {
        const m = &matches.items[job.match_index];
        spectrogram.prepareForComparison(job.ref_spec, job.deg_spec, num_bands, job.nf_ref, job.nf_deg);

        const shared_nf = @min(job.nf_ref, job.nf_deg);
        if (scratch == null or scratch.?.nrows != num_bands or scratch.?.ncols != shared_nf) {
            if (scratch) |*sc| sc.deinit();
            scratch = null;
            scratch = try nsim.Scratch.init(allocator, num_bands, shared_nf);
        }
        const ref_slab = try allocator.alloc(f64, num_bands * shared_nf);
        defer allocator.free(ref_slab);
        const deg_slab = try allocator.alloc(f64, num_bands * shared_nf);
        defer allocator.free(deg_slab);
        for (0..num_bands) |b| {
            @memcpy(ref_slab[b * shared_nf ..][0..shared_nf], job.ref_spec[b * job.nf_ref ..][0..shared_nf]);
            @memcpy(deg_slab[b * shared_nf ..][0..shared_nf], job.deg_spec[b * job.nf_deg ..][0..shared_nf]);
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
        cmp.measurePatchSimilarity(&scratch.?, ref_slab, deg_slab, &ps);

        if (!(ps.mean_freq_band_means < m.similarity)) {
            allocator.free(m.freq_band_means);
            allocator.free(m.freq_band_stddevs);
            allocator.free(m.freq_band_deg_energy);
            m.freq_band_means = new_means;
            m.freq_band_stddevs = new_stddevs;
            m.freq_band_deg_energy = new_deg_energy;
            m.similarity = ps.mean_freq_band_means;

            const sr_f: f64 = @floatFromInt(sample_rate);
            const new_ref_dur: f64 = @as(f64, @floatFromInt(job.trimmed.ref.len)) / sr_f;
            const new_deg_dur: f64 = @as(f64, @floatFromInt(job.trimmed.deg.len)) / sr_f;
            if (job.trimmed.lag_seconds > 0.0) {
                m.ref_patch_start_time += job.trimmed.lag_seconds;
            } else {
                m.deg_patch_start_time -= job.trimmed.lag_seconds;
            }
            m.ref_patch_end_time = m.ref_patch_start_time + new_ref_dur;
            m.deg_patch_end_time = m.deg_patch_start_time + new_deg_dur;
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
