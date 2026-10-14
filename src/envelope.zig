// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Upper envelope in closed form, O(L).
//!
//! Upstream's Hilbert envelope keeps only Re(IFFT(X * h)), discarding the
//! analytic signal's imaginary part. That reduces to
//!   env[i] = |2*((x[i] - mean) - (-1)^i * nyq/N) - 1e-6| + mean,
//!   nyq = Σ (-1)^k (x[k] - mean), N = max(next_pow_two(L), 32).
//! Replicated verbatim so alignment xcorr sees the same envelope.
const std = @import("std");

const MIN_FFT_SIZE: usize = 32;

fn nextPowTwo(x: usize) usize {
    if (x <= 1) return 1;
    var n: usize = 1;
    while (n < x) n <<= 1;
    return n;
}

/// `out.len` must equal `signal.len`.
pub fn upperEnvelope(signal: []const f64, out: []f64) void {
    std.debug.assert(out.len == signal.len);
    const l = signal.len;
    if (l == 0) return;

    var sum: f64 = 0.0;
    for (signal) |s| sum += s;
    const mean = sum / @as(f64, @floatFromInt(l));

    const n = @max(nextPowTwo(l), MIN_FFT_SIZE);

    // Nyquist bin of the mean-centered, zero-padded signal.
    var nyquist: f64 = 0.0;
    var sign: f64 = 1.0;
    for (signal) |s| {
        nyquist += sign * (s - mean);
        sign = -sign;
    }
    const nyquist_over_n = nyquist / @as(f64, @floatFromInt(n));

    const eps: f64 = 0.000_001;
    var pos_sign = true;
    var idx: usize = 0;
    while (idx < signal.len) : (idx += 1) {
        const pad_centered = signal[idx] - mean;
        const nyq_term = if (pos_sign) nyquist_over_n else -nyquist_over_n;
        const re = 2.0 * (pad_centered - nyq_term) - eps;
        out[idx] = @abs(re) + mean;
        pos_sign = !pos_sign;
    }
}

test "upperEnvelope: zero signal yields all-mean (mean = 0)" {
    const signal: [8]f64 = @splat(0.0);
    var env: [8]f64 = undefined;
    upperEnvelope(&signal, &env);
    for (env) |v| {
        try std.testing.expectApproxEqAbs(@as(f64, 1e-6), v, 1e-12);
    }
}

test "upperEnvelope: dc-shifted constant" {
    const signal: [16]f64 = @splat(0.7);
    var env: [16]f64 = undefined;
    upperEnvelope(&signal, &env);
    for (env) |v| try std.testing.expectApproxEqAbs(@as(f64, 0.7 + 1e-6), v, 1e-12);
}

test "upperEnvelope: nonzero output for real-ish input" {
    var signal: [128]f64 = undefined;
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        const t: f64 = @as(f64, @floatFromInt(i)) / 128.0;
        signal[i] = @sin(2.0 * std.math.pi * 4.0 * t);
    }
    var env: [128]f64 = undefined;
    upperEnvelope(&signal, &env);
    var any_nonzero = false;
    for (env) |v| {
        try std.testing.expect(std.math.isFinite(v));
        if (v > 1e-3) any_nonzero = true;
    }
    try std.testing.expect(any_nonzero);
}
