// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Spectrogram prep: dB conversion, per-frame noise floor, joint minimum
//! subtract. Row-major `[num_bands][num_frames]`.
const std = @import("std");

/// Noise floor relative to per-frame peak (dB), shared by ref + deg.
pub const NOISE_FLOOR_RELATIVE_TO_PEAK_DB: f64 = 45.0;
/// Absolute noise floor (dB).
pub const NOISE_FLOOR_ABSOLUTE_DB: f64 = -45.0;

/// `data[i] = max(10*log10(|data[i]| or epsilon), floor)`.
pub fn convertToDbAndRaiseFloor(data: []f64, floor: f64) void {
    for (data) |*x| {
        const sample = if (x.* == 0.0) std.math.floatEps(f64) else @abs(x.*);
        const db = 10.0 * std.math.log10(sample);
        x.* = @max(db, floor);
    }
}

/// Clamp both spectrograms per frame to `max(column) - relative_floor`,
/// over the shared frame prefix.
pub fn raiseFloorPerFrame(
    ref: []f64,
    deg: []f64,
    num_bands: usize,
    num_frames_ref: usize,
    num_frames_deg: usize,
    relative_floor: f64,
) void {
    std.debug.assert(ref.len == num_bands * num_frames_ref);
    std.debug.assert(deg.len == num_bands * num_frames_deg);
    const min_frames = @min(num_frames_ref, num_frames_deg);
    var c: usize = 0;
    while (c < min_frames) : (c += 1) {
        var col_max = -std.math.inf(f64);
        var r: usize = 0;
        while (r < num_bands) : (r += 1) {
            const sv = ref[r * num_frames_ref + c];
            const ov = deg[r * num_frames_deg + c];
            const m = @max(sv, ov);
            if (m > col_max) col_max = m;
        }
        const floor_db = col_max - relative_floor;
        r = 0;
        while (r < num_bands) : (r += 1) {
            const ri = r * num_frames_ref + c;
            if (ref[ri] < floor_db) ref[ri] = floor_db;
            const oi = r * num_frames_deg + c;
            if (deg[oi] < floor_db) deg[oi] = floor_db;
        }
    }
}

pub fn subtractJointMinimum(ref: []f64, deg: []f64) void {
    var lo = std.math.inf(f64);
    for (ref) |v| if (v < lo) {
        lo = v;
    };
    for (deg) |v| if (v < lo) {
        lo = v;
    };
    for (ref) |*v| v.* -= lo;
    for (deg) |*v| v.* -= lo;
}

/// Linear ref and deg in, comparison-ready dB out.
pub fn prepareForComparison(
    ref: []f64,
    deg: []f64,
    num_bands: usize,
    num_frames_ref: usize,
    num_frames_deg: usize,
) void {
    convertToDbAndRaiseFloor(ref, NOISE_FLOOR_ABSOLUTE_DB);
    convertToDbAndRaiseFloor(deg, NOISE_FLOOR_ABSOLUTE_DB);
    raiseFloorPerFrame(ref, deg, num_bands, num_frames_ref, num_frames_deg, NOISE_FLOOR_RELATIVE_TO_PEAK_DB);
    subtractJointMinimum(ref, deg);
}

/// `prepareForComparison` with `ref` already in dB.
pub fn prepareForComparisonRefDb(
    ref: []f64,
    deg: []f64,
    num_bands: usize,
    num_frames_ref: usize,
    num_frames_deg: usize,
) void {
    convertToDbAndRaiseFloor(deg, NOISE_FLOOR_ABSOLUTE_DB);
    raiseFloorPerFrame(ref, deg, num_bands, num_frames_ref, num_frames_deg, NOISE_FLOOR_RELATIVE_TO_PEAK_DB);
    subtractJointMinimum(ref, deg);
}

test "convertToDbAndRaiseFloor: reference values" {
    var data = [_]f64{ 10.21, -4.63, 0.54, 87.98, 0.065, 0.0, -53.2, 8.7, 0.0, -2.76 };
    const expected = [_]f64{
        10.0903, 6.6558, -2.6761,   19.4438, -11.8709, -156.5356,
        17.2591, 9.3952, -156.5356, 4.4091,
    };
    convertToDbAndRaiseFloor(&data, -1000.0);
    for (data, expected) |a, e| try std.testing.expectApproxEqAbs(e, a, 1e-3);
}

test "convertToDbAndRaiseFloor: clamps to floor" {
    var data = [_]f64{ 1.0, 0.001, 0.000001 };
    convertToDbAndRaiseFloor(&data, -45.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), data[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -30.0), data[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -45.0), data[2], 1e-9);
}

test "subtractJointMinimum: shifts both by the joint min" {
    var a = [_]f64{ 5.0, -3.0, 2.0 };
    var b = [_]f64{ 4.0, -7.0, 1.0 };
    subtractJointMinimum(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), a[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), a[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), a[2], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 11.0), b[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), b[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), b[2], 1e-12);
}

test "raiseFloorPerFrame: clamps below per-column max minus threshold" {
    // 2 bands x 2 frames. Floors: frame 0 = 10-45, frame 1 = 20-45.
    var ref = [_]f64{ 10.0, -50.0, 5.0, 20.0 };
    var deg = [_]f64{ 3.0, -200.0, -100.0, -1.0 };
    raiseFloorPerFrame(&ref, &deg, 2, 2, 2, 45.0);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), ref[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -25.0), ref[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), ref[2], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), ref[3], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), deg[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -25.0), deg[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -35.0), deg[2], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), deg[3], 1e-12);
}
