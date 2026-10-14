// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Speech-mode reference patch selection by RMS VAD (upstream
//! `VadPatchCreator` + `RmsVad`). Upstream quirks kept: normalise by max
//! sample (not max |x|), scan starts at *sample* `patch_size/2 - 1`, and
//! i16 scaling truncates after clamping.
const std = @import("std");

const SILENT_CHUNK_COUNT: usize = 3;
const RMS_THRESHOLD: f64 = 5000.0;
const FRAMES_WITH_VA_THRESHOLD: f64 = 1.0;

/// Reference patch start frames whose span contains voice activity.
pub fn refPatchIndices(
    allocator: std.mem.Allocator,
    ref: []const f64,
    num_frames: usize,
    patch_size: usize,
    window_size: usize,
    overlap: f64,
) ![]usize {
    const frame_size: f64 = @as(f64, @floatFromInt(window_size)) * overlap;
    const frame_len: usize = @intFromFloat(frame_size);
    const patch_sample_len: usize = @intFromFloat(@as(f64, @floatFromInt(patch_size)) * frame_size);
    const first_patch_idx: usize = patch_size / 2 - 1;
    if (num_frames <= first_patch_idx or frame_len == 0) return allocator.alloc(usize, 0);
    const patch_count = (num_frames - first_patch_idx) / patch_size;
    const total_samples = patch_count * patch_sample_len;

    var max_val: f64 = -std.math.inf(f64);
    for (ref) |x| max_val = @max(max_val, x);

    const n_chunks = total_samples / frame_len;
    const chunk_active = try allocator.alloc(bool, n_chunks);
    defer allocator.free(chunk_active);
    for (chunk_active, 0..) |*active, c| {
        var square: f64 = 0.0;
        for (0..frame_len) |j| {
            const idx = first_patch_idx + c * frame_len + j;
            const x = if (idx < ref.len) ref[idx] / max_val else 0.0;
            const scaled = std.math.clamp(x * 32768.0, -32768.0, 32767.0);
            const s: f64 = @trunc(scaled);
            square += s * s;
        }
        const rms = @sqrt(square / @as(f64, @floatFromInt(frame_len)));
        active.* = rms >= RMS_THRESHOLD;
    }

    // First SILENT_CHUNK_COUNT-1 results are forced active; later a chunk is
    // inactive only if it and the previous SILENT_CHUNK_COUNT-1 are silent.
    const vad_len = @max(n_chunks, SILENT_CHUNK_COUNT - 1);
    const vad_res = try allocator.alloc(f64, vad_len);
    defer allocator.free(vad_res);
    for (0..SILENT_CHUNK_COUNT - 1) |i| vad_res[i] = 1.0;
    var i: usize = SILENT_CHUNK_COUNT - 1;
    while (i < n_chunks) : (i += 1) {
        var prev_silent = true;
        for (1..SILENT_CHUNK_COUNT) |j| {
            if (chunk_active[i - j]) {
                prev_silent = false;
                break;
            }
        }
        vad_res[i] = if (!chunk_active[i] and prev_silent) 0.0 else 1.0;
    }

    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(allocator);
    var patch_idx = first_patch_idx;
    for (0..patch_count) |p| {
        var frames_with_va: f64 = 0.0;
        const lo = p * patch_size;
        for (lo..lo + patch_size) |k| {
            if (k < vad_res.len) frames_with_va += vad_res[k];
        }
        if (frames_with_va >= FRAMES_WITH_VA_THRESHOLD) try out.append(allocator, patch_idx);
        patch_idx += patch_size;
    }
    return out.toOwnedSlice(allocator);
}

test "refPatchIndices: silence after the forced-active lead-in drops patches" {
    const allocator = std.testing.allocator;
    // 16 kHz, window 1280, hop 320, patch 20 → 6400 samples per patch.
    var sig = try allocator.alloc(f64, 16000 * 4);
    defer allocator.free(sig);
    @memset(sig, 0.0);
    for (16000..32000) |n| sig[n] = @sin(@as(f64, @floatFromInt(n)) * 0.1);
    const nf = 1 + (sig.len - 1280) / 320;
    const idx = try refPatchIndices(allocator, sig, nf, 20, 1280, 0.25);
    defer allocator.free(idx);
    try std.testing.expect(idx.len >= 2 and idx.len < (nf - 9) / 20);
    try std.testing.expectEqual(@as(usize, 9), idx[0]);
}
