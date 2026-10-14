// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Glasberg & Moore (1990) ERB primitives, generic over float type.
const std = @import("std");

/// Q value of the auditory filter (Glasberg & Moore 1990).
pub const EAR_Q: f64 = 9.26449;
/// Minimum bandwidth at f = 0 Hz, in Hz.
pub const MIN_BW: f64 = 24.7;
pub const ERB_ORDER: f64 = 1.0;

/// Classic ERB, `24.7 * (4.37*f/1000 + 1)`; the constants `psy/sfb.zig` was trained against.
pub inline fn erbN(comptime T: type, f: T) T {
    return @as(T, 24.7) * (@as(T, 4.37) * f / @as(T, 1000.0) + @as(T, 1.0));
}

/// `((f/EAR_Q)^order + MIN_BW^order)^(1/order)`; at order 1 the unrounded
/// form of `erbN` (4.37 rounds 1000/(EAR_Q*MIN_BW)). Used by the gammatone bank.
pub inline fn erbGeneralized(comptime T: type, f: T, comptime order: T) T {
    const q: T = @floatCast(EAR_Q);
    const m: T = @floatCast(MIN_BW);
    if (order == @as(T, 1.0)) return f / q + m;
    const a = std.math.pow(T, f / q, order);
    const b = std.math.pow(T, m, order);
    return std.math.pow(T, a + b, @as(T, 1.0) / order);
}

/// ERB-uniform center frequencies in `[low_freq, high_freq]`, descending.
pub fn uniformCenterFreqs(
    comptime T: type,
    comptime N: usize,
    low_freq: T,
    high_freq: T,
) [N]T {
    const q: T = @floatCast(EAR_Q);
    const m: T = @floatCast(MIN_BW);
    const a: T = -(q * m);
    const b: T = -@log(high_freq + q * m);
    const c: T = @log(low_freq + q * m);
    const d: T = high_freq + q * m;
    const e: T = (b + c) / @as(T, @floatFromInt(N));

    var out: [N]T = undefined;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const idx: T = @as(T, @floatFromInt(i)) + @as(T, 1.0);
        const f = @exp(idx * e) * d;
        out[i] = a + f;
    }
    return out;
}

test "erbN matches generalized at order=1 within rounding" {
    const fs = [_]f64{ 50, 200, 1000, 4000, 16000 };
    for (fs) |f| {
        const a = erbN(f64, f);
        const b = erbGeneralized(f64, f, 1.0);
        const rel = @abs(a - b) / b;
        try std.testing.expect(rel < 1e-4);
    }
}

test "uniformCenterFreqs first/last match reference" {
    const cf = uniformCenterFreqs(f64, 32, 50.0, 24000.0);
    try std.testing.expectApproxEqAbs(@as(f64, 20844.7852), cf[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), cf[31], 1e-6);
    var i: usize = 1;
    while (i < cf.len) : (i += 1) {
        try std.testing.expect(cf[i] < cf[i - 1]);
    }
}
