// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! The CPU model's batched stages: spectrograms, DP patch similarities,
//! alignment lags, patch realignment.
const std = @import("std");
const gammatone = @import("gammatone.zig");
const nsim = @import("nsim.zig");
const dp = @import("dp.zig");
const xcorr = @import("xcorr.zig");
const realign = @import("realign.zig");

/// Filterbank + analysis window shared by every job in one call.
pub const SpecParams = struct {
    bands: []const gammatone.Band,
    window_size: usize,
    hop_size: usize,
    hann: []const f64,
};

pub const SpecJob = struct {
    signal: []const f64,
    num_frames: usize,
    /// Row-major `[bands.len, num_frames]`.
    out: []f64,
};

/// NSIM of reference patch `p` (frames `ref_indices[p] ..+patch_size`)
/// against degraded patches starting at every offset in
/// `[lo[p], hi[p]]` (degraded frames past `nf_deg` read as zero).
/// Results land in `out[p * nf_deg + offset]`; other cells are untouched.
pub const SimJob = struct {
    ref_spec: []const f64,
    nf_ref: usize,
    deg_spec: []const f64,
    nf_deg: usize,
    num_bands: usize,
    patch_size: usize,
    ref_indices: []const usize,
    lo: []const usize,
    hi: []const usize,
    out: []f64,
};

/// `out.*` = `xcorr.bestLagCached` of the upper envelopes of `a` and `b`
/// (`realign.alignmentEnvelopes`): the lag maximising |Σ_t a[t + lag]·b[t]|
/// over |lag| < max(a.len, b.len), first maximum in the order negative lags
/// (most negative first), then 0, 1, ….
pub const LagJob = struct {
    a: []const f64,
    b: []const f64,
    out: *i64,
};

/// `realign.sliceAudio(signal, …)` without the copy.
pub const View = struct {
    signal: []const f64,
    layout: realign.SliceLayout,

    pub fn len(v: View) usize {
        return v.layout.pad + v.layout.len;
    }
};

/// Fine alignment of a matched patch pair (`realign.realignCpu`): the
/// `LagJob` lag of the slices, then the spectrograms of what
/// `realign.trimGeometry` keeps of them.
pub const RealignJob = struct {
    ref: View,
    deg: View,
    /// Full-signal spectrograms to copy grid-aligned frames from.
    raw: ?realign.RawSpectrograms = null,
    out: *RealignOut,
};

pub const RealignOut = struct {
    lag: i64 = 0,
    /// Of both spectrograms; 0 when the trimmed patch is under a window.
    num_frames: usize = 0,
    /// `[bands][num_frames]`, room for the frames of `ref.len()` samples.
    ref_spec: []f64,
    deg_spec: []f64,
};

/// Single-threaded; batch parallelism is one pipeline per worker thread.
pub const Cpu = struct {
    allocator: std.mem.Allocator,
    xcorr_cache: ?xcorr.Cache = null,

    pub fn deinit(self: *Cpu) void {
        if (self.xcorr_cache) |*c| c.deinit();
        self.xcorr_cache = null;
    }

    fn cache(self: *Cpu) *xcorr.Cache {
        if (self.xcorr_cache == null) self.xcorr_cache = xcorr.Cache.init(self.allocator);
        return &self.xcorr_cache.?;
    }

    pub fn bestLags(self: *Cpu, jobs: []const LagJob) !void {
        for (jobs) |j| {
            const env = try realign.alignmentEnvelopes(self.allocator, j.a, j.b);
            defer self.allocator.free(env.ref);
            defer self.allocator.free(env.deg);
            j.out.* = try xcorr.bestLagCached(self.cache(), env.ref, env.deg);
        }
    }

    pub fn realignPatches(self: *Cpu, params: SpecParams, sample_rate: u32, jobs: []const RealignJob) !void {
        if (jobs.len == 0) return;
        const frame_buf = try gammatone.allocFrameBuf(self.allocator, params.window_size);
        defer self.allocator.free(frame_buf);
        for (jobs) |j| try realign.realignCpu(self.allocator, self.cache(), params, sample_rate, j, frame_buf);
    }

    pub fn spectrograms(self: *Cpu, params: SpecParams, jobs: []const SpecJob) !void {
        if (jobs.len == 0) return;
        const frame_buf = try gammatone.allocFrameBuf(self.allocator, params.window_size);
        defer self.allocator.free(frame_buf);
        for (jobs) |j| {
            std.debug.assert(j.num_frames == gammatone.numFrames(j.signal.len, params.window_size, params.hop_size));
            _ = try gammatone.buildSpectrogramBands(params.bands, j.signal, params.window_size, params.hop_size, params.hann, frame_buf, j.out);
        }
    }

    pub fn patchSimilarities(self: *Cpu, jobs: []const SimJob) !void {
        const cmp = nsim.Comparator.init(1.0);
        for (jobs) |j| {
            var scratch = try nsim.Scratch.init(self.allocator, j.num_bands, j.patch_size);
            defer scratch.deinit();
            const ref_patch = try self.allocator.alloc(f64, j.num_bands * j.patch_size);
            defer self.allocator.free(ref_patch);
            var width = j.nf_deg;
            for (j.hi) |hi| width = @max(width, hi + j.patch_size);
            var plane = try nsim.DegPlane.init(self.allocator, j.deg_spec, j.num_bands, j.nf_deg, width);
            defer plane.deinit();
            for (j.ref_indices, j.lo, j.hi, 0..) |ri, lo, hi, p| {
                dp.buildRefPatch(j.ref_spec, j.num_bands, j.nf_ref, ri, j.patch_size, ref_patch);
                cmp.precomputeRef(&scratch, ref_patch);
                var off = lo;
                while (off <= hi) : (off += 1) {
                    j.out[p * j.nf_deg + off] = cmp.measureSimilarityAt(&scratch, ref_patch, &plane, off);
                }
            }
        }
    }
};
