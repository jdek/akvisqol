// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Patch alignment: DP search for the best degraded patch per reference patch.
//! Spectrograms and patches are row-major [bands][frames].
const std = @import("std");
const nsim = @import("nsim.zig");

pub const Error = error{
    SignalsTooDifferent,
    ReferenceSpectrogramTooSmall,
    OutOfMemory,
};

/// Per-patch result of the post-DP scoring pass.
pub const Match = struct {
    /// Zero when `!valid`.
    similarity: f64 = 0.0,
    ref_patch_start_time: f64 = 0.0,
    ref_patch_end_time: f64 = 0.0,
    deg_patch_start_time: f64 = 0.0,
    deg_patch_end_time: f64 = 0.0,
    /// One entry per band.
    freq_band_means: []f64,
    freq_band_stddevs: []f64,
    freq_band_deg_energy: []f64,
    /// False when the backtrace points at the same offset (no real match).
    valid: bool = true,
};

pub const Matches = struct {
    items: []Match,
    num_bands: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Matches) void {
        for (self.items) |*m| {
            self.allocator.free(m.freq_band_means);
            self.allocator.free(m.freq_band_stddevs);
            self.allocator.free(m.freq_band_deg_energy);
        }
        self.allocator.free(self.items);
    }
};

/// Reference patch start frames.
pub fn refPatchIndices(
    allocator: std.mem.Allocator,
    num_frames: usize,
    patch_size: usize,
) ![]usize {
    const init_patch_index: usize = patch_size / 2;
    if (num_frames < patch_size + init_patch_index) {
        return Error.ReferenceSpectrogramTooSmall;
    }

    const max_index: usize = if (init_patch_index < num_frames - patch_size)
        num_frames - patch_size
    else
        init_patch_index + 1;

    var list: std.ArrayList(usize) = .empty;
    errdefer list.deinit(allocator);

    var i: usize = init_patch_index;
    while (i < max_index) : (i += patch_size) {
        try list.append(allocator, i - 1);
    }
    return list.toOwnedSlice(allocator);
}

/// Patch count after dropping tail patches past the degraded end.
pub fn calcMaxNumPatches(
    ref_patch_indices: []const usize,
    num_frames_deg: usize,
    num_frames_per_patch: usize,
) usize {
    var n = ref_patch_indices.len;
    if (n == 0) return 0;
    while (n > 0) {
        const last = ref_patch_indices[n - 1];
        if (last < num_frames_per_patch / 2) break;
        if (last - (num_frames_per_patch / 2) <= num_frames_deg) break;
        n -= 1;
    }
    return n;
}

/// Copy columns `[start, end)` into `out`, zero-padding past `num_frames`.
pub fn buildDegradedPatch(
    spec: []const f64,
    num_bands: usize,
    num_frames: usize,
    start: usize,
    end: usize,
    out: []f64,
) void {
    std.debug.assert(end > start);
    const patch_cols = end - start;
    std.debug.assert(out.len == num_bands * patch_cols);
    const real_end = @min(end, num_frames);
    const real_cols = if (real_end > start) real_end - start else 0;
    var b: usize = 0;
    while (b < num_bands) : (b += 1) {
        var c: usize = 0;
        while (c < real_cols) : (c += 1) {
            out[b * patch_cols + c] = spec[b * num_frames + start + c];
        }
        while (c < patch_cols) : (c += 1) {
            out[b * patch_cols + c] = 0.0;
        }
    }
}

pub fn buildRefPatch(
    spec: []const f64,
    num_bands: usize,
    num_frames: usize,
    start: usize,
    patch_size: usize,
    out: []f64,
) void {
    std.debug.assert(out.len == num_bands * patch_size);
    std.debug.assert(start + patch_size <= num_frames);
    var b: usize = 0;
    while (b < num_bands) : (b += 1) {
        var c: usize = 0;
        while (c < patch_size) : (c += 1) {
            out[b * patch_size + c] = spec[b * num_frames + start + c];
        }
    }
}

/// Per reference patch, the inclusive degraded-offset window `[lo, hi]`.
pub const SearchPlan = struct {
    num_patches: usize,
    lo: []usize,
    hi: []usize,
    /// `[num_patches][nf_deg]`, filled by `accel.patchSimilarities`.
    sims: []f64,
    nf_deg: usize,
    search_window: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SearchPlan) void {
        self.allocator.free(self.lo);
        self.allocator.free(self.hi);
        self.allocator.free(self.sims);
    }
};

/// How many patches `planSearch` keeps, by the same checks.
pub fn searchPatches(ref_patch_indices: []const usize, num_frames_ref: usize, num_frames_deg: usize, patch_size: usize) Error!usize {
    const num_patches = calcMaxNumPatches(ref_patch_indices, num_frames_deg, patch_size);
    if (num_patches == 0 or num_frames_deg == 0) return Error.SignalsTooDifferent;
    for (ref_patch_indices[0..num_patches]) |ri| {
        if (ri + patch_size > num_frames_ref) return Error.SignalsTooDifferent;
    }
    return num_patches;
}

/// A patch's inclusive degraded-offset window.
pub fn searchWindow(ref_index: usize, num_frames_deg: usize, patch_size: usize, search_window_radius: i32) struct { lo: usize, hi: usize } {
    const search_window: i64 = @as(i64, search_window_radius) * @as(i64, @intCast(patch_size));
    const last: i64 = @as(i64, @intCast(num_frames_deg)) - 1;
    const r: i64 = @intCast(ref_index);
    const lo: usize = @intCast(@max(0, r - search_window));
    return .{ .lo = lo, .hi = @intCast(@max(@as(i64, @intCast(lo)), @min(r + search_window, last))) };
}

pub fn planSearch(
    allocator: std.mem.Allocator,
    ref_patch_indices: []const usize,
    num_frames_ref: usize,
    num_frames_deg: usize,
    patch_size: usize,
    search_window_radius: i32,
) !SearchPlan {
    const num_patches = try searchPatches(ref_patch_indices, num_frames_ref, num_frames_deg, patch_size);
    const search_window: i64 = @as(i64, search_window_radius) * @as(i64, @intCast(patch_size));
    const lo = try allocator.alloc(usize, num_patches);
    errdefer allocator.free(lo);
    const hi = try allocator.alloc(usize, num_patches);
    errdefer allocator.free(hi);
    const sims = try allocator.alloc(f64, num_patches * num_frames_deg);
    @memset(sims, 0.0);
    for (ref_patch_indices[0..num_patches], lo, hi) |ri, *l, *h| {
        const w = searchWindow(ri, num_frames_deg, patch_size, search_window_radius);
        l.* = w.lo;
        h.* = w.hi;
    }
    return .{
        .num_patches = num_patches,
        .lo = lo,
        .hi = hi,
        .sims = sims,
        .nf_deg = num_frames_deg,
        .search_window = search_window,
        .allocator = allocator,
    };
}

/// DP over `plan.sims`, backtrack, then score each chosen patch with full
/// per-band NSIM. Matches upstream `FindMostOptimalDegPatches`.
pub fn findOptimalDegPatchesFromSims(
    allocator: std.mem.Allocator,
    plan: *const SearchPlan,
    ref_spec: []const f64,
    ref_patch_indices: []const usize,
    deg_spec: []const f64,
    num_bands: usize,
    num_frames_ref: usize,
    patch_size: usize,
    frame_duration: f64,
) !Matches {
    const num_patches = plan.num_patches;
    const num_frames_deg = plan.nf_deg;
    const dp_cols = num_frames_deg;
    const search_window = plan.search_window;
    const dp = try allocator.alloc(f64, num_patches * dp_cols);
    defer allocator.free(dp);
    const bt = try allocator.alloc(usize, num_patches * dp_cols);
    defer allocator.free(bt);
    @memset(dp, 0.0);
    @memset(bt, 0);

    for (0..num_patches) |pi| {
        const start_offset: usize = plan.lo[pi];
        const end_offset: usize = plan.hi[pi];

        var prev_row: usize = 0;
        var prev_lower: usize = 0;
        if (pi > 0) {
            prev_row = (pi - 1) * dp_cols;
            prev_lower = plan.lo[pi - 1];
        }

        // Running max over dp[pi-1][prev_lower..slide). `>=` because
        // upstream scans downwards with `>`: ties go to the highest offset.
        var running_max: f64 = -std.math.inf(f64);
        var running_max_idx: i64 = -1;
        if (pi > 0) {
            var i: usize = prev_lower;
            while (i < start_offset) : (i += 1) {
                const val = dp[prev_row + i];
                if (val >= running_max) {
                    running_max = val;
                    running_max_idx = @intCast(i);
                }
            }
        }

        var slide: usize = start_offset;
        while (slide <= end_offset) : (slide += 1) {
            var similarity = plan.sims[pi * dp_cols + slide];
            var past_slide: i64 = -1;
            if (pi > 0) {
                similarity += running_max;
                past_slide = running_max_idx;
                const no_move = dp[prev_row + slide];
                if (no_move > similarity) {
                    similarity = no_move;
                    past_slide = @intCast(slide);
                }
                if (no_move >= running_max) {
                    running_max = no_move;
                    running_max_idx = @intCast(slide);
                }
            }
            dp[pi * dp_cols + slide] = similarity;
            bt[pi * dp_cols + slide] = if (past_slide < 0) std.math.maxInt(usize) else @intCast(past_slide);
        }
    }

    const last_index = num_patches - 1;
    var max_score = -std.math.inf(f64);
    var last_offset: usize = 0;
    {
        var off = plan.lo[last_index];
        while (off <= plan.hi[last_index]) : (off += 1) {
            const v = dp[last_index * dp_cols + off];
            if (v > max_score) {
                max_score = v;
                last_offset = off;
            }
        }
    }
    _ = search_window;

    const items = try allocator.alloc(Match, num_patches);
    for (items) |*m| m.* = .{ .freq_band_means = &.{}, .freq_band_stddevs = &.{}, .freq_band_deg_energy = &.{} };
    var result: Matches = .{ .items = items, .num_bands = num_bands, .allocator = allocator };
    errdefer result.deinit();
    for (items) |*m| {
        m.freq_band_means = try allocator.alloc(f64, num_bands);
        m.freq_band_stddevs = try allocator.alloc(f64, num_bands);
        m.freq_band_deg_energy = try allocator.alloc(f64, num_bands);
        @memset(m.freq_band_means, 0.0);
        @memset(m.freq_band_stddevs, 0.0);
        @memset(m.freq_band_deg_energy, 0.0);
    }

    const patch_elems = num_bands * patch_size;
    var scratch = try nsim.Scratch.init(allocator, num_bands, patch_size);
    defer scratch.deinit();
    const ref_patch_buf = try allocator.alloc(f64, patch_elems);
    defer allocator.free(ref_patch_buf);
    const deg_patch_buf = try allocator.alloc(f64, patch_elems);
    defer allocator.free(deg_patch_buf);
    const cmp = nsim.Comparator.init(1.0);
    const patch_duration: f64 = frame_duration * @as(f64, @floatFromInt(patch_size));

    var p_idx: i64 = @intCast(num_patches - 1);
    var cur_offset = last_offset;
    while (p_idx >= 0) {
        const i: usize = @intCast(p_idx);
        const ref_idx = ref_patch_indices[i];

        buildDegradedPatch(deg_spec, num_bands, num_frames_deg, cur_offset, cur_offset + patch_size, deg_patch_buf);
        buildRefPatch(ref_spec, num_bands, num_frames_ref, ref_idx, patch_size, ref_patch_buf);
        scratch.invalidateRef();

        var ps = nsim.PatchSimilarity{
            .freq_band_means = items[i].freq_band_means,
            .freq_band_stddevs = items[i].freq_band_stddevs,
            .freq_band_deg_energy = items[i].freq_band_deg_energy,
            .mean_freq_band_means = 0.0,
            .allocator = allocator,
        };
        cmp.measurePatchSimilarity(&scratch, ref_patch_buf, deg_patch_buf, &ps);
        items[i].similarity = ps.mean_freq_band_means;

        // No real match: the backtrace points at itself.
        const back = bt[i * dp_cols + cur_offset];
        if (back == cur_offset) {
            items[i].deg_patch_start_time = 0.0;
            items[i].deg_patch_end_time = 0.0;
            items[i].similarity = 0.0;
            @memset(items[i].freq_band_means, 0.0);
            items[i].valid = false;
        } else {
            items[i].deg_patch_start_time = @as(f64, @floatFromInt(cur_offset)) * frame_duration;
            items[i].deg_patch_end_time = items[i].deg_patch_start_time + patch_duration;
            items[i].valid = true;
        }
        items[i].ref_patch_start_time = @as(f64, @floatFromInt(ref_idx)) * frame_duration;
        items[i].ref_patch_end_time = items[i].ref_patch_start_time + patch_duration;

        if (back == std.math.maxInt(usize)) break;
        cur_offset = back;
        p_idx -= 1;
    }

    return result;
}

/// Plan, CPU similarities and DP in one call.
pub fn findOptimalDegPatches(
    allocator: std.mem.Allocator,
    ref_spec: []const f64,
    ref_patch_indices: []const usize,
    deg_spec: []const f64,
    num_bands: usize,
    num_frames_ref: usize,
    num_frames_deg: usize,
    patch_size: usize,
    frame_duration: f64,
    search_window_radius: i32,
) !Matches {
    const accel = @import("accel.zig");
    var plan = try planSearch(allocator, ref_patch_indices, num_frames_ref, num_frames_deg, patch_size, search_window_radius);
    defer plan.deinit();
    var cpu: accel.Cpu = .{ .allocator = allocator };
    try cpu.accelerator().patchSimilarities(&.{.{
        .ref_spec = ref_spec,
        .nf_ref = num_frames_ref,
        .deg_spec = deg_spec,
        .nf_deg = num_frames_deg,
        .num_bands = num_bands,
        .patch_size = patch_size,
        .ref_indices = ref_patch_indices[0..plan.num_patches],
        .lo = plan.lo,
        .hi = plan.hi,
        .out = plan.sims,
    }});
    return findOptimalDegPatchesFromSims(allocator, &plan, ref_spec, ref_patch_indices, deg_spec, num_bands, num_frames_ref, patch_size, frame_duration);
}

test "refPatchIndices: sliding indices" {
    const allocator = std.testing.allocator;
    const idx = try refPatchIndices(allocator, 200, 30);
    defer allocator.free(idx);
    const expected = [_]usize{ 14, 44, 74, 104, 134, 164 };
    try std.testing.expectEqual(@as(usize, expected.len), idx.len);
    for (expected, idx) |e, a| try std.testing.expectEqual(e, a);
}

test "calcMaxNumPatches: drops tail patches that exceed deg" {
    const idx = [_]usize{ 0, 15, 30, 45, 60 };
    try std.testing.expectEqual(@as(usize, 5), calcMaxNumPatches(&idx, 45, 30));
    try std.testing.expectEqual(@as(usize, 4), calcMaxNumPatches(&idx, 44, 30));
}

test "DP: optimal patch start times" {
    // Ref patches 3..5 should match deg starts {0, 7, 8}.
    const allocator = std.testing.allocator;
    const ref_rows: [3][10]f64 = .{
        .{ 1.0, 1.0, 1.0, 2.0, 2.0, 2.0, 2.0, 2.0, 3.0, 3.0 },
        .{ 0.0, 1.0, 0.0, 2.0, 1.0, 1.0, 2.0, 3.0, 1.0, 2.0 },
        .{ 0.0, 1.0, 0.0, 2.0, 1.0, 1.0, 2.0, 3.0, 1.0, 2.0 },
    };
    var ref: [3 * 10]f64 = undefined;
    for (ref_rows, 0..) |row, b| {
        for (row, 0..) |v, c| ref[b * 10 + c] = v;
    }
    const deg_col_major = [_]f64{
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 1.0, 0.0, 0.0, 0.0, 0.0, 2.0, 2.0, 3.0, 2.0,
        0.0, 0.0, 0.0, 0.0, 3.0, 3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 1.0, 2.0, 3.0, 0.0, 0.0, 0.0, 0.0,
        1.0, 2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0,
        0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 1.0, 2.0, 3.0, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 0.0, 0.0,
    };
    var deg: [3 * 30]f64 = undefined;
    // Already row-major [3][30] despite the name.
    for (deg_col_major, 0..) |v, k| deg[k] = v;

    const patch_size: usize = 1;
    // Explicit indices: refPatchIndices underflows for patch_size 1.
    var patch_indices_buf = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const patch_indices = patch_indices_buf[0..];

    var matches = try findOptimalDegPatches(
        allocator,
        &ref,
        patch_indices,
        &deg,
        3, // num_bands
        10, // num_frames_ref
        30, // num_frames_deg
        patch_size,
        1.0, // frame_duration
        8, // search_window_radius
    );
    defer matches.deinit();

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), matches.items[3].deg_patch_start_time, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), matches.items[4].deg_patch_start_time, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), matches.items[5].deg_patch_start_time, 1e-9);
}
