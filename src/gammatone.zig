// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Gammatone filterbank and spectrogram builder. All math in f64 for parity.
//!
//! Each band is a 4th-order gammatone realised as four biquads sharing one
//! denominator; only stage 1's numerator is gain-normalised.
//! Spectrogram layout: row-major [bands][frames], row 0 = lowest band.
const std = @import("std");
const build_options = @import("build_options");
const erb_mod = @import("dsp/erb.zig");
const Complex = std.math.Complex;

pub const NUM_FILTER_CONDITIONS: usize = 2;

/// Per-band gammatone coefficients.
pub const Band = struct {
    a0: f64,
    a11: f64,
    a12: f64,
    a13: f64,
    a14: f64,
    b1: f64,
    b2: f64,
    gain: f64,

    /// Second numerator tap, identically zero for every band; the leading
    /// denominator tap is 1. Comptime so the hot loops drop the products.
    pub const a2: f64 = 0.0;
};

pub fn Filters(comptime NUM_BANDS: usize) type {
    return struct {
        const Self = @This();

        bands: [NUM_BANDS]Band,
        /// Center frequencies (Hz), ascending, parallel to `bands`.
        center_freqs: [NUM_BANDS]f64,
        sample_rate: u32,

        pub fn init(sample_rate: u32, low_freq: f64, high_freq_in: f64) Self {
            const sr_f: f64 = @floatFromInt(sample_rate);
            const high_freq = @min(high_freq_in, sr_f / 2.0);

            // Descending; reversed below.
            const cf_desc = erb_mod.uniformCenterFreqs(f64, NUM_BANDS, low_freq, high_freq);
            const t: f64 = 1.0 / sr_f;
            const pi: f64 = std.math.pi;

            var desc: [NUM_BANDS]Band = undefined;
            var i: usize = 0;
            while (i < NUM_BANDS) : (i += 1) {
                const cf = cf_desc[i];
                desc[i] = computeBand(cf, t, pi);
            }

            var bands_asc: [NUM_BANDS]Band = undefined;
            var cf_asc: [NUM_BANDS]f64 = undefined;
            i = 0;
            while (i < NUM_BANDS) : (i += 1) {
                bands_asc[i] = desc[NUM_BANDS - 1 - i];
                cf_asc[i] = cf_desc[NUM_BANDS - 1 - i];
            }

            return .{
                .bands = bands_asc,
                .center_freqs = cf_asc,
                .sample_rate = sample_rate,
            };
        }
    };
}

/// The complex coefficient algebra reduces to real values except for the
/// gain, which is computed in complex arithmetic for bit-exact parity.
fn computeBand(cf: f64, t: f64, pi: f64) Band {
    const erb = erb_mod.erbGeneralized(f64, cf, 1.0);
    const big_b = 1.019 * 2.0 * pi * erb;
    const exp_bt = std.math.exp(big_b * t);
    const inv_exp_bt = 1.0 / exp_bt;
    const exp_neg_2bt = std.math.exp(-2.0 * big_b * t);

    const omega = 2.0 * cf * pi * t;
    const cos_w = @cos(omega);
    const sin_w = @sin(omega);

    const b1_re = -2.0 * cos_w * inv_exp_bt;
    const b2_re = exp_neg_2bt;

    const sin_t = sin_w * t;
    const sqrt_3p_p1 = @sqrt(3.0 + std.math.pow(f64, 2.0, 1.5));
    const sqrt_3m_p1 = @sqrt(3.0 - std.math.pow(f64, 2.0, 1.5));
    const b_pos = sin_t * 2.0 * sqrt_3p_p1;
    const b_neg = sin_t * 2.0 * sqrt_3m_p1;
    const a_term = cos_w * 2.0 * t;

    const a11_re = -(a_term * inv_exp_bt + b_pos * inv_exp_bt) / 2.0;
    const a12_re = -(a_term * inv_exp_bt - b_pos * inv_exp_bt) / 2.0;
    const a13_re = -(a_term * inv_exp_bt + b_neg * inv_exp_bt) / 2.0;
    const a14_re = -(a_term * inv_exp_bt - b_neg * inv_exp_bt) / 2.0;

    // gain = |x1*x2*x3*x4 / x5^4|
    const i_unit = Complex(f64){ .re = 0.0, .im = 1.0 };
    const four_i_cf_pi_t = cmulScalar(i_unit, 4.0 * cf * pi * t);
    const x_exp = cexp(four_i_cf_pi_t);

    const x01 = cmulScalar(x_exp, -2.0 * t);

    // x02 = 2 * exp(-(B*t) + 2i*cf*pi*t) * t
    const inner = Complex(f64){ .re = -big_b * t, .im = 2.0 * cf * pi * t };
    const x02 = cmulScalar(cexp(inner), 2.0 * t);

    const xcos = Complex(f64){ .re = cos_w, .im = 0.0 };
    const xsin = Complex(f64){ .re = sin_w, .im = 0.0 };

    const s1 = @sqrt(3.0 - std.math.pow(f64, 2.0, 1.5));
    const s2 = @sqrt(3.0 + std.math.pow(f64, 2.0, 1.5));

    const x12 = csub(xcos, cmulScalar(xsin, s1));
    const x22 = cadd(xcos, cmulScalar(xsin, s1));
    const x32 = csub(xcos, cmulScalar(xsin, s2));
    const x42 = cadd(xcos, cmulScalar(xsin, s2));

    const x1 = cadd(x01, cmul(x02, x12));
    const x2 = cadd(x01, cmul(x02, x22));
    const x3 = cadd(x01, cmul(x02, x32));
    const x4 = cadd(x01, cmul(x02, x42));

    // x5 = -2/exp(2Bt) - 2*xExp + 2*(1+xExp)/exp(Bt)
    const exp_2bt = Complex(f64){ .re = std.math.exp(2.0 * big_b * t), .im = 0.0 };
    const exp_bt_c = Complex(f64){ .re = exp_bt, .im = 0.0 };
    const term1 = cdiv(Complex(f64){ .re = -2.0, .im = 0.0 }, exp_2bt);
    const term2 = cmulScalar(x_exp, -2.0);
    const one_p_xexp = cadd(Complex(f64){ .re = 1.0, .im = 0.0 }, x_exp);
    const term3 = cmulScalar(cdiv(one_p_xexp, exp_bt_c), 2.0);
    const x5 = cadd(cadd(term1, term2), term3);

    const x5_p4 = cmul(cmul(x5, x5), cmul(x5, x5));
    const num = cmul(cmul(x1, x2), cmul(x3, x4));
    const ratio = cdiv(num, x5_p4);
    const gain = @sqrt(ratio.re * ratio.re + ratio.im * ratio.im);

    return .{
        .a0 = t,
        .a11 = a11_re,
        .a12 = a12_re,
        .a13 = a13_re,
        .a14 = a14_re,
        .b1 = b1_re,
        .b2 = b2_re,
        .gain = gain,
    };
}

inline fn cadd(a: Complex(f64), b: Complex(f64)) Complex(f64) {
    return .{ .re = a.re + b.re, .im = a.im + b.im };
}
inline fn csub(a: Complex(f64), b: Complex(f64)) Complex(f64) {
    return .{ .re = a.re - b.re, .im = a.im - b.im };
}
inline fn cmul(a: Complex(f64), b: Complex(f64)) Complex(f64) {
    return .{
        .re = a.re * b.re - a.im * b.im,
        .im = a.re * b.im + a.im * b.re,
    };
}
inline fn cmulScalar(a: Complex(f64), s: f64) Complex(f64) {
    return .{ .re = a.re * s, .im = a.im * s };
}
inline fn cdiv(a: Complex(f64), b: Complex(f64)) Complex(f64) {
    const denom = b.re * b.re + b.im * b.im;
    return .{
        .re = (a.re * b.re + a.im * b.im) / denom,
        .im = (a.im * b.re - a.re * b.im) / denom,
    };
}
inline fn cexp(z: Complex(f64)) Complex(f64) {
    const e = std.math.exp(z.re);
    return .{ .re = e * @cos(z.im), .im = e * @sin(z.im) };
}

/// IIR state for one band's 4-stage cascade (DF2T).
pub const BandState = struct {
    s: [4][NUM_FILTER_CONDITIONS]f64 = @splat(@splat(0.0)),

    pub fn reset(self: *BandState) void {
        self.s = @splat(@splat(0.0));
    }
};

/// One DF2T biquad stage. The `Band.a2 * s` numerator term is dropped:
/// `±0 - x == -x` up to the sign of a zero, which no output observes.
inline fn applyStage(
    n0: f64,
    n1: f64,
    d1: f64,
    d2: f64,
    in: []const f64,
    out: []f64,
    cond: *[NUM_FILTER_CONDITIONS]f64,
) void {
    var c0 = cond[0];
    var c1 = cond[1];
    for (in, 0..) |s, i| {
        const filtered = n0 * s + c0;
        c0 = n1 * s + c1 - d1 * filtered;
        c1 = -(d2 * filtered);
        out[i] = filtered;
    }
    cond[0] = c0;
    cond[1] = c1;
}

/// Filter `signal` through one band. `state` persists across calls.
/// `scratch_a`, `scratch_b`, `out` must be `>= signal.len`.
pub fn filterBand(
    band: Band,
    state: *BandState,
    signal: []const f64,
    scratch_a: []f64,
    scratch_b: []f64,
    out: []f64,
) void {
    std.debug.assert(scratch_a.len >= signal.len);
    std.debug.assert(scratch_b.len >= signal.len);
    std.debug.assert(out.len >= signal.len);

    const gi = 1.0 / band.gain;
    applyStage(
        band.a0 * gi,
        band.a11 * gi,
        band.b1,
        band.b2,
        signal,
        scratch_a[0..signal.len],
        &state.s[0],
    );
    applyStage(
        band.a0,
        band.a12,
        band.b1,
        band.b2,
        scratch_a[0..signal.len],
        scratch_b[0..signal.len],
        &state.s[1],
    );
    applyStage(
        band.a0,
        band.a13,
        band.b1,
        band.b2,
        scratch_b[0..signal.len],
        scratch_a[0..signal.len],
        &state.s[2],
    );
    applyStage(
        band.a0,
        band.a14,
        band.b1,
        band.b2,
        scratch_a[0..signal.len],
        out[0..signal.len],
        &state.s[3],
    );
}

/// RMS of one band's output from zero initial state.
pub fn filterBandRmsFresh(band: Band, signal: []const f64) f64 {
    const gi = 1.0 / band.gain;
    const s1n0 = band.a0 * gi;
    const s1n1 = band.a11 * gi;
    const s2n1 = band.a12;
    const s3n1 = band.a13;
    const s4n1 = band.a14;
    const ca0 = band.a0;
    const d1 = band.b1;
    const d2 = band.b2;

    var s1c0: f64 = 0;
    var s1c1: f64 = 0;
    var s2c0: f64 = 0;
    var s2c1: f64 = 0;
    var s3c0: f64 = 0;
    var s3c1: f64 = 0;
    var s4c0: f64 = 0;
    var s4c1: f64 = 0;
    var sum_sq: f64 = 0;

    for (signal) |s| {
        const f1 = s1n0 * s + s1c0;
        s1c0 = s1n1 * s + s1c1 - d1 * f1;
        s1c1 = -(d2 * f1);
        const f2 = ca0 * f1 + s2c0;
        s2c0 = s2n1 * f1 + s2c1 - d1 * f2;
        s2c1 = -(d2 * f2);
        const f3 = ca0 * f2 + s3c0;
        s3c0 = s3n1 * f2 + s3c1 - d1 * f3;
        s3c1 = -(d2 * f3);
        const f4 = ca0 * f3 + s4c0;
        s4c0 = s4n1 * f3 + s4c1 - d1 * f4;
        s4c1 = -(d2 * f4);
        sum_sq += f4 * f4;
    }
    const inv_n = 1.0 / @as(f64, @floatFromInt(signal.len));
    return @sqrt(sum_sq * inv_n);
}

/// Symmetric Hann: w[i] = 0.5 - 0.5 * cos(2π i / (size - 1)).
pub fn hannWindow(size: usize, out: []f64) void {
    std.debug.assert(out.len >= size);
    const denom: f64 = @max(1.0, @as(f64, @floatFromInt(size)) - 1.0);
    var i: usize = 0;
    while (i < size) : (i += 1) {
        out[i] = 0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / denom);
    }
}

pub const Error = error{ TooFewSamples, OutputBufferTooSmall };

pub fn numFrames(signal_len: usize, window_size: usize, hop_size: usize) usize {
    if (signal_len < window_size) return 0;
    return 1 + (signal_len - window_size) / hop_size;
}

/// Frames per vector; `-Dgammatone-lanes` overrides. Two native vectors per
/// state keep the FP pipes busy behind each stage's recurrence; one is
/// latency-bound, more only adds register pressure.
const LANES = if (build_options.gammatone_lanes != 0)
    build_options.gammatone_lanes
else
    2 * (std.simd.suggestVectorLength(f64) orelse 2);
/// `buildSpectrogram`'s `frame_buf` must hold this many analysis windows
/// (more than LANES when the vector is padded, e.g. 3 lanes in 4 slots).
pub const FRAME_BUF_WINDOWS = @sizeOf(@Vector(LANES, f64)) / @sizeOf(f64);

/// Vectorised `filterBandRmsFresh` over independent frames in lanes.
fn filterBandRmsFreshVec(band: Band, w: []const @Vector(LANES, f64)) @Vector(LANES, f64) {
    const V = @Vector(LANES, f64);
    const k = VecCoeffs(LANES).init(band);
    var sum: V = @splat(0.0);
    var st = VecState(LANES){};
    for (w) |x| {
        const y = st.step(&k, x);
        sum += y * y;
    }
    const inv_n: V = @splat(1.0 / @as(f64, @floatFromInt(w.len)));
    return @sqrt(sum * inv_n);
}

/// `filterBandRmsFresh`'s coefficients, splatted once per band.
fn VecCoeffs(comptime N: usize) type {
    const V = @Vector(N, f64);
    return struct {
        s1n0: V,
        s1n1: V,
        s2n1: V,
        s3n1: V,
        s4n1: V,
        ca0: V,
        d1: V,
        d2: V,

        fn init(band: Band) @This() {
            const gi = 1.0 / band.gain;
            return .{
                .s1n0 = @splat(band.a0 * gi),
                .s1n1 = @splat(band.a11 * gi),
                .s2n1 = @splat(band.a12),
                .s3n1 = @splat(band.a13),
                .s4n1 = @splat(band.a14),
                .ca0 = @splat(band.a0),
                .d1 = @splat(band.b1),
                .d2 = @splat(band.b2),
            };
        }
    };
}

fn VecState(comptime N: usize) type {
    const V = @Vector(N, f64);
    return struct {
        s1c0: V = @splat(0.0),
        s1c1: V = @splat(0.0),
        s2c0: V = @splat(0.0),
        s2c1: V = @splat(0.0),
        s3c0: V = @splat(0.0),
        s3c1: V = @splat(0.0),
        s4c0: V = @splat(0.0),
        s4c1: V = @splat(0.0),

        /// Same operation order as `filterBandRmsFresh`.
        inline fn step(self: *@This(), k: *const VecCoeffs(N), s: V) V {
            const f1 = k.s1n0 * s + self.s1c0;
            self.s1c0 = k.s1n1 * s + self.s1c1 - k.d1 * f1;
            self.s1c1 = -(k.d2 * f1);
            const f2 = k.ca0 * f1 + self.s2c0;
            self.s2c0 = k.s2n1 * f1 + self.s2c1 - k.d1 * f2;
            self.s2c1 = -(k.d2 * f2);
            const f3 = k.ca0 * f2 + self.s3c0;
            self.s3c0 = k.s3n1 * f2 + self.s3c1 - k.d1 * f3;
            self.s3c1 = -(k.d2 * f3);
            const f4 = k.ca0 * f3 + self.s4c0;
            self.s4c0 = k.s4n1 * f3 + self.s4c1 - k.d1 * f4;
            self.s4c1 = -(k.d2 * f4);
            return f4;
        }
    };
}

/// Scratch for `buildSpectrogram`, correctly sized and aligned.
pub const FrameBuf = []align(@alignOf(@Vector(LANES, f64))) f64;
pub fn allocFrameBuf(allocator: std.mem.Allocator, window_size: usize) !FrameBuf {
    return allocator.alignedAlloc(f64, .fromByteUnits(@alignOf(@Vector(LANES, f64))), window_size * FRAME_BUF_WINDOWS);
}

/// Writes `out[band * num_frames + frame]`; returns num_frames.
/// `hann` has length `window_size`; `frame_buf` comes from `allocFrameBuf`.
pub fn buildSpectrogram(
    comptime NUM_BANDS: usize,
    filters: *const Filters(NUM_BANDS),
    signal: []const f64,
    window_size: usize,
    hop_size: usize,
    hann: []const f64,
    frame_buf: FrameBuf,
    out: []f64,
) Error!usize {
    return buildSpectrogramBands(&filters.bands, signal, window_size, hop_size, hann, frame_buf, out);
}

/// `buildSpectrogram` with a runtime band list.
pub fn buildSpectrogramBands(
    bands: []const Band,
    signal: []const f64,
    window_size: usize,
    hop_size: usize,
    hann: []const f64,
    frame_buf: FrameBuf,
    out: []f64,
) Error!usize {
    std.debug.assert(hann.len >= window_size);
    std.debug.assert(frame_buf.len >= window_size * FRAME_BUF_WINDOWS);
    if (signal.len < window_size) return Error.TooFewSamples;
    if (hop_size == 0) return Error.TooFewSamples;
    const nf = numFrames(signal.len, window_size, hop_size);
    if (out.len < bands.len * nf) return Error.OutputBufferTooSmall;

    // Frames start from zero state, so LANES frames run side by side;
    // each lane is bit-identical to `filterBandRmsFresh`.
    const w: []@Vector(LANES, f64) = @as([*]@Vector(LANES, f64), @ptrCast(frame_buf.ptr))[0..window_size];
    var f: usize = 0;
    while (f < nf) : (f += LANES) {
        const lanes = @min(LANES, nf - f);
        for (0..window_size) |i| {
            var v: @Vector(LANES, f64) = @splat(0.0);
            inline for (0..LANES) |l| {
                if (l < lanes) v[l] = signal[(f + l) * hop_size + i] * hann[i];
            }
            w[i] = v;
        }
        for (bands, 0..) |band, b| {
            const rms: [LANES]f64 = filterBandRmsFreshVec(band, w);
            @memcpy(out[b * nf + f ..][0..lanes], rms[0..lanes]);
        }
    }
    return nf;
}

test "Filters: 32-band 48kHz center freqs are sorted ascending" {
    const F = Filters(32);
    const f = F.init(48000, 50.0, 24000.0);
    var i: usize = 1;
    while (i < 32) : (i += 1) {
        try std.testing.expect(f.center_freqs[i] > f.center_freqs[i - 1]);
    }
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), f.center_freqs[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 20844.7852), f.center_freqs[31], 1e-3);
}

test "Filters: gain is finite and positive" {
    const F = Filters(32);
    const f = F.init(48000, 50.0, 24000.0);
    for (f.bands) |b| {
        try std.testing.expect(std.math.isFinite(b.gain));
        try std.testing.expect(b.gain > 0.0);
        try std.testing.expect(std.math.isFinite(b.b1));
        try std.testing.expect(std.math.isFinite(b.b2));
    }
}

test "Filters: lowest band reference output (first 3 samples)" {
    const F = Filters(32);
    const f = F.init(48000, 50.0, 24000.0);
    const samples = [_]f64{ 0.2, 0.4, 0.6, 0.8, 0.9, 0.1, 0.3, 0.5, 0.7, 0.9 };
    var scratch_a: [16]f64 = undefined;
    var scratch_b: [16]f64 = undefined;
    var out: [10]f64 = undefined;
    var state = BandState{};
    filterBand(f.bands[0], &state, &samples, &scratch_a, &scratch_b, &out);

    const epsilon = 1e-13;
    try std.testing.expectApproxEqAbs(@as(f64, 1.028e-10), out[0], epsilon);
    try std.testing.expectApproxEqAbs(@as(f64, 6.15143e-10), out[1], 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 2.14718e-09), out[2], 1e-13);
}

test "hannWindow: symmetric, endpoints are 0" {
    var w: [16]f64 = undefined;
    hannWindow(16, &w);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), w[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), w[15], 1e-12);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try std.testing.expectApproxEqAbs(w[i], w[15 - i], 1e-12);
    }
}

test "buildSpectrogram: reference value" {
    const allocator = std.testing.allocator;
    const wav_path = "tests/data/conformance_testdata_subset/contrabassoon48_stereo.wav";
    const audio = @import("audio.zig");
    var sig = audio.loadAsMono(allocator, wav_path) catch return error.SkipZigTest;
    defer sig.deinit();

    const NB = 32;
    const F = Filters(NB);
    const f = F.init(sig.sample_rate, 50.0, @as(f64, @floatFromInt(sig.sample_rate)) / 2.0);

    const window_size: usize = @intFromFloat(@round(@as(f64, @floatFromInt(sig.sample_rate)) * 0.08));
    const hop_size: usize = @intFromFloat(@as(f64, @floatFromInt(window_size)) * 0.25);

    const hann = try allocator.alloc(f64, window_size);
    defer allocator.free(hann);
    hannWindow(window_size, hann);
    const frame_buf = try allocFrameBuf(allocator, window_size);
    defer allocator.free(frame_buf);

    const nf = numFrames(sig.samples.len, window_size, hop_size);
    const spec = try allocator.alloc(f64, NB * nf);
    defer allocator.free(spec);
    _ = try buildSpectrogram(NB, &f, sig.samples, window_size, hop_size, hann, frame_buf, spec);

    try std.testing.expectApproxEqAbs(@as(f64, 1.363673e-5), spec[0], 1e-9);
}

test "buildSpectrogramExplicit: shape and finiteness" {
    const NB = 32;
    const F = Filters(NB);
    const f = F.init(48000, 50.0, 24000.0);
    const sample_rate: u32 = 48000;
    const window_size: usize = @intFromFloat(@as(f64, @floatFromInt(sample_rate)) * 0.08);
    const hop = @as(usize, @intFromFloat(@as(f64, @floatFromInt(window_size)) * 0.25));

    const allocator = std.testing.allocator;
    const sig_len: usize = window_size * 4 + hop * 7;
    const sig = try allocator.alloc(f64, sig_len);
    defer allocator.free(sig);
    var rng = std.Random.DefaultPrng.init(0xabc123);
    const r = rng.random();
    for (sig) |*x| x.* = r.float(f64) * 2.0 - 1.0;

    const nf = numFrames(sig_len, window_size, hop);
    const hann = try allocator.alloc(f64, window_size);
    defer allocator.free(hann);
    hannWindow(window_size, hann);
    const frame_buf = try allocFrameBuf(allocator, window_size);
    defer allocator.free(frame_buf);
    const spec = try allocator.alloc(f64, NB * nf);
    defer allocator.free(spec);

    const got = try buildSpectrogram(NB, &f, sig, window_size, hop, hann, frame_buf, spec);
    try std.testing.expectEqual(nf, got);
    for (spec) |v| {
        try std.testing.expect(std.math.isFinite(v));
        try std.testing.expect(v >= 0.0);
    }
}

test "buildSpectrogram: SIMD lanes are bit-identical to filterBandRmsFresh" {
    const NB = 32;
    const f = Filters(NB).init(48000, 50.0, 24000.0);
    const allocator = std.testing.allocator;
    const window_size: usize = 384;
    const hop: usize = 96;
    // Frame count not a multiple of LANES, to cover the partial group.
    const nf = 3 * LANES + 1;
    const sig = try allocator.alloc(f64, window_size + (nf - 1) * hop);
    defer allocator.free(sig);
    var rng = std.Random.DefaultPrng.init(0x9a77);
    const r = rng.random();
    for (sig) |*x| x.* = r.float(f64) * 2.0 - 1.0;

    const hann = try allocator.alloc(f64, window_size);
    defer allocator.free(hann);
    hannWindow(window_size, hann);
    const frame_buf = try allocFrameBuf(allocator, window_size);
    defer allocator.free(frame_buf);
    const spec = try allocator.alloc(f64, NB * nf);
    defer allocator.free(spec);
    _ = try buildSpectrogram(NB, &f, sig, window_size, hop, hann, frame_buf, spec);

    const frame = try allocator.alloc(f64, window_size);
    defer allocator.free(frame);
    for (0..nf) |fi| {
        for (frame, sig[fi * hop ..][0..window_size], hann) |*o, x, w| o.* = x * w;
        for (f.bands, 0..) |band, b| {
            try std.testing.expectEqual(filterBandRmsFresh(band, frame), spec[b * nf + fi]);
        }
    }
}
