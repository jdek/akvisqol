// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! FFT cross-correlation lag search: argmax of `|xcorr(s1, s2)|` over
//! lags in `[-(max(L1, L2) - 1), max(L1, L2) - 1]`.
const std = @import("std");
const fft = @import("dsp/fft.zig");

pub const C = std.math.Complex(f64);

/// FFT plan and scratch for a fixed power-of-two `fft_size`.
pub const Plan = struct {
    fft_plan: fft.Plan(f64),
    pad_a: []f64,
    pad_b: []f64,
    spec_a: []C,
    spec_b: []C,
    time_out: []f64,
    scratch: []C,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, fft_size: usize) !Plan {
        var p = try fft.Plan(f64).init(allocator, fft_size);
        errdefer p.deinit();
        const pad_a = try allocator.alloc(f64, fft_size);
        errdefer allocator.free(pad_a);
        const pad_b = try allocator.alloc(f64, fft_size);
        errdefer allocator.free(pad_b);
        const spec_a = try allocator.alloc(C, fft_size / 2 + 1);
        errdefer allocator.free(spec_a);
        const spec_b = try allocator.alloc(C, fft_size / 2 + 1);
        errdefer allocator.free(spec_b);
        const time_out = try allocator.alloc(f64, fft_size);
        errdefer allocator.free(time_out);
        const scratch = try allocator.alloc(C, fft_size);
        return .{
            .fft_plan = p,
            .pad_a = pad_a,
            .pad_b = pad_b,
            .spec_a = spec_a,
            .spec_b = spec_b,
            .time_out = time_out,
            .scratch = scratch,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Plan) void {
        self.fft_plan.deinit();
        self.allocator.free(self.pad_a);
        self.allocator.free(self.pad_b);
        self.allocator.free(self.spec_a);
        self.allocator.free(self.spec_b);
        self.allocator.free(self.time_out);
        self.allocator.free(self.scratch);
    }

    pub fn size(self: Plan) usize {
        return self.fft_plan.n;
    }
};

/// Smallest power of two >= `2 * biggest - 1`.
pub fn fftSizeFor(biggest: usize) usize {
    const needed = if (biggest == 0) 1 else 2 * biggest - 1;
    var n: usize = 1;
    while (n < needed) n <<= 1;
    return @max(n, 1);
}

/// Circular cross-correlation into `plan.time_out` (length `plan.size()`);
/// returns a view of it.
pub fn xcorrCircular(
    plan: *Plan,
    s1: []const f64,
    s2: []const f64,
) []const f64 {
    const n = plan.size();
    std.debug.assert(s1.len <= n);
    std.debug.assert(s2.len <= n);
    const biggest = @max(s1.len, s2.len);

    @memcpy(plan.pad_a[0..s1.len], s1);
    @memset(plan.pad_a[s1.len..biggest], 0);
    @memset(plan.pad_a[biggest..n], 0);
    @memcpy(plan.pad_b[0..s2.len], s2);
    @memset(plan.pad_b[s2.len..biggest], 0);
    @memset(plan.pad_b[biggest..n], 0);

    plan.fft_plan.rfft(plan.pad_a, plan.spec_a, plan.scratch);
    plan.fft_plan.rfft(plan.pad_b, plan.spec_b, plan.scratch);

    for (plan.spec_a, plan.spec_b) |*a, b| {
        const ar = a.re;
        const ai = a.im;
        const br = b.re;
        const bi = b.im;
        a.re = ar * br + ai * bi;
        a.im = ai * br - ar * bi;
    }

    plan.fft_plan.irfft(plan.spec_a, plan.time_out, plan.scratch);
    return plan.time_out[0..n];
}

/// Positive lag means `s2` is delayed relative to `s1`.
pub fn bestLagWithPlan(plan: *Plan, s1: []const f64, s2: []const f64) i64 {
    const biggest = @max(s1.len, s2.len);
    if (biggest == 0) return 0;
    const corr = xcorrCircular(plan, s1, s2);
    const n = corr.len;
    const max_lag: i64 = @intCast(biggest - 1);

    var best_abs: f64 = -std.math.inf(f64);
    var best_lag: i64 = 0;

    // Negative lags: corr[n - max_lag .. n] map to -max_lag .. -1.
    const neg_start = n - @as(usize, @intCast(max_lag));
    var i: usize = neg_start;
    while (i < n) : (i += 1) {
        const a = @abs(corr[i]);
        if (a > best_abs) {
            best_abs = a;
            best_lag = @as(i64, @intCast(i)) - @as(i64, @intCast(n));
        }
    }
    var k: usize = 0;
    while (k <= @as(usize, @intCast(max_lag))) : (k += 1) {
        const a = @abs(corr[k]);
        if (a > best_abs) {
            best_abs = a;
            best_lag = @as(i64, @intCast(k));
        }
    }
    return best_lag;
}

/// FFT plans keyed by size. Few distinct sizes occur, and a 2^21-point
/// plan's twiddles cost more than the transform.
pub const Cache = struct {
    const Entry = struct { plan: fft.Plan(f64), work: []C };
    entries: [4]?Entry = @splat(null),
    next_evict: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        for (&self.entries) |*e| if (e.*) |*x| {
            x.plan.deinit();
            self.allocator.free(x.work);
            e.* = null;
        };
    }

    fn get(self: *Cache, n: usize) !*Entry {
        for (&self.entries) |*e| if (e.*) |*x| {
            if (x.plan.n == n) return x;
        };
        const slot = for (&self.entries) |*e| {
            if (e.* == null) break e;
        } else blk: {
            const e = &self.entries[self.next_evict];
            self.next_evict = (self.next_evict + 1) % self.entries.len;
            e.*.?.plan.deinit();
            self.allocator.free(e.*.?.work);
            e.* = null;
            break :blk e;
        };
        var plan = try fft.Plan(f64).init(self.allocator, n);
        errdefer plan.deinit();
        const work = try self.allocator.alloc(C, n);
        slot.* = .{ .plan = plan, .work = work };
        return &slot.*.?;
    }
};

/// X = Z[k], Y = conj(Z[-k]); A = (X+Y)/2, B = (X-Y)/(2i);
/// A·conj(B) = (X+Y) · i·conj(X-Y) / 4.
inline fn crossTerm(x: C, zy: C) C {
    const y: C = .{ .re = zy.re, .im = -zy.im };
    const sum: C = .{ .re = x.re + y.re, .im = x.im + y.im };
    const dif_c: C = .{ .re = x.re - y.re, .im = -(x.im - y.im) };
    // i · conj(X-Y)
    const idc: C = .{ .re = -dif_c.im, .im = dif_c.re };
    return .{
        .re = 0.25 * (sum.re * idc.re - sum.im * idc.im),
        .im = 0.25 * (sum.re * idc.im + sum.im * idc.re),
    };
}

/// Two-FFT `bestLagWithPlan`: packs z = s1 + i·s2 into one complex
/// transform and forms the cross-spectrum in DIF bit-reversed order, so no
/// permutation passes. Unscaled (argmax is scale-invariant).
pub fn bestLagCached(cache: *Cache, s1: []const f64, s2: []const f64) !i64 {
    const biggest = @max(s1.len, s2.len);
    if (biggest == 0) return 0;
    const n = fftSizeFor(biggest);
    const e = try cache.get(n);
    const z = e.work;

    const m = @min(s1.len, s2.len);
    for (z[0..m], s1[0..m], s2[0..m]) |*c, x, y| c.* = .{ .re = x, .im = y };
    for (z[m..s1.len], s1[m..]) |*c, x| c.* = .{ .re = x, .im = 0.0 };
    for (z[m..s2.len], s2[m..]) |*c, y| c.* = .{ .re = 0.0, .im = y };
    @memset(z[biggest..], .{ .re = 0.0, .im = 0.0 });
    e.plan.difForward(z);

    // Z[-k] sits at a mirror position in bit-reversed order: positions 0
    // and 1 (k = 0, n/2) are their own partners, and in each block [h, 2h)
    // position i pairs with 3h-1-i. Each pair is updated in place.
    z[0] = crossTerm(z[0], z[0]);
    if (n > 1) z[1] = crossTerm(z[1], z[1]);
    var h: usize = 2;
    while (h < n) : (h <<= 1) {
        var a = h;
        var b = 2 * h - 1;
        while (a < b) : ({
            a += 1;
            b -= 1;
        }) {
            const za = z[a];
            const zb = z[b];
            z[a] = crossTerm(za, zb);
            z[b] = crossTerm(zb, za);
        }
    }
    e.plan.ditInverse(z);
    const p = z;

    const max_lag: usize = biggest - 1;
    var best_abs: f64 = -std.math.inf(f64);
    var best_lag: i64 = 0;
    for (n - max_lag..n) |i| {
        const a = @abs(p[i].re);
        if (a > best_abs) {
            best_abs = a;
            best_lag = @as(i64, @intCast(i)) - @as(i64, @intCast(n));
        }
    }
    for (0..max_lag + 1) |k| {
        const a = @abs(p[k].re);
        if (a > best_abs) {
            best_abs = a;
            best_lag = @intCast(k);
        }
    }
    return best_lag;
}

/// Allocates a one-off Plan; prefer `bestLagCached` in loops.
pub fn bestLag(allocator: std.mem.Allocator, s1: []const f64, s2: []const f64) !i64 {
    var cache = Cache.init(allocator);
    defer cache.deinit();
    return bestLagCached(&cache, s1, s2);
}

/// Three-FFT reference for testing the fast path.
pub fn bestLagReference(allocator: std.mem.Allocator, s1: []const f64, s2: []const f64) !i64 {
    const biggest = @max(s1.len, s2.len);
    if (biggest == 0) return 0;
    var plan = try Plan.init(allocator, fftSizeFor(biggest));
    defer plan.deinit();
    return bestLagWithPlan(&plan, s1, s2);
}

/// Upper bound on lags `refineLag` rescores before giving up.
pub const MAX_REFINE_CANDIDATES = 64;

/// `bestLagCached` from an approximate (e.g. f32 GPU) correlation.
/// `approx[i * stride]` holds `scale`·Σ_t s1[t + i]·s2[t] (circular index
/// `i`, `n` points) with absolute error <= `tol · (‖s1‖² + ‖s2‖²) · scale`.
/// Candidate lags within that bound are rescored in f64 in
/// `bestLagCached`'s scan order, so the result matches the f64 path.
/// Null when more than `MAX_REFINE_CANDIDATES` qualify.
pub fn refineLag(s1: []const f64, s2: []const f64, approx: []const f32, stride: usize, n: usize, scale: f64, tol: f64) ?i64 {
    const biggest = @max(s1.len, s2.len);
    if (biggest == 0) return 0;
    std.debug.assert(n >= 2 * biggest - 1);
    const max_lag = biggest - 1;
    const slack = refineSlack(s1, s2, scale, tol);

    var top: f32 = 0;
    for (n - max_lag..n) |i| top = @max(top, @abs(approx[i * stride]));
    for (0..max_lag + 1) |i| top = @max(top, @abs(approx[i * stride]));
    const floor = top - slack;

    var cands: [MAX_REFINE_CANDIDATES]i64 = undefined;
    var nc: usize = 0;
    for (n - max_lag..n) |i| if (@abs(approx[i * stride]) >= floor) {
        if (nc == cands.len) return null;
        cands[nc] = @as(i64, @intCast(i)) - @as(i64, @intCast(n));
        nc += 1;
    };
    for (0..max_lag + 1) |i| if (@abs(approx[i * stride]) >= floor) {
        if (nc == cands.len) return null;
        cands[nc] = @intCast(i);
        nc += 1;
    };
    return rescore(s1, s2, cands[0..nc]);
}

pub fn refineSlack(s1: []const f64, s2: []const f64, scale: f64, tol: f64) f32 {
    var e1: f64 = 0;
    var e2: f64 = 0;
    for (s1) |x| e1 += x * x;
    for (s2) |x| e2 += x * x;
    return @floatCast(2.0 * tol * (e1 + e2) * scale);
}

/// First on ties, so `cands` must ascend (`bestLagCached`'s order).
pub fn rescore(s1: []const f64, s2: []const f64, cands: []const i64) i64 {
    var best_abs: f64 = -std.math.inf(f64);
    var best_lag: i64 = 0;
    for (cands) |lag| {
        const a = @abs(dotAtLag(s1, s2, lag));
        if (a > best_abs) {
            best_abs = a;
            best_lag = lag;
        }
    }
    return best_lag;
}

/// Σ_t s1[t + lag]·s2[t] over the overlap.
fn dotAtLag(s1: []const f64, s2: []const f64, lag: i64) f64 {
    const off: usize = @intCast(@abs(lag));
    const a = if (lag >= 0) s1[@min(off, s1.len)..] else s1;
    const b = if (lag >= 0) s2 else s2[@min(off, s2.len)..];
    const len = @min(a.len, b.len);
    const V = @Vector(4, f64);
    var acc: V = @splat(0);
    var t: usize = 0;
    while (t + 4 <= len) : (t += 4) acc += @as(V, a[t..][0..4].*) * @as(V, b[t..][0..4].*);
    var sum = @reduce(.Add, acc);
    while (t < len) : (t += 1) sum += a[t] * b[t];
    return sum;
}

test "fftSizeFor: next power of two of 2*biggest - 1" {
    try std.testing.expectEqual(@as(usize, 32), fftSizeFor(14));
    try std.testing.expectEqual(@as(usize, 32), fftSizeFor(15));
    try std.testing.expectEqual(@as(usize, 32), fftSizeFor(16));
    try std.testing.expectEqual(@as(usize, 64), fftSizeFor(17));
}

test "bestLag: equal-length signals, positive lag of 2" {
    const ref = [_]f64{ 2.0, 2.0, 1.0, 0.1, -3.0, 0.1, 1.0, 2.0, 2.0, 6.0, 8.0, 6.0, 2.0, 2.0 };
    const deg = [_]f64{ 1.2, 0.1, -3.3, 0.1, 1.1, 2.2, 2.1, 7.1, 8.3, 6.8, 2.4, 2.2, 2.2, 2.1 };
    const lag = try bestLag(std.testing.allocator, &ref, &deg);
    try std.testing.expectEqual(@as(i64, 2), lag);
}

test "bestLag: reference shorter than degraded → still 2" {
    const ref = [_]f64{ 2.0, 2.0, 1.0, 0.1, -3.0, 0.1, 1.0, 2.0, 2.0, 6.0, 8.0, 6.0, 2.0, 2.0 };
    const deg = [_]f64{ 1.2, 0.1, -3.3, 0.1, 1.1, 2.2, 2.1, 7.1, 8.3, 6.8, 2.4, 2.2, 2.2, 2.1, 2.0 };
    const lag = try bestLag(std.testing.allocator, &ref, &deg);
    try std.testing.expectEqual(@as(i64, 2), lag);
}

test "bestLag: reference longer than degraded → still 2" {
    const ref = [_]f64{ 2.0, 2.0, 1.0, 0.1, -3.0, 0.1, 1.0, 2.0, 2.0, 6.0, 8.0, 6.0, 2.0, 2.0 };
    const deg = [_]f64{ 1.2, 0.1, -3.3, 0.1, 1.1, 2.2, 2.1, 7.1, 8.3, 6.8, 2.4, 2.2, 2.2 };
    const lag = try bestLag(std.testing.allocator, &ref, &deg);
    try std.testing.expectEqual(@as(i64, 2), lag);
}

test "bestLag: negative lag of -2" {
    const ref = [_]f64{ 2.0, 2.0, 1.0, 0.1, -3.0, 0.1, 1.0, 2.0, 2.0, 6.0, 8.0, 6.0, 2.0, 2.0 };
    const deg = [_]f64{ 2.0, 2.0, 2.0, 2.0, 1.0, 0.1, -3.0, 0.1, 1.0, 2.0, 2.0, 6.0, 8.0, 6.0 };
    const lag = try bestLag(std.testing.allocator, &ref, &deg);
    try std.testing.expectEqual(@as(i64, -2), lag);
}

test "bestLag: identical signals → lag 0" {
    const sig = [_]f64{ 0.5, -0.3, 0.8, 0.1, -0.2, 0.9, 0.0, -0.5 };
    const lag = try bestLag(std.testing.allocator, &sig, &sig);
    try std.testing.expectEqual(@as(i64, 0), lag);
}

test "bestLagCached matches the three-FFT reference on random signals" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    var cache = Cache.init(allocator);
    defer cache.deinit();
    for (0..20) |_| {
        const l1 = 50 + r.uintLessThan(usize, 3000);
        const l2 = 50 + r.uintLessThan(usize, 3000);
        const a = try allocator.alloc(f64, l1);
        defer allocator.free(a);
        const b = try allocator.alloc(f64, l2);
        defer allocator.free(b);
        for (a) |*x| x.* = r.float(f64) * 2 - 1;
        const shift = r.uintLessThan(usize, 40);
        for (b, 0..) |*x, i| x.* = if (i >= shift and i - shift < l1) a[i - shift] + 0.1 * (r.float(f64) - 0.5) else 0.05 * r.float(f64);
        try std.testing.expectEqual(try bestLagReference(allocator, a, b), try bestLagCached(&cache, a, b));
    }
}

test "refineLag recovers bestLagCached from a perturbed correlation" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    for ([_]usize{ 37, 500, 4096 }) |len| {
        const s1 = try allocator.alloc(f64, len);
        defer allocator.free(s1);
        const s2 = try allocator.alloc(f64, len + 13);
        defer allocator.free(s2);
        for (s1) |*x| x.* = r.float(f64) + 0.5;
        for (s2, 0..) |*x, i| x.* = if (i >= 9 and i - 9 < len) s1[i - 9] else r.float(f64);
        const want = try bestLag(allocator, s1, s2);

        const n = fftSizeFor(s2.len);
        var plan = try Plan.init(allocator, n);
        defer plan.deinit();
        const corr = xcorrCircular(&plan, s1, s2);
        const approx = try allocator.alloc(f32, n);
        defer allocator.free(approx);
        var e: f64 = 0;
        for (s1) |x| e += x * x;
        for (s2) |x| e += x * x;
        const tol = 1e-6;
        for (approx, corr) |*y, x| y.* = @floatCast(x + (r.float(f64) * 2 - 1) * tol * e);
        try std.testing.expectEqual(want, refineLag(s1, s2, approx, 1, n, 1.0, tol).?);
    }
}

test "bestLagCached: bit-reversed mirror pairing matches Z[-k]" {
    var n: usize = 1;
    while (n <= 1 << 12) : (n <<= 1) {
        var plan = try fft.Plan(f64).init(std.testing.allocator, n);
        defer plan.deinit();
        const br = plan.br;
        var inv = try std.testing.allocator.alloc(usize, n);
        defer std.testing.allocator.free(inv);
        for (0..n) |pos| inv[br[pos]] = pos;
        for (0..n) |pos| {
            const want = inv[(n - br[pos]) & (n - 1)];
            const got = if (pos < 2) pos else blk: {
                const h = std.math.floorPowerOfTwo(usize, pos);
                break :blk 3 * h - 1 - pos;
            };
            try std.testing.expectEqual(want, got);
        }
    }
}
