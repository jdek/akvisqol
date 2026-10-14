// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Neurogram Similarity Index Measure (NSIM) on row-major [bands][frames] patches.
const std = @import("std");

/// Cells per SIMD chunk (two native vectors, for ILP). Every op is
/// lane-wise, so any width is bit-exact.
const VL = 2 * (std.simd.suggestVectorLength(f64) orelse 1);

/// Per-band similarity statistics for one patch pair.
pub const PatchSimilarity = struct {
    /// Mean of `intensity * structure` over time, per band.
    freq_band_means: []f64,
    /// Sample stddev (ddof=1) of the same; zero when `num_frames <= 1`.
    freq_band_stddevs: []f64,
    /// Mean of `deg_patch` over time, per band.
    freq_band_deg_energy: []f64,
    /// Mean of `freq_band_means`.
    mean_freq_band_means: f64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_bands: usize) !PatchSimilarity {
        const fbm = try allocator.alloc(f64, num_bands);
        errdefer allocator.free(fbm);
        const fbs = try allocator.alloc(f64, num_bands);
        errdefer allocator.free(fbs);
        const fbe = try allocator.alloc(f64, num_bands);
        return .{
            .freq_band_means = fbm,
            .freq_band_stddevs = fbs,
            .freq_band_deg_energy = fbe,
            .mean_freq_band_means = 0.0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PatchSimilarity) void {
        self.allocator.free(self.freq_band_means);
        self.allocator.free(self.freq_band_stddevs);
        self.allocator.free(self.freq_band_deg_energy);
    }
};

/// NSIM scratch for fixed patch dimensions.
pub const Scratch = struct {
    nrows: usize,
    ncols: usize,
    mu_ref: []f64,
    mu_deg: []f64,
    ref_sq: []f64,
    deg_sq: []f64,
    ref_deg: []f64,
    conv_ref_sq: []f64,
    conv_deg_sq: []f64,
    conv_rd: []f64,
    /// conv(ref²) - mu_ref², cached across calls sharing a ref patch.
    precomp_srs: []f64,
    /// mu_ref², cached alongside `precomp_srs`.
    precomp_rms: []f64,
    /// One-row buffers for `measureSimilarityAt`.
    row_crd: []f64,
    row_sim: []f64,
    /// `mu_ref`, `conv_ref_sq`, `precomp_srs`, `precomp_rms` hold the current ref patch.
    precomp_valid: bool,
    slab: []f64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, nrows: usize, ncols: usize) !Scratch {
        const n = nrows * ncols;
        const slab = try allocator.alloc(f64, 10 * n + 2 * ncols);
        var rest = slab;
        const take = struct {
            fn f(r: *[]f64, len: usize) []f64 {
                const out = r.*[0..len];
                r.* = r.*[len..];
                return out;
            }
        }.f;
        return .{
            .nrows = nrows,
            .ncols = ncols,
            .mu_ref = take(&rest, n),
            .mu_deg = take(&rest, n),
            .ref_sq = take(&rest, n),
            .deg_sq = take(&rest, n),
            .ref_deg = take(&rest, n),
            .conv_ref_sq = take(&rest, n),
            .conv_deg_sq = take(&rest, n),
            .conv_rd = take(&rest, n),
            .precomp_srs = take(&rest, n),
            .precomp_rms = take(&rest, n),
            .row_crd = take(&rest, ncols),
            .row_sim = take(&rest, ncols),
            .precomp_valid = false,
            .slab = slab,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scratch) void {
        self.allocator.free(self.slab);
    }

    pub fn invalidateRef(self: *Scratch) void {
        self.precomp_valid = false;
    }
};

/// 3x3 Gaussian NSIM window.
pub const WINDOW: [3][3]f64 = .{
    .{ 0.0113033910173052, 0.0838251475442633, 0.0113033910173052 },
    .{ 0.0838251475442633, 0.619485845753726, 0.0838251475442633 },
    .{ 0.0113033910173052, 0.0838251475442633, 0.0113033910173052 },
};

/// Flipped 3x3 kernel taps. `at` is the single definition of the tap
/// summation order, so every caller produces bit-identical cells.
const Taps = struct {
    w00: f64,
    w01: f64,
    w02: f64,
    w10: f64,
    w11: f64,
    w12: f64,
    w20: f64,
    w21: f64,
    w22: f64,

    fn init(filter: *const [3][3]f64) Taps {
        return .{
            .w00 = filter[2][2],
            .w01 = filter[2][1],
            .w02 = filter[2][0],
            .w10 = filter[1][2],
            .w11 = filter[1][1],
            .w12 = filter[1][0],
            .w20 = filter[0][2],
            .w21 = filter[0][1],
            .w22 = filter[0][0],
        };
    }

    /// Output cell from row offsets `rm/r0/rp` and column indices `cm/c/cp`.
    inline fn at(t: Taps, in: []const f64, rm: usize, r0: usize, rp: usize, cm: usize, c: usize, cp: usize) f64 {
        return t.w00 * in[rm + cm] +
            t.w01 * in[rm + c] +
            t.w02 * in[rm + cp] +
            t.w10 * in[r0 + cm] +
            t.w11 * in[r0 + c] +
            t.w12 * in[r0 + cp] +
            t.w20 * in[rp + cm] +
            t.w21 * in[rp + c] +
            t.w22 * in[rp + cp];
    }

    /// `at` for the `N` unclamped interior cells starting at column `c`.
    inline fn atN(t: Taps, comptime N: usize, in: []const f64, rm: usize, r0: usize, rp: usize, c: usize) @Vector(N, f64) {
        const V = @Vector(N, f64);
        const ld = struct {
            inline fn f(x: []const f64, i: usize) V {
                return x[i..][0..N].*;
            }
        }.f;
        const sp = struct {
            inline fn f(w: f64) V {
                return @splat(w);
            }
        }.f;
        return sp(t.w00) * ld(in, rm + c - 1) +
            sp(t.w01) * ld(in, rm + c) +
            sp(t.w02) * ld(in, rm + c + 1) +
            sp(t.w10) * ld(in, r0 + c - 1) +
            sp(t.w11) * ld(in, r0 + c) +
            sp(t.w12) * ld(in, r0 + c + 1) +
            sp(t.w20) * ld(in, rp + c - 1) +
            sp(t.w21) * ld(in, rp + c) +
            sp(t.w22) * ld(in, rp + c + 1);
    }

    /// One replicate-padded output row of width `ncols` into `out`.
    inline fn row(t: Taps, in: []const f64, rm: usize, r0: usize, rp: usize, ncols: usize, out: []f64) void {
        if (ncols == 1) {
            out[0] = t.at(in, rm, r0, rp, 0, 0, 0);
            return;
        }
        out[0] = t.at(in, rm, r0, rp, 0, 0, 1);
        var c: usize = 1;
        while (c + VL < ncols) : (c += VL) out[c..][0..VL].* = t.atN(VL, in, rm, r0, rp, c);
        while (c < ncols - 1) : (c += 1) out[c] = t.at(in, rm, r0, rp, c - 1, c, c + 1);
        out[ncols - 1] = t.at(in, rm, r0, rp, ncols - 2, ncols - 1, ncols - 1);
    }
};

inline fn rowAbove(r: usize) usize {
    return if (r == 0) 0 else r - 1;
}
inline fn rowBelow(r: usize, nrows: usize) usize {
    return if (r + 1 >= nrows) nrows - 1 else r + 1;
}

/// 3x3 true convolution (kernel flipped), replicate-padded, row-major.
/// `out` must not alias `input`.
pub fn conv2d3x3Replicate(
    filter: *const [3][3]f64,
    input: []const f64,
    out: []f64,
    nrows: usize,
    ncols: usize,
) void {
    std.debug.assert(input.len == nrows * ncols);
    std.debug.assert(out.len == nrows * ncols);
    const t = Taps.init(filter);
    for (0..nrows) |r| {
        const r0 = r * ncols;
        t.row(input, rowAbove(r) * ncols, r0, rowBelow(r, nrows) * ncols, ncols, out[r0..][0..ncols]);
    }
}

/// Deg-side NSIM terms over a whole degraded spectrogram, zero-padded to
/// `width` frames (as `dp.buildDegradedPatch` pads). A patch's interior
/// columns see the same 3x3 neighbourhood here as in the patch itself, so
/// sliding a patch along the plane only recomputes its two edge columns.
pub const DegPlane = struct {
    nrows: usize,
    width: usize,
    /// Padded spectrogram and its square.
    pad: []f64,
    sq: []f64,
    /// conv(pad), conv(pad)², conv(pad²) - conv(pad)².
    mu: []f64,
    dms: []f64,
    sds: []f64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, spec: []const f64, nrows: usize, nf: usize, width: usize) !DegPlane {
        std.debug.assert(spec.len == nrows * nf);
        std.debug.assert(width >= nf);
        const n = nrows * width;
        const slab = try allocator.alloc(f64, 5 * n);
        const p: DegPlane = .{
            .nrows = nrows,
            .width = width,
            .pad = slab[0..n],
            .sq = slab[n..][0..n],
            .mu = slab[2 * n ..][0..n],
            .dms = slab[3 * n ..][0..n],
            .sds = slab[4 * n ..][0..n],
            .allocator = allocator,
        };
        for (0..nrows) |r| {
            @memcpy(p.pad[r * width ..][0..nf], spec[r * nf ..][0..nf]);
            @memset(p.pad[r * width + nf ..][0 .. width - nf], 0.0);
        }
        for (p.sq, p.pad) |*o, d| o.* = d * d;
        conv2d3x3Replicate(&WINDOW, p.pad, p.mu, nrows, width);
        conv2d3x3Replicate(&WINDOW, p.sq, p.sds, nrows, width);
        for (p.dms, p.sds, p.mu) |*dms, *sds, md| {
            dms.* = md * md;
            sds.* = sds.* - dms.*;
        }
        return p;
    }

    pub fn deinit(self: *DegPlane) void {
        self.allocator.free(self.pad.ptr[0 .. 5 * self.pad.len]);
    }
};

/// One patch row's NSIM inputs for `measureSimilarityAt`.
const SimRow = struct {
    mr: []const f64,
    rms: []const f64,
    srs: []const f64,
    md: []const f64,
    dms: []const f64,
    sds: []const f64,
    crd: []const f64,
    c1: f64,
    c3: f64,

    /// Cells `c..c+N`; per lane identical to `measureSimilarityScalar`'s cell.
    inline fn cells(row: SimRow, comptime N: usize, c: usize) @Vector(N, f64) {
        return simCell(@Vector(N, f64), row.mr[c..][0..N].*, row.rms[c..][0..N].*, row.srs[c..][0..N].*, row.md[c..][0..N].*, row.dms[c..][0..N].*, row.sds[c..][0..N].*, row.crd[c..][0..N].*, row.c1, row.c3);
    }

    /// Cell `c` with overridden deg-side terms.
    inline fn cell(row: SimRow, c: usize, md: f64, dms: f64, sds: f64) f64 {
        return simCell(f64, row.mr[c], row.rms[c], row.srs[c], md, dms, sds, row.crd[c], row.c1, row.c3);
    }
};

inline fn simCell(comptime T: type, mr: T, rms: T, srs: T, md: T, dms: T, sds: T, crd: T, c1s: f64, c3s: f64) T {
    const c1: T = if (T == f64) c1s else @splat(c1s);
    const c3: T = if (T == f64) c3s else @splat(c3s);
    const two: T = if (T == f64) 2.0 else @splat(2.0);
    const zero: T = if (T == f64) 0.0 else @splat(0.0);
    const mrd = mr * md;
    const srd = crd - mrd;
    const intensity = (two * mrd + c1) / (rms + dms + c1);
    const prod = srs * sds;
    const structure_denom = if (T == f64)
        (if (prod < 0.0) c3 else @sqrt(prod) + c3)
    else
        @select(f64, prod < zero, c3, @sqrt(prod) + c3);
    const structure = (srd + c3) / structure_denom;
    return intensity * structure;
}

pub const Comparator = struct {
    intensity_range: f64 = 1.0,

    pub fn init(intensity_range: f64) Comparator {
        return .{ .intensity_range = intensity_range };
    }

    /// Cache ref-side intermediates in `s`.
    pub fn precomputeRef(self: Comparator, s: *Scratch, ref_patch: []const f64) void {
        _ = self;
        std.debug.assert(ref_patch.len == s.nrows * s.ncols);
        conv2d3x3Replicate(&WINDOW, ref_patch, s.mu_ref, s.nrows, s.ncols);
        for (s.ref_sq, ref_patch) |*o, r| o.* = r * r;
        conv2d3x3Replicate(&WINDOW, s.ref_sq, s.conv_ref_sq, s.nrows, s.ncols);
        for (s.precomp_srs, s.precomp_rms, s.conv_ref_sq, s.mu_ref) |*srs, *rms, crsq, mr| {
            rms.* = mr * mr;
            srs.* = crsq - rms.*;
        }
        s.precomp_valid = true;
    }

    /// Mean of `intensity * structure`; uses the ref cache if valid.
    pub fn measureSimilarityScalar(
        self: Comparator,
        s: *Scratch,
        ref_patch: []const f64,
        deg_patch: []const f64,
    ) f64 {
        std.debug.assert(ref_patch.len == s.nrows * s.ncols);
        std.debug.assert(deg_patch.len == s.nrows * s.ncols);
        const c1 = (0.01 * self.intensity_range) * (0.01 * self.intensity_range);
        const c3 = (0.03 * self.intensity_range) * (0.03 * self.intensity_range) / 2.0;

        if (!s.precomp_valid) {
            self.precomputeRef(s, ref_patch);
        }

        conv2d3x3Replicate(&WINDOW, deg_patch, s.mu_deg, s.nrows, s.ncols);
        for (s.deg_sq, deg_patch) |*o, d| o.* = d * d;
        for (s.ref_deg, ref_patch, deg_patch) |*o, r, d| o.* = r * d;
        conv2d3x3Replicate(&WINDOW, s.deg_sq, s.conv_deg_sq, s.nrows, s.ncols);
        conv2d3x3Replicate(&WINDOW, s.ref_deg, s.conv_rd, s.nrows, s.ncols);

        const n_f: f64 = @floatFromInt(s.nrows * s.ncols);
        var sum: f64 = 0.0;
        for (s.mu_ref, s.mu_deg, s.precomp_srs, s.conv_deg_sq, s.conv_rd) |mr, md, srs, cdsq, crd| {
            const dms = md * md;
            sum += simCell(f64, mr, mr * mr, srs, md, dms, cdsq - dms, crd, c1, c3);
        }
        return sum / n_f;
    }

    /// `measureSimilarityScalar(ref_patch, <plane frames off..off+ncols>)`,
    /// bit-identical, reusing the plane's deg-side terms. Needs `precomputeRef`.
    pub fn measureSimilarityAt(
        self: Comparator,
        s: *Scratch,
        ref_patch: []const f64,
        plane: *const DegPlane,
        off: usize,
    ) f64 {
        const nr = s.nrows;
        const nc = s.ncols;
        const w = plane.width;
        std.debug.assert(ref_patch.len == nr * nc);
        std.debug.assert(plane.nrows == nr);
        std.debug.assert(off + nc <= w);
        std.debug.assert(s.precomp_valid);
        const c1 = (0.01 * self.intensity_range) * (0.01 * self.intensity_range);
        const c3 = (0.03 * self.intensity_range) * (0.03 * self.intensity_range) / 2.0;
        const t = Taps.init(&WINDOW);

        for (0..nr) |r| {
            const deg = plane.pad[r * w + off ..][0..nc];
            for (s.ref_deg[r * nc ..][0..nc], ref_patch[r * nc ..][0..nc], deg) |*o, rv, d| o.* = rv * d;
        }

        var sum: f64 = 0.0;
        for (0..nr) |r| {
            const rm = rowAbove(r);
            const rp = rowBelow(r, nr);
            t.row(s.ref_deg, rm * nc, r * nc, rp * nc, nc, s.row_crd);

            const pr = r * w + off;
            const ri = r * nc;
            const row: SimRow = .{
                .mr = s.mu_ref[ri..][0..nc],
                .rms = s.precomp_rms[ri..][0..nc],
                .srs = s.precomp_srs[ri..][0..nc],
                .md = plane.mu[pr..][0..nc],
                .dms = plane.dms[pr..][0..nc],
                .sds = plane.sds[pr..][0..nc],
                .crd = s.row_crd,
                .c1 = c1,
                .c3 = c3,
            };
            // Interior cells read the plane as-is; the edges are re-clamped
            // to the patch, whose replicate padding differs from the plane's.
            const edges = [2]usize{ 0, nc - 1 };
            for (edges[0..@min(nc, 2)]) |c| {
                const cm = off + (if (c == 0) 0 else c - 1);
                const cp = off + (if (c + 1 >= nc) nc - 1 else c + 1);
                const md = t.at(plane.pad, rm * w, r * w, rp * w, cm, off + c, cp);
                const cdsq = t.at(plane.sq, rm * w, r * w, rp * w, cm, off + c, cp);
                const dms = md * md;
                s.row_sim[c] = row.cell(c, md, dms, cdsq - dms);
            }
            var c: usize = 1;
            while (c + VL < nc) : (c += VL) s.row_sim[c..][0..VL].* = row.cells(VL, c);
            while (c + 1 < nc) : (c += 1) s.row_sim[c] = row.cells(1, c)[0];
            // Serial, row-major: same summation order as the scalar path.
            for (s.row_sim) |v| sum += v;
        }
        return sum / @as(f64, @floatFromInt(nr * nc));
    }

    /// NSIM with per-band statistics. Clobbers the ref cache.
    pub fn measurePatchSimilarity(
        self: Comparator,
        s: *Scratch,
        ref_patch: []const f64,
        deg_patch: []const f64,
        out: *PatchSimilarity,
    ) void {
        std.debug.assert(ref_patch.len == s.nrows * s.ncols);
        std.debug.assert(deg_patch.len == s.nrows * s.ncols);
        std.debug.assert(out.freq_band_means.len == s.nrows);

        const c1 = (0.01 * self.intensity_range) * (0.01 * self.intensity_range);
        const c3 = (0.03 * self.intensity_range) * (0.03 * self.intensity_range) / 2.0;

        conv2d3x3Replicate(&WINDOW, ref_patch, s.mu_ref, s.nrows, s.ncols);
        conv2d3x3Replicate(&WINDOW, deg_patch, s.mu_deg, s.nrows, s.ncols);
        for (s.ref_sq, ref_patch) |*o, r| o.* = r * r;
        for (s.deg_sq, deg_patch) |*o, d| o.* = d * d;
        for (s.ref_deg, ref_patch, deg_patch) |*o, r, d| o.* = r * d;
        conv2d3x3Replicate(&WINDOW, s.ref_sq, s.conv_ref_sq, s.nrows, s.ncols);
        conv2d3x3Replicate(&WINDOW, s.deg_sq, s.conv_deg_sq, s.nrows, s.ncols);
        conv2d3x3Replicate(&WINDOW, s.ref_deg, s.conv_rd, s.nrows, s.ncols);

        const inv_ncols: f64 = 1.0 / @as(f64, @floatFromInt(s.ncols));

        var r: usize = 0;
        while (r < s.nrows) : (r += 1) {
            var deg_sum: f64 = 0.0;
            var c: usize = 0;
            while (c < s.ncols) : (c += 1) {
                deg_sum += deg_patch[r * s.ncols + c];
            }
            out.freq_band_deg_energy[r] = deg_sum * inv_ncols;
        }

        // sim_map is stored into conv_rd for the stddev pass.
        r = 0;
        while (r < s.nrows) : (r += 1) {
            var sim_sum: f64 = 0.0;
            var c: usize = 0;
            while (c < s.ncols) : (c += 1) {
                const idx = r * s.ncols + c;
                const mr = s.mu_ref[idx];
                const md = s.mu_deg[idx];
                const rms = mr * mr;
                const dms = md * md;
                const mrd = mr * md;
                const srs = s.conv_ref_sq[idx] - rms;
                const sds = s.conv_deg_sq[idx] - dms;
                const srd = s.conv_rd[idx] - mrd;
                const intensity = (2.0 * mrd + c1) / (rms + dms + c1);
                const prod = srs * sds;
                const structure_denom = if (prod < 0.0) c3 else @sqrt(prod) + c3;
                const structure = (srd + c3) / structure_denom;
                const sim = intensity * structure;
                sim_sum += sim;
                s.conv_rd[idx] = sim;
            }
            out.freq_band_means[r] = sim_sum * inv_ncols;
        }

        r = 0;
        while (r < s.nrows) : (r += 1) {
            if (s.ncols <= 1) {
                out.freq_band_stddevs[r] = 0.0;
                continue;
            }
            const mean = out.freq_band_means[r];
            var ss: f64 = 0.0;
            var c: usize = 0;
            while (c < s.ncols) : (c += 1) {
                const diff = s.conv_rd[r * s.ncols + c] - mean;
                ss += diff * diff;
            }
            out.freq_band_stddevs[r] = @sqrt(ss / (@as(f64, @floatFromInt(s.ncols)) - 1.0));
        }

        var mean_acc: f64 = 0.0;
        for (out.freq_band_means) |m| mean_acc += m;
        out.mean_freq_band_means = mean_acc / @as(f64, @floatFromInt(s.nrows));

        // precomp_srs was not updated for this ref.
        s.precomp_valid = false;
    }
};

test "conv2d3x3Replicate: reference output" {
    // Input and expected are column-major [4][5]; repacked to row-major 5x4.
    const cols: [4][5]f64 = .{
        .{ 40.0392, 43.3409, 39.5270, 41.1731, 41.3591 },
        .{ 42.6852, 45.2083, 45.7769, 39.9689, 43.6190 },
        .{ 41.0119, 40.4244, 41.5932, 43.6027, 42.6204 },
        .{ 43.0624, 42.2610, 42.4725, 43.4258, 42.9079 },
    };
    var input: [5 * 4]f64 = undefined;
    {
        var r: usize = 0;
        while (r < 5) : (r += 1) {
            var c: usize = 0;
            while (c < 4) : (c += 1) {
                input[r * 4 + c] = cols[c][r];
            }
        }
    }

    var out: [5 * 4]f64 = undefined;
    conv2d3x3Replicate(&WINDOW, &input, &out, 5, 4);

    const exp_cols: [4][5]f64 = .{
        .{ 40.6634, 42.8407, 40.6395, 41.0129, 41.5407 },
        .{ 42.4677, 44.2760, 44.2031, 41.2263, 42.9752 },
        .{ 41.3784, 41.2656, 42.1388, 43.0366, 42.8042 },
        .{ 42.7613, 42.1817, 42.4590, 43.2709, 42.9377 },
    };
    var r: usize = 0;
    while (r < 5) : (r += 1) {
        var c: usize = 0;
        while (c < 4) : (c += 1) {
            try std.testing.expectApproxEqAbs(exp_cols[c][r], out[r * 4 + c], 1e-3);
        }
    }
}

test "Comparator.measurePatchSimilarity: reference test_neurogram_measure" {
    // 3x1 patches.
    const allocator = std.testing.allocator;
    const ref = [_]f64{ 1.0, 0.0, 0.0 };
    const deg = [_]f64{ 0.0, 0.0, 0.0 };

    var s = try Scratch.init(allocator, 3, 1);
    defer s.deinit();

    var out = try PatchSimilarity.init(allocator, 3);
    defer out.deinit();

    const cmp = Comparator.init(1.0);
    cmp.measurePatchSimilarity(&s, &ref, &deg, &out);

    try std.testing.expectApproxEqAbs(@as(f64, 0.000125225), out.freq_band_means[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00875062), out.freq_band_means[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), out.freq_band_means[2], 1e-4);
}

test "Comparator.measureSimilarityScalar: identical patches → 1.0" {
    const allocator = std.testing.allocator;
    var s = try Scratch.init(allocator, 4, 5);
    defer s.deinit();
    var sig: [20]f64 = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) sig[i] = @sin(@as(f64, @floatFromInt(i)) * 0.3) + 1.5;

    const cmp = Comparator.init(1.0);
    const score = cmp.measureSimilarityScalar(&s, &sig, &sig);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), score, 1e-9);
}

test "Comparator: precomputeRef + scalar matches no-precompute path" {
    const allocator = std.testing.allocator;
    var s1 = try Scratch.init(allocator, 4, 5);
    defer s1.deinit();
    var s2 = try Scratch.init(allocator, 4, 5);
    defer s2.deinit();

    var ref: [20]f64 = undefined;
    var deg: [20]f64 = undefined;
    var rng = std.Random.DefaultPrng.init(0xfeedface);
    const r = rng.random();
    for (&ref, &deg) |*x, *y| {
        x.* = r.float(f64);
        y.* = r.float(f64);
    }

    const cmp = Comparator.init(1.0);
    const a = cmp.measureSimilarityScalar(&s1, &ref, &deg);
    cmp.precomputeRef(&s2, &ref);
    const b = cmp.measureSimilarityScalar(&s2, &ref, &deg);
    try std.testing.expectApproxEqAbs(a, b, 1e-12);
}

test "Comparator.measureSimilarityAt matches measureSimilarityScalar bit-for-bit" {
    const allocator = std.testing.allocator;
    const nr = 6;
    const nc = 5;
    const nf = 17;
    var rng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = rng.random();
    var spec: [nr * nf]f64 = undefined;
    for (&spec) |*x| x.* = rnd.float(f64) * 40.0;
    var ref: [nr * nc]f64 = undefined;
    for (&ref) |*x| x.* = rnd.float(f64) * 40.0;

    const width = nf + nc;
    var plane = try DegPlane.init(allocator, &spec, nr, nf, width);
    defer plane.deinit();
    var s1 = try Scratch.init(allocator, nr, nc);
    defer s1.deinit();
    var s2 = try Scratch.init(allocator, nr, nc);
    defer s2.deinit();
    const cmp = Comparator.init(1.0);
    cmp.precomputeRef(&s1, &ref);
    cmp.precomputeRef(&s2, &ref);

    var deg: [nr * nc]f64 = undefined;
    for (0..width - nc + 1) |off| {
        for (0..nr) |r| for (0..nc) |c| {
            deg[r * nc + c] = if (off + c < nf) spec[r * nf + off + c] else 0.0;
        };
        const want = cmp.measureSimilarityScalar(&s1, &ref, &deg);
        const got = cmp.measureSimilarityAt(&s2, &ref, &plane, off);
        try std.testing.expectEqual(want, got);
    }
}
