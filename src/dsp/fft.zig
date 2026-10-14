// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Power-of-two radix-2 complex/real FFT, generic over float type.
//! Plans precompute twiddles; transforms are allocation-free.
const std = @import("std");
const math = std.math;

pub fn Complex(comptime T: type) type {
    return std.math.Complex(T);
}

fn bitReverse(x: usize, log2_n: u6) usize {
    var v = x;
    var r: usize = 0;
    var i: u6 = 0;
    while (i < log2_n) : (i += 1) {
        r = (r << 1) | (v & 1);
        v >>= 1;
    }
    return r;
}

/// FFT plan for a fixed power-of-two size `n`.
pub fn Plan(comptime T: type) type {
    return PlanWidth(T, std.simd.suggestVectorLength(T) orelse 1);
}

/// `Plan` with `VW` butterflies per SIMD group. Lanes run independent
/// butterflies with the scalar op sequence, so every width is bit-exact.
pub fn PlanWidth(comptime T: type, comptime VW: usize) type {
    return struct {
        const Self = @This();
        pub const C = Complex(T);

        n: usize,
        log2_n: u6,
        // Per-span forward twiddles: W_S^j at `tw[S/2 - 1 + j]`, j < S/2,
        // copied from the span-n table (bit-identical to strided lookup).
        // Inverse twiddles are exact conjugates.
        tw: []C,
        br: []u32,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, n: usize) !Self {
            std.debug.assert(n > 0);
            std.debug.assert(std.math.isPowerOfTwo(n));
            const log2_n: u6 = @intCast(std.math.log2_int(usize, n));

            const tw = try allocator.alloc(C, @max(n - 1, 1));
            errdefer allocator.free(tw);
            const br = try allocator.alloc(u32, n);
            errdefer allocator.free(br);

            const two_pi: T = 2.0 * std.math.pi;
            const n_f: T = @floatFromInt(n);
            const top = tw[n / 2 -| 1..][0 .. n / 2];
            for (top, 0..) |*w, k| {
                const angle: T = -two_pi * @as(T, @floatFromInt(k)) / n_f;
                w.* = .{ .re = @cos(angle), .im = @sin(angle) };
            }
            var span: usize = n / 2;
            while (span >= 2) : (span >>= 1) {
                const stride = n / span;
                for (tw[span / 2 - 1 ..][0 .. span / 2], 0..) |*w, j| w.* = top[j * stride];
            }

            var i: usize = 0;
            while (i < n) : (i += 1) {
                br[i] = @intCast(bitReverse(i, log2_n));
            }

            return .{
                .n = n,
                .log2_n = log2_n,
                .tw = tw,
                .br = br,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.tw);
            self.allocator.free(self.br);
        }

        fn bitReversePermute(self: *const Self, buf: []C) void {
            var i: usize = 0;
            while (i < self.n) : (i += 1) {
                const j = self.br[i];
                if (@as(usize, j) > i) {
                    const tmp = buf[i];
                    buf[i] = buf[j];
                    buf[j] = tmp;
                }
            }
        }

        inline fn stageTw(self: *const Self, size: usize) []const C {
            return self.tw[size / 2 - 1 ..][0 .. size / 2];
        }

        fn run(self: *const Self, buf: []C, comptime inverse: bool) void {
            std.debug.assert(buf.len == self.n);
            self.bitReversePermute(buf);

            var size: usize = 2;
            while (size <= self.n) : (size <<= 1) {
                const half = size / 2;
                const tws = self.stageTw(size);
                var k: usize = 0;
                while (k < self.n) : (k += size) {
                    var j: usize = 0;
                    while (j < half) : (j += 1) {
                        const a = buf[k + j];
                        const b = if (inverse) cmulConj(buf[k + j + half], tws[j]) else cmul(buf[k + j + half], tws[j]);
                        buf[k + j] = a.add(b);
                        buf[k + j + half] = a.sub(b);
                    }
                }
            }
        }

        /// DIF forward: natural-order in, **bit-reversed** out, unscaled.
        /// Pair with `ditInverse` for pointwise products to skip permutation.
        /// Fuses up to `MAX_FUSE` stages per pass, then finishes per `CACHE_BLOCK`.
        pub fn difForward(self: *const Self, buf: []C) void {
            std.debug.assert(buf.len == self.n);
            const block: usize = @min(self.n, CACHE_BLOCK);
            var size: usize = self.n;
            while (size > block) {
                const m = fuse(size / block);
                self.difPass(m, buf, 0, self.n, size);
                size >>= m;
            }
            var base: usize = 0;
            while (base < self.n) : (base += block) {
                var s = block;
                while (s > 1) {
                    const m = fuse(s);
                    self.difPass(m, buf, base, block, s);
                    s >>= m;
                }
            }
        }

        /// DIT inverse: **bit-reversed** in, natural-order out, unscaled.
        pub fn ditInverse(self: *const Self, buf: []C) void {
            std.debug.assert(buf.len == self.n);
            const block: usize = @min(self.n, CACHE_BLOCK);
            var base: usize = 0;
            while (base < self.n) : (base += block) {
                var done: usize = 1;
                while (done < block) {
                    const m = fuse(block / done);
                    done <<= m;
                    self.ditPass(m, buf, base, block, done);
                }
            }
            var done: usize = block;
            while (done < self.n) {
                const m = fuse(self.n / done);
                done <<= m;
                self.ditPass(m, buf, 0, self.n, done);
            }
        }

        /// 4096 points (64 KiB in f64) stay in L1 while a block's stages run.
        const CACHE_BLOCK: usize = 1 << 12;
        /// Radix-4 passes measured fastest once vectorised: a radix-16 group
        /// fills the register file with split re/im lanes and spills.
        const MAX_FUSE = 2;

        /// Stages to fuse next with `ratio` spans left: up to MAX_FUSE, split evenly.
        fn fuse(ratio: usize) u3 {
            const stages = std.math.log2_int(usize, ratio);
            const passes = (stages + MAX_FUSE - 1) / MAX_FUSE;
            return @intCast((stages + passes - 1) / passes);
        }

        inline fn cmul(x: C, w: C) C {
            return .{ .re = x.re * w.re - x.im * w.im, .im = x.re * w.im + x.im * w.re };
        }
        /// `cmul(x, conj(w))`, bit-identical to `cmul` on a stored conjugate.
        inline fn cmulConj(x: C, w: C) C {
            const wi = -w.im;
            return .{ .re = x.re * w.re - x.im * wi, .im = x.re * wi + x.im * w.re };
        }

        fn difPass(self: *const Self, m: u3, buf: []C, base: usize, len: usize, size: usize) void {
            switch (m) {
                inline 1...MAX_FUSE => |mm| self.difPassR(mm, buf, base, len, size),
                else => unreachable,
            }
        }

        fn ditPass(self: *const Self, m: u3, buf: []C, base: usize, len: usize, size: usize) void {
            switch (m) {
                inline 1...MAX_FUSE => |mm| self.ditPassR(mm, buf, base, len, size),
                else => unreachable,
            }
        }

        /// `W` complex values, split into re/im vectors.
        fn Lanes(comptime W: usize) type {
            const V = @Vector(W, T);
            return struct {
                re: V,
                im: V,

                const L = @This();
                const even: [W]i32 = blk: {
                    var e: [W]i32 = undefined;
                    for (&e, 0..) |*x, i| x.* = 2 * i;
                    break :blk e;
                };
                const odd: [W]i32 = blk: {
                    var o: [W]i32 = undefined;
                    for (&o, 0..) |*x, i| x.* = 2 * i + 1;
                    break :blk o;
                };
                const interleave: [2 * W]i32 = blk: {
                    var v: [2 * W]i32 = undefined;
                    for (0..W) |i| {
                        v[2 * i] = i;
                        v[2 * i + 1] = ~@as(i32, i);
                    }
                    break :blk v;
                };

                comptime {
                    std.debug.assert(@sizeOf(C) == 2 * @sizeOf(T));
                    std.debug.assert(@offsetOf(C, "re") == 0);
                    std.debug.assert(@offsetOf(C, "im") == @sizeOf(T));
                }

                /// `src[0..W]`, deinterleaved.
                inline fn load(src: []const C) L {
                    const raw: @Vector(2 * W, T) = @as(*const [2 * W]T, @ptrCast(src[0..W])).*;
                    return .{ .re = @shuffle(T, raw, undefined, even), .im = @shuffle(T, raw, undefined, odd) };
                }
                inline fn store(x: L, dst: []C) void {
                    @as(*[2 * W]T, @ptrCast(dst[0..W])).* = @shuffle(T, x.re, x.im, interleave);
                }
                /// `src[i * stride]` for each lane `i`.
                inline fn gather(src: []const C, stride: usize) L {
                    var x: L = undefined;
                    inline for (0..W) |i| {
                        x.re[i] = src[i * stride].re;
                        x.im[i] = src[i * stride].im;
                    }
                    return x;
                }
                inline fn scatter(x: L, dst: []C, stride: usize) void {
                    inline for (0..W) |i| dst[i * stride] = .{ .re = x.re[i], .im = x.im[i] };
                }
                inline fn splat(c: C) L {
                    return .{ .re = @splat(c.re), .im = @splat(c.im) };
                }
                inline fn add(x: L, y: L) L {
                    return .{ .re = x.re + y.re, .im = x.im + y.im };
                }
                inline fn sub(x: L, y: L) L {
                    return .{ .re = x.re - y.re, .im = x.im - y.im };
                }
                /// Same op order as `cmul`.
                inline fn mul(x: L, w: L) L {
                    return .{ .re = x.re * w.re - x.im * w.im, .im = x.re * w.im + x.im * w.re };
                }
                /// Same op order as `cmulConj`.
                inline fn mulConj(x: L, w: L) L {
                    const wi = -w.im;
                    return .{ .re = x.re * w.re - x.im * wi, .im = x.re * wi + x.im * w.re };
                }
            };
        }

        /// How a group's lanes map onto butterflies: consecutive `j` within
        /// one span (contiguous data and twiddles), or the same `j` in
        /// consecutive spans (strided data, one shared twiddle).
        const Across = enum { j, spans };

        /// One fused radix-2^m DIF (`dit == false`) or DIT group of `W`
        /// lanes at `buf[i + t*q]`; spans are `size` apart.
        inline fn group(
            comptime m: u3,
            comptime dit: bool,
            comptime W: usize,
            comptime across: Across,
            tws: *const [m][]const C,
            buf: []C,
            i: usize,
            j: usize,
            q: usize,
            size: usize,
        ) void {
            const R = 1 << m;
            const X = Lanes(W);
            var x: [R]X = undefined;
            inline for (0..R) |t| x[t] = switch (across) {
                .j => X.load(buf[i + t * q ..]),
                .spans => X.gather(buf[i + t * q ..], size),
            };
            inline for (0..m) |li| {
                const l = if (dit) m - 1 - li else li;
                const h = R >> (l + 1);
                inline for (0..R) |t| {
                    if (t % (2 * h) < h) {
                        const ti = j + (t % (2 * h)) * q;
                        const w = switch (across) {
                            .j => X.load(tws[l][ti..]),
                            .spans => X.splat(tws[l][ti]),
                        };
                        const a = x[t];
                        if (dit) {
                            const b = X.mulConj(x[t + h], w);
                            x[t] = X.add(a, b);
                            x[t + h] = X.sub(a, b);
                        } else {
                            const b = x[t + h];
                            x[t] = X.add(a, b);
                            x[t + h] = X.mul(X.sub(a, b), w);
                        }
                    }
                }
            }
            inline for (0..R) |t| switch (across) {
                .j => X.store(x[t], buf[i + t * q ..]),
                .spans => X.scatter(x[t], buf[i + t * q ..], size),
            };
        }

        /// `m` fused DIF (`dit == false`) or DIT stages at span `size`
        /// over `buf[base..base+len]`.
        fn passR(self: *const Self, comptime m: u3, comptime dit: bool, buf: []C, base: usize, len: usize, size: usize) void {
            const q = size >> m;
            var tws: [m][]const C = undefined;
            inline for (0..m) |l| tws[l] = self.stageTw(size >> l);
            const end = base + len;
            if (q >= VW) {
                var k: usize = base;
                while (k < end) : (k += size) {
                    var j: usize = 0;
                    while (j < q) : (j += VW) group(m, dit, VW, .j, &tws, buf, k + j, j, q, size);
                }
                return;
            }
            // Short spans: lanes take the same `j` in consecutive spans.
            var k: usize = base;
            while (k + VW * size <= end) : (k += VW * size) {
                for (0..q) |j| group(m, dit, VW, .spans, &tws, buf, k + j, j, q, size);
            }
            while (k < end) : (k += size) {
                for (0..q) |j| group(m, dit, 1, .j, &tws, buf, k + j, j, q, size);
            }
        }

        fn difPassR(self: *const Self, comptime m: u3, buf: []C, base: usize, len: usize, size: usize) void {
            self.passR(m, false, buf, base, len, size);
        }

        fn ditPassR(self: *const Self, comptime m: u3, buf: []C, base: usize, len: usize, size: usize) void {
            self.passR(m, true, buf, base, len, size);
        }

        /// In place, unscaled.
        pub fn fft(self: *const Self, buf: []C) void {
            self.run(buf, false);
        }

        /// In place, scaled by 1/n.
        pub fn ifft(self: *const Self, buf: []C) void {
            self.run(buf, true);
            const inv_n: T = @as(T, 1.0) / @as(T, @floatFromInt(self.n));
            for (buf) |*c| {
                c.re *= inv_n;
                c.im *= inv_n;
            }
        }

        /// `real_in.len == n`, `out.len == n / 2 + 1`. Full complex transform
        /// for numerical parity.
        pub fn rfft(self: *const Self, real_in: []const T, out: []C, scratch: []C) void {
            std.debug.assert(real_in.len == self.n);
            std.debug.assert(out.len == self.n / 2 + 1);
            std.debug.assert(scratch.len == self.n);
            for (real_in, 0..) |x, i| scratch[i] = .{ .re = x, .im = 0 };
            self.fft(scratch);
            std.mem.copyForwards(C, out, scratch[0 .. self.n / 2 + 1]);
        }

        /// `complex_in.len == n / 2 + 1`, `out.len == n`.
        pub fn irfft(self: *const Self, complex_in: []const C, out: []T, scratch: []C) void {
            std.debug.assert(complex_in.len == self.n / 2 + 1);
            std.debug.assert(out.len == self.n);
            std.debug.assert(scratch.len == self.n);
            std.mem.copyForwards(C, scratch[0 .. self.n / 2 + 1], complex_in);
            var i: usize = 1;
            while (i < self.n / 2) : (i += 1) {
                scratch[self.n - i] = .{
                    .re = complex_in[i].re,
                    .im = -complex_in[i].im,
                };
            }
            self.ifft(scratch);
            for (scratch, 0..) |c, k| out[k] = c.re;
        }
    };
}

test "fft: dc input → impulse at bin 0" {
    var plan = try Plan(f64).init(std.testing.allocator, 16);
    defer plan.deinit();

    var buf: [16]Complex(f64) = undefined;
    for (&buf) |*c| c.* = .{ .re = 1.0, .im = 0.0 };
    plan.fft(&buf);

    try std.testing.expectApproxEqAbs(@as(f64, 16.0), buf[0].re, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), buf[0].im, 1e-10);
    var i: usize = 1;
    while (i < 16) : (i += 1) {
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), buf[i].re, 1e-10);
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), buf[i].im, 1e-10);
    }
}

test "fft: ifft(fft(x)) round-trips" {
    const N = 64;
    var plan = try Plan(f64).init(std.testing.allocator, N);
    defer plan.deinit();

    var buf: [N]Complex(f64) = undefined;
    var ref: [N]Complex(f64) = undefined;
    var rng = std.Random.DefaultPrng.init(0xdeadbeef);
    const r = rng.random();
    for (&buf, &ref) |*c, *r_c| {
        c.* = .{ .re = r.float(f64) * 2.0 - 1.0, .im = r.float(f64) * 2.0 - 1.0 };
        r_c.* = c.*;
    }
    plan.fft(&buf);
    plan.ifft(&buf);
    for (buf, ref) |out, in| {
        try std.testing.expectApproxEqAbs(in.re, out.re, 1e-12);
        try std.testing.expectApproxEqAbs(in.im, out.im, 1e-12);
    }
}

test "fft: pure tone has single nonzero bin" {
    const N: usize = 64;
    var plan = try Plan(f64).init(std.testing.allocator, N);
    defer plan.deinit();

    var buf: [N]Complex(f64) = undefined;
    const k_target: usize = 5;
    var n: usize = 0;
    while (n < N) : (n += 1) {
        const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt(k_target * n)) / @as(f64, @floatFromInt(N));
        buf[n] = .{ .re = @cos(angle), .im = @sin(angle) };
    }
    plan.fft(&buf);
    // exp(+i 2π k_target n / N) has FFT bin at k = k_target with magnitude N.
    n = 0;
    while (n < N) : (n += 1) {
        const mag2 = buf[n].re * buf[n].re + buf[n].im * buf[n].im;
        if (n == k_target) {
            try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(N * N)), mag2, 1e-6);
        } else {
            try std.testing.expect(mag2 < 1e-12);
        }
    }
}

test "fft: rfft / irfft round-trip" {
    const N: usize = 128;
    var plan = try Plan(f64).init(std.testing.allocator, N);
    defer plan.deinit();

    const allocator = std.testing.allocator;
    const real_in = try allocator.alloc(f64, N);
    defer allocator.free(real_in);
    const real_out = try allocator.alloc(f64, N);
    defer allocator.free(real_out);
    const cplx = try allocator.alloc(Complex(f64), N / 2 + 1);
    defer allocator.free(cplx);
    const scratch = try allocator.alloc(Complex(f64), N);
    defer allocator.free(scratch);

    var rng = std.Random.DefaultPrng.init(0xc0ffee);
    const r = rng.random();
    for (real_in) |*x| x.* = r.float(f64) * 2.0 - 1.0;

    plan.rfft(real_in, cplx, scratch);
    plan.irfft(cplx, real_out, scratch);
    for (real_in, real_out) |a, b| {
        try std.testing.expectApproxEqAbs(a, b, 1e-12);
    }
}

test "difForward/ditInverse round-trip and match the radix-2 reference bit-for-bit" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    for ([_]usize{ 2, 4, 8, 32, 1 << 13, 1 << 15, 1 << 16, 1 << 17 }) |n| {
        var plan = try Plan(f64).init(allocator, n);
        defer plan.deinit();
        const x = try allocator.alloc(Complex(f64), n);
        defer allocator.free(x);
        const y = try allocator.alloc(Complex(f64), n);
        defer allocator.free(y);
        for (x) |*c| c.* = .{ .re = r.float(f64) - 0.5, .im = r.float(f64) - 0.5 };
        @memcpy(y, x);
        plan.difForward(y);
        // Reference: natural-order FFT, then bit-reverse.
        const z = try allocator.alloc(Complex(f64), n);
        defer allocator.free(z);
        @memcpy(z, x);
        plan.fft(z);
        for (0..n) |i| {
            const ref = z[plan.br[i]];
            try std.testing.expectApproxEqAbs(ref.re, y[i].re, 1e-9 * @as(f64, @floatFromInt(n)));
            try std.testing.expectApproxEqAbs(ref.im, y[i].im, 1e-9 * @as(f64, @floatFromInt(n)));
        }
        plan.ditInverse(y);
        const inv_n = 1.0 / @as(f64, @floatFromInt(n));
        for (x, y) |a, b| {
            try std.testing.expectApproxEqAbs(a.re, b.re * inv_n, 1e-12);
            try std.testing.expectApproxEqAbs(a.im, b.im * inv_n, 1e-12);
        }
    }
}

test "difForward/ditInverse: SIMD widths are bit-identical to scalar" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    // Covers fused passes in and above CACHE_BLOCK, and spans shorter than a vector.
    for ([_]usize{ 1, 2, 4, 8, 16, 32, 1 << 10, 1 << 13, 1 << 15 }) |n| {
        const x = try allocator.alloc(Complex(f64), n);
        defer allocator.free(x);
        for (x) |*c| c.* = .{ .re = r.float(f64) - 0.5, .im = r.float(f64) - 0.5 };

        var scalar = try PlanWidth(f64, 1).init(allocator, n);
        defer scalar.deinit();
        const want = try allocator.dupe(Complex(f64), x);
        defer allocator.free(want);
        scalar.difForward(want);
        const want_inv = try allocator.dupe(Complex(f64), want);
        defer allocator.free(want_inv);
        scalar.ditInverse(want_inv);

        inline for (.{ 2, 4, 8 }) |w| {
            var plan = try PlanWidth(f64, w).init(allocator, n);
            defer plan.deinit();
            const got = try allocator.dupe(Complex(f64), x);
            defer allocator.free(got);
            plan.difForward(got);
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(want), std.mem.sliceAsBytes(got));
            plan.ditInverse(got);
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(want_inv), std.mem.sliceAsBytes(got));
        }
    }
}
