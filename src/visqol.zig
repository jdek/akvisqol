// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Public ViSQOL API. `Visqol` dispatches to `Pipeline(NUM_BANDS)`
//! (32 bands audio, 21 speech); stages follow upstream
//! `Visqol::CalculateSimilarity`.
const std = @import("std");
const audio = @import("audio.zig");
const gammatone = @import("gammatone.zig");
const spectrogram = @import("spectrogram.zig");
const dp = @import("dp.zig");
const realign_mod = @import("realign.zig");
const svr = @import("svr.zig");
const lattice = @import("lattice.zig");
const vad = @import("vad.zig");
const accel = @import("accel.zig");
pub const Accelerator = accel.Accelerator;

pub const constants = struct {
    pub const NUM_BANDS_AUDIO: usize = 32;
    pub const NUM_BANDS_SPEECH: usize = 21;
    pub const PATCH_SIZE_AUDIO: usize = 30;
    pub const PATCH_SIZE_SPEECH: usize = 20;
    pub const MIN_FREQ: f64 = 50.0;
    pub const SPEECH_MODE_MAX_FREQ: f64 = 8000.0;
    pub const OVERLAP: f64 = 0.25;
    pub const WINDOW_DURATION: f64 = 0.08;
    pub const DEFAULT_SEARCH_WINDOW: i32 = 60;
    pub const AUDIO_SAMPLE_RATE: u32 = 48000;
    pub const SPEECH_SAMPLE_RATE: u32 = 16000;
};

pub const Error = error{
    InvalidInput,
    SampleRateMismatch,
    SignalsTooDifferent,
    OutOfMemory,
    ReferenceSpectrogramTooSmall,
    SpectrogramTooShort,
    AlignmentFailed,
    NoPatches,
};

pub const Mode = enum(u8) { audio = 0, speech = 1 };

pub const Options = struct {
    mode: Mode = .audio,
    /// DP search radius in frames.
    search_window_radius: i32 = constants.DEFAULT_SEARCH_WINDOW,
    /// Speech mode only: map NSIM=1 → MOS≈4.x instead of 5.0.
    use_unscaled_speech_mos_mapping: bool = false,
    /// Speech mode only: TF-Lattice instead of the exponential fit (upstream default).
    use_lattice_model: bool = false,
    disable_global_alignment: bool = false,
    disable_realignment: bool = false,
};

pub const QualityMapper = union(enum) {
    /// Audio mode: libsvm nu-SVR over `fvnsim`.
    svr: svr.Model,
    /// Speech mode: exponential fit over mean NSIM (TCD-VOIP).
    speech_exponential: struct { scale_to_max_mos: bool },
    /// Speech mode: TF-Lattice model over all four per-band features.
    lattice: lattice.Mapper,

    pub fn deinit(self: *QualityMapper) void {
        switch (self.*) {
            .svr => |*m| m.deinit(),
            .speech_exponential => {},
            .lattice => |*m| m.deinit(),
        }
    }

    pub fn predict(self: *const QualityMapper, fvnsim: []const f64, fvnsim10: []const f64, fstdnsim: []const f64, fvdegenergy: []const f64) !f64 {
        switch (self.*) {
            .svr => |m| return m.predictClamped(fvnsim),
            .lattice => |*m| return m.predict(fvnsim, fvnsim10, fstdnsim, fvdegenergy),
            .speech_exponential => |e| {
                const a = -262.847869;
                const b = 0.0154302525;
                const x0 = -361.063949;
                var sum: f64 = 0.0;
                for (fvnsim) |x| sum += x;
                const nsim_mean = sum / @as(f64, @floatFromInt(fvnsim.len));
                const mos = a + @exp(b * (nsim_mean - x0));
                // Upstream stores the scale in a `float`; keep that rounding.
                const scale: f64 = if (e.scale_to_max_mos) @as(f32, 1.245063) else 1.0;
                return std.math.clamp(mos * scale, 1.0, 5.0);
            },
        }
    }
};

/// Mirrors upstream `PatchSimilarityMsg`.
pub const PatchSimilarity = struct {
    similarity: f64,
    ref_patch_start_time: f64,
    ref_patch_end_time: f64,
    deg_patch_start_time: f64,
    deg_patch_end_time: f64,
    /// Each `num_bands` long, slicing `Result.patch_band_data`.
    freq_band_means: []const f64,
    freq_band_stddevs: []const f64,
    freq_band_deg_energy: []const f64,
};

/// Mirrors upstream `SimilarityResultMsg`. Owns all slices.
pub const Result = struct {
    moslqo: f64,
    vnsim: f64,
    fvnsim: []f64,
    fvnsim10: []f64,
    fstdnsim: []f64,
    fvdegenergy: []f64,
    center_freq_bands: []f64,
    patch_sims: []PatchSimilarity,
    /// Backing store for every patch's per-band slices.
    patch_band_data: []f64,
    alignment_lag_s: f64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        const a = self.allocator;
        a.free(self.fvnsim);
        a.free(self.fvnsim10);
        a.free(self.fstdnsim);
        a.free(self.fvdegenergy);
        a.free(self.center_freq_bands);
        a.free(self.patch_sims);
        a.free(self.patch_band_data);
    }
};

pub const Pair = struct { ref: []const f64, deg: []const f64 };

/// Not thread-safe (holds per-rate caches); use one per thread.
pub const Visqol = struct {
    allocator: std.mem.Allocator,
    options: Options,
    mapper: QualityMapper,
    cpu: accel.Cpu,
    impl: union(Mode) {
        audio: Pipeline(constants.NUM_BANDS_AUDIO),
        speech: Pipeline(constants.NUM_BANDS_SPEECH),
    },

    /// Takes ownership of `mapper`. Audio mode requires `.svr`; speech mode
    /// uses `.lattice` if given, else the exponential fit from `options`.
    pub fn init(allocator: std.mem.Allocator, options: Options, mapper: ?QualityMapper) !Visqol {
        switch (options.mode) {
            .audio => {
                const m = mapper orelse return Error.InvalidInput;
                if (m != .svr) return Error.InvalidInput;
                return .{
                    .allocator = allocator,
                    .options = options,
                    .mapper = m,
                    .cpu = .{ .allocator = allocator },
                    .impl = .{ .audio = .{ .allocator = allocator, .patch_size = constants.PATCH_SIZE_AUDIO, .max_freq = null } },
                };
            },
            .speech => {
                var m = mapper;
                const use_lattice = if (m) |mm| mm == .lattice else false;
                if (!use_lattice) if (m) |*mm| mm.deinit();
                return .{
                    .allocator = allocator,
                    .options = options,
                    .mapper = if (use_lattice) m.? else .{ .speech_exponential = .{ .scale_to_max_mos = !options.use_unscaled_speech_mos_mapping } },
                    .cpu = .{ .allocator = allocator },
                    .impl = .{ .speech = .{ .allocator = allocator, .patch_size = constants.PATCH_SIZE_SPEECH, .max_freq = constants.SPEECH_MODE_MAX_FREQ } },
                };
            },
        }
    }

    pub fn deinit(self: *Visqol) void {
        self.mapper.deinit();
        self.cpu.deinit();
        switch (self.impl) {
            inline else => |*p| p.deinit(),
        }
    }

    /// Score two mono f64 signals at a shared sample rate.
    pub fn measure(self: *Visqol, ref: []const f64, deg: []const f64, sample_rate: u32) !Result {
        var out: [1]anyerror!Result = undefined;
        try self.measureBatch(&.{.{ .ref = ref, .deg = deg }}, sample_rate, self.cpu.accelerator(), &out);
        return out[0];
    }

    /// Score pairs in lock-step, batching each stage on `acc`. Per-pair
    /// errors land in `results[i]`; accelerator errors fail the call.
    pub fn measureBatch(self: *Visqol, pairs: []const Pair, sample_rate: u32, acc: accel.Accelerator, results: []anyerror!Result) !void {
        std.debug.assert(results.len == pairs.len);
        switch (self.impl) {
            inline else => |*p| return p.runBatch(pairs, sample_rate, self.options, self.mapper, acc, results),
        }
    }

    /// Score two WAV files (loaded as mono).
    pub fn measureFiles(self: *Visqol, ref_path: []const u8, deg_path: []const u8) !Result {
        var ref = try audio.loadAsMono(self.allocator, ref_path);
        defer ref.deinit();
        var deg = try audio.loadAsMono(self.allocator, deg_path);
        defer deg.deinit();
        if (ref.sample_rate != deg.sample_rate) return Error.SampleRateMismatch;
        return self.measure(ref.samples, deg.samples, ref.sample_rate);
    }
};

pub fn Pipeline(comptime NUM_BANDS: usize) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        patch_size: usize,
        /// Filterbank upper edge; `null` = Nyquist.
        max_freq: ?f64,
        min_freq: f64 = constants.MIN_FREQ,
        overlap: f64 = constants.OVERLAP,
        window_duration: f64 = constants.WINDOW_DURATION,

        cached_sample_rate: u32 = 0,
        cached_filters: ?gammatone.Filters(NUM_BANDS) = null,
        cached_window_size: usize = 0,
        cached_hop_size: usize = 0,
        cached_hann: []f64 = &.{},
        cached_frame_duration: f64 = 0.0,

        pub fn deinit(self: *Self) void {
            if (self.cached_hann.len > 0) self.allocator.free(self.cached_hann);
        }

        fn ensureCache(self: *Self, sample_rate: u32) !void {
            if (self.cached_sample_rate == sample_rate and self.cached_filters != null) return;
            const sr_f: f64 = @floatFromInt(sample_rate);
            self.cached_filters = gammatone.Filters(NUM_BANDS).init(sample_rate, self.min_freq, self.max_freq orelse sr_f / 2.0);
            self.cached_window_size = @intFromFloat(@round(sr_f * self.window_duration));
            self.cached_hop_size = @intFromFloat(@as(f64, @floatFromInt(self.cached_window_size)) * self.overlap);
            if (self.cached_hop_size == 0) self.cached_hop_size = 1;
            if (self.cached_hann.len > 0) self.allocator.free(self.cached_hann);
            self.cached_hann = &.{};
            self.cached_hann = try self.allocator.alloc(f64, self.cached_window_size);
            gammatone.hannWindow(self.cached_window_size, self.cached_hann);
            self.cached_frame_duration = @as(f64, @floatFromInt(self.cached_hop_size)) / sr_f;
            self.cached_sample_rate = sample_rate;
        }

        const State = struct {
            failed: ?anyerror = null,
            deg: []f64 = &.{},
            env: ?realign_mod.Envelopes = null,
            lag: i64 = 0,
            lag_s: f64 = 0.0,
            nf_ref: usize = 0,
            nf_deg: usize = 0,
            ref_spec: []f64 = &.{},
            deg_spec: []f64 = &.{},
            ref_raw: []f64 = &.{},
            deg_raw: []f64 = &.{},
            ref_indices: []usize = &.{},
            plan: ?dp.SearchPlan = null,
            matches: ?dp.Matches = null,
            realign_plan: ?realign_mod.RealignPlan = null,
            realign: ?realign_mod.RealignPrep = null,

            fn freeEnvelopes(st: *State, a: std.mem.Allocator) void {
                if (st.env) |e| {
                    a.free(e.ref);
                    a.free(e.deg);
                }
                st.env = null;
            }

            fn deinit(st: *State, a: std.mem.Allocator) void {
                st.freeEnvelopes(a);
                a.free(st.deg);
                a.free(st.ref_spec);
                a.free(st.deg_spec);
                a.free(st.ref_raw);
                a.free(st.deg_raw);
                a.free(st.ref_indices);
                if (st.plan) |*x| x.deinit();
                if (st.matches) |*x| x.deinit();
                if (st.realign_plan) |*x| x.deinit();
                if (st.realign) |*x| x.deinit();
            }

            fn live(st: *const State) bool {
                return st.failed == null;
            }
        };

        pub fn runBatch(
            self: *Self,
            pairs: []const Pair,
            sample_rate: u32,
            options: Options,
            mapper: QualityMapper,
            acc: accel.Accelerator,
            results: []anyerror!Result,
        ) !void {
            if (sample_rate == 0) return Error.InvalidInput;
            try self.ensureCache(sample_rate);
            const allocator = self.allocator;
            const filters = &self.cached_filters.?;
            const window_size = self.cached_window_size;
            const hop_size = self.cached_hop_size;
            const frame_duration = self.cached_frame_duration;
            const spec_params: accel.SpecParams = .{
                .bands = &filters.bands,
                .window_size = window_size,
                .hop_size = hop_size,
                .hann = self.cached_hann,
            };

            const states = try allocator.alloc(State, pairs.len);
            defer allocator.free(states);
            for (states) |*st| st.* = .{};
            defer for (states) |*st| st.deinit(allocator);

            var spec_jobs: std.ArrayList(accel.SpecJob) = .empty;
            defer spec_jobs.deinit(allocator);

            // 1: global-alignment lag search.
            if (!options.disable_global_alignment) {
                var lag_jobs: std.ArrayList(accel.LagJob) = .empty;
                defer lag_jobs.deinit(allocator);
                for (pairs, states) |pair, *st| {
                    if (pair.ref.len == 0 or pair.deg.len == 0) continue;
                    st.env = realign_mod.alignmentEnvelopes(allocator, pair.ref, pair.deg) catch |e| {
                        st.failed = e;
                        continue;
                    };
                    try lag_jobs.append(allocator, .{ .a = st.env.?.ref, .b = st.env.?.deg, .out = &st.lag });
                }
                defer for (states) |*st| st.freeEnvelopes(allocator);
                try acc.bestLags(lag_jobs.items);
            }

            // 2: apply lag, SPL match, queue spectrograms.
            for (pairs, states) |pair, *st| {
                if (!st.live()) continue;
                self.prepareSignals(pair, st, options, sample_rate, &spec_jobs) catch |e| {
                    st.failed = e;
                };
            }

            // 3: gammatone spectrograms.
            try acc.spectrograms(spec_params, spec_jobs.items);

            // 4-5: normalise, ref patch indices, DP plan.
            var sim_jobs: std.ArrayList(accel.SimJob) = .empty;
            defer sim_jobs.deinit(allocator);
            for (pairs, states) |pair, *st| {
                if (!st.live()) continue;
                self.planPair(pair, st, options, window_size, &sim_jobs) catch |e| {
                    st.failed = e;
                };
            }

            // 6a: DP similarity matrix.
            try acc.patchSimilarities(sim_jobs.items);

            // 6b: DP backtrace; queue every patch's realignment lag search.
            var patch_lags: std.ArrayList(accel.LagJob) = .empty;
            defer patch_lags.deinit(allocator);
            for (pairs, states) |pair, *st| {
                if (!st.live()) continue;
                self.searchPair(pair, st, options, sample_rate, frame_duration, &patch_lags) catch |e| {
                    st.failed = e;
                };
            }
            try acc.bestLags(patch_lags.items);

            // 6c: align and truncate patches; queue their spectrograms.
            spec_jobs.clearRetainingCapacity();
            for (pairs, states) |pair, *st| {
                if (!st.live() or st.realign_plan == null) continue;
                st.realign = realign_mod.prepareRealign(
                    NUM_BANDS,
                    allocator,
                    &st.realign_plan.?,
                    &st.matches.?,
                    pair.ref,
                    st.deg,
                    sample_rate,
                    window_size,
                    hop_size,
                    .{ .ref = st.ref_raw, .nf_ref = st.nf_ref, .deg = st.deg_raw, .nf_deg = st.nf_deg },
                    &spec_jobs,
                ) catch |e| {
                    st.failed = e;
                    continue;
                };
                st.realign_plan.?.deinit();
                st.realign_plan = null;
            }

            // 7: realigned spectrograms, rescore.
            try acc.spectrograms(spec_params, spec_jobs.items);
            for (states) |*st| {
                if (!st.live()) continue;
                if (st.realign) |*rp| realign_mod.finishRealign(NUM_BANDS, allocator, rp, &st.matches.?, sample_rate) catch |e| {
                    st.failed = e;
                };
            }

            // 8: aggregate, map to MOS.
            for (states, results) |*st, *r| {
                if (st.failed) |e| {
                    r.* = e;
                    continue;
                }
                r.* = buildResult(allocator, NUM_BANDS, &st.matches.?, frame_duration, mapper, &filters.center_freqs, st.lag_s);
            }
        }

        fn prepareSignals(
            self: *Self,
            pair: Pair,
            st: *State,
            options: Options,
            sample_rate: u32,
            spec_jobs: *std.ArrayList(accel.SpecJob),
        ) !void {
            const allocator = self.allocator;
            const window_size = self.cached_window_size;
            const hop_size = self.cached_hop_size;
            if (options.disable_global_alignment) {
                st.deg = try allocator.dupe(f64, pair.deg);
            } else {
                const aligned = try realign_mod.applyLag(allocator, pair.ref.len, pair.deg, st.lag, sample_rate);
                st.lag_s = aligned.lag_seconds;
                st.deg = if (aligned.deg_owned) aligned.deg else try allocator.dupe(f64, aligned.deg);
            }
            audio.scaleToMatchSpl(pair.ref, st.deg);

            // Upstream requires signals strictly longer than one window.
            if (pair.ref.len <= window_size or st.deg.len <= window_size) return Error.SpectrogramTooShort;
            st.nf_ref = gammatone.numFrames(pair.ref.len, window_size, hop_size);
            st.nf_deg = gammatone.numFrames(st.deg.len, window_size, hop_size);
            st.ref_spec = try allocator.alloc(f64, NUM_BANDS * st.nf_ref);
            st.deg_spec = try allocator.alloc(f64, NUM_BANDS * st.nf_deg);
            try spec_jobs.append(allocator, .{ .signal = pair.ref, .num_frames = st.nf_ref, .out = st.ref_spec });
            try spec_jobs.append(allocator, .{ .signal = st.deg, .num_frames = st.nf_deg, .out = st.deg_spec });
        }

        fn planPair(
            self: *Self,
            pair: Pair,
            st: *State,
            options: Options,
            window_size: usize,
            sim_jobs: *std.ArrayList(accel.SimJob),
        ) !void {
            const allocator = self.allocator;
            // Linear copies for realignment frame reuse.
            if (!options.disable_realignment) {
                st.ref_raw = try allocator.dupe(f64, st.ref_spec);
                st.deg_raw = try allocator.dupe(f64, st.deg_spec);
            }
            spectrogram.prepareForComparison(st.ref_spec, st.deg_spec, NUM_BANDS, st.nf_ref, st.nf_deg);

            st.ref_indices = switch (options.mode) {
                .audio => try dp.refPatchIndices(allocator, st.nf_ref, self.patch_size),
                .speech => try vad.refPatchIndices(allocator, pair.ref, st.nf_ref, self.patch_size, window_size, self.overlap),
            };
            if (st.ref_indices.len == 0) return Error.NoPatches;

            st.plan = try dp.planSearch(allocator, st.ref_indices, st.nf_ref, st.nf_deg, self.patch_size, options.search_window_radius);
            const plan = &st.plan.?;
            try sim_jobs.append(allocator, .{
                .ref_spec = st.ref_spec,
                .nf_ref = st.nf_ref,
                .deg_spec = st.deg_spec,
                .nf_deg = st.nf_deg,
                .num_bands = NUM_BANDS,
                .patch_size = self.patch_size,
                .ref_indices = st.ref_indices[0..plan.num_patches],
                .lo = plan.lo,
                .hi = plan.hi,
                .out = plan.sims,
            });
        }

        fn searchPair(
            self: *Self,
            pair: Pair,
            st: *State,
            options: Options,
            sample_rate: u32,
            frame_duration: f64,
            lag_jobs: *std.ArrayList(accel.LagJob),
        ) !void {
            const allocator = self.allocator;
            st.matches = try dp.findOptimalDegPatchesFromSims(
                allocator,
                &st.plan.?,
                st.ref_spec,
                st.ref_indices,
                st.deg_spec,
                NUM_BANDS,
                st.nf_ref,
                self.patch_size,
                frame_duration,
            );
            if (options.disable_realignment) return;
            st.realign_plan = try realign_mod.planRealign(allocator, &st.matches.?, pair.ref, st.deg, sample_rate, self.cached_window_size, lag_jobs);
        }
    };
}

fn buildResult(
    allocator: std.mem.Allocator,
    comptime NUM_BANDS: usize,
    matches: *const dp.Matches,
    frame_duration: f64,
    mapper: QualityMapper,
    center_freqs: *const [NUM_BANDS]f64,
    lag_s: f64,
) !Result {
    const n = matches.items.len;
    const n_f: f64 = @floatFromInt(n);

    const fvnsim = try allocator.alloc(f64, NUM_BANDS);
    errdefer allocator.free(fvnsim);
    const fvnsim10 = try allocator.alloc(f64, NUM_BANDS);
    errdefer allocator.free(fvnsim10);
    const fstdnsim = try allocator.alloc(f64, NUM_BANDS);
    errdefer allocator.free(fstdnsim);
    const fvdegenergy = try allocator.alloc(f64, NUM_BANDS);
    errdefer allocator.free(fvdegenergy);
    const cfb = try allocator.dupe(f64, center_freqs);
    errdefer allocator.free(cfb);
    const patch_sims = try allocator.alloc(PatchSimilarity, n);
    errdefer allocator.free(patch_sims);
    const band_data = try allocator.alloc(f64, n * NUM_BANDS * 3);
    errdefer allocator.free(band_data);

    @memset(fvnsim, 0.0);
    @memset(fvdegenergy, 0.0);
    for (matches.items) |m| {
        for (0..NUM_BANDS) |b| {
            fvnsim[b] += m.freq_band_means[b];
            fvdegenergy[b] += m.freq_band_deg_energy[b];
        }
    }
    for (0..NUM_BANDS) |b| {
        fvnsim[b] /= n_f;
        fvdegenergy[b] /= n_f;
    }

    // fvnsim10: mean of the lowest 10% (at least one) of per-patch band means.
    {
        const sorted = try allocator.alloc(f64, n);
        defer allocator.free(sorted);
        const k: usize = @max(1, @as(usize, @intFromFloat(@trunc(n_f * 0.10))));
        for (0..NUM_BANDS) |b| {
            for (matches.items, sorted) |m, *s| s.* = m.freq_band_means[b];
            std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
            var acc: f64 = 0.0;
            for (sorted[0..k]) |x| acc += x;
            fvnsim10[b] = acc / @as(f64, @floatFromInt(k));
        }
    }

    // Pooled variance: (Σ (n_i - 1)σ_i² + n_i μ_i² - N μ²) / (N - 1)
    {
        var contribution: [NUM_BANDS]f64 = @splat(0.0);
        var total_frame_count: i64 = 0;
        for (matches.items) |m| {
            const secs_in_patch = m.ref_patch_end_time - m.ref_patch_start_time;
            const frame_count: i64 = @intFromFloat(@ceil(secs_in_patch / frame_duration));
            total_frame_count += frame_count;
            const fc: f64 = @floatFromInt(frame_count);
            for (0..NUM_BANDS) |b| {
                const dev = m.freq_band_stddevs[b];
                const mean = m.freq_band_means[b];
                contribution[b] += (fc - 1.0) * dev * dev;
                contribution[b] += fc * mean * mean;
            }
        }
        const total_f: f64 = @floatFromInt(total_frame_count);
        for (0..NUM_BANDS) |b| {
            const v = (contribution[b] - fvnsim[b] * fvnsim[b] * total_f) / (total_f - 1.0);
            fstdnsim[b] = if (v < 0.0) 0.0 else @sqrt(v);
        }
    }

    var sum: f64 = 0.0;
    for (fvnsim) |x| sum += x;
    const vnsim = sum / @as(f64, @floatFromInt(NUM_BANDS));

    var moslqo = try mapper.predict(fvnsim, fvnsim10, fstdnsim, fvdegenergy);
    if (vnsim < 0.15) moslqo = 1.0;

    for (matches.items, patch_sims, 0..) |m, *p, i| {
        const dst = band_data[i * NUM_BANDS * 3 ..][0 .. NUM_BANDS * 3];
        @memcpy(dst[0..NUM_BANDS], m.freq_band_means[0..NUM_BANDS]);
        @memcpy(dst[NUM_BANDS .. 2 * NUM_BANDS], m.freq_band_stddevs[0..NUM_BANDS]);
        @memcpy(dst[2 * NUM_BANDS ..], m.freq_band_deg_energy[0..NUM_BANDS]);
        p.* = .{
            .similarity = m.similarity,
            .ref_patch_start_time = m.ref_patch_start_time,
            .ref_patch_end_time = m.ref_patch_end_time,
            .deg_patch_start_time = m.deg_patch_start_time,
            .deg_patch_end_time = m.deg_patch_end_time,
            .freq_band_means = dst[0..NUM_BANDS],
            .freq_band_stddevs = dst[NUM_BANDS .. 2 * NUM_BANDS],
            .freq_band_deg_energy = dst[2 * NUM_BANDS ..],
        };
    }

    return .{
        .moslqo = moslqo,
        .vnsim = vnsim,
        .fvnsim = fvnsim,
        .fvnsim10 = fvnsim10,
        .fstdnsim = fstdnsim,
        .fvdegenergy = fvdegenergy,
        .center_freq_bands = cfb,
        .patch_sims = patch_sims,
        .patch_band_data = band_data,
        .alignment_lag_s = lag_s,
        .allocator = allocator,
    };
}

test "Visqol: contrabassoon48 matches reference per-band NSIM" {
    // Reference values were computed with 16-bit WAV scaled by 1/32767.
    const allocator = std.testing.allocator;
    const dir = "tests/data/conformance_testdata_subset/";
    var ref = audio.loadAsMono(allocator, dir ++ "contrabassoon48_stereo.wav") catch return error.SkipZigTest;
    defer ref.deinit();
    var deg = audio.loadAsMono(allocator, dir ++ "contrabassoon48_stereo_24kbps_aac.wav") catch return error.SkipZigTest;
    defer deg.deinit();
    for (ref.samples) |*x| x.* *= 32768.0 / 32767.0;
    for (deg.samples) |*x| x.* *= 32768.0 / 32767.0;

    const model = try svr.parseModel(allocator, @import("default_model").svr);
    var v = try Visqol.init(allocator, .{}, .{ .svr = model });
    defer v.deinit();
    var s = try v.measure(ref.samples, deg.samples, ref.sample_rate);
    defer s.deinit();

    const expected_fvnsim = [_]f64{
        0.837734260287562,   0.8765210376757312,  0.9612349526988143,  0.994765812271997,
        0.9933659740014174,  0.960257938305334,   0.9706692144323132,  0.9772403520387919,
        0.9560641930677231,  0.9555945848793426,  0.9289740025705935,  0.942510828361512,
        0.9294305338282229,  0.9241669309619619,  0.9100427352591389,  0.919950477053634,
        0.9482040584815496,  0.9671281722718106,  0.9383640364072753,  0.6663120256532349,
        0.559159573359504,   0.638509794116757,   0.5915906418759799,  0.3751543978450459,
        0.14361318464558812, 0.17565320069967247, 0.22983350597253122, 0.10406759722035226,
        0.13429604341749354, 0.16404544727107198, 0.8301770613687206,  0.96012996384962,
    };
    for (s.fvnsim, expected_fvnsim) |a, b| try std.testing.expectApproxEqAbs(b, a, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7332738291), s.vnsim, 1e-9);
}
