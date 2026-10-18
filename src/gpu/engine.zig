// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! The CPU model with its `Accelerator` hot spots as f32 Slang kernels on
//! zimt (Metal, CUDA or Vulkan). Cheap delicate stages stay f64 on the CPU; MOS
//! drift vs the CPU path is <1e-6. Alignment lags are rescored in f64, so exact.
const std = @import("std");
const zimt = @import("zimt");
const kernels = @import("visqol_kernels");
const visqol = @import("../visqol.zig");
const accel = @import("../accel.zig");
const gammatone = @import("../gammatone.zig");
const xcorr = @import("../xcorr.zig");
const backend = @import("../backend.zig");

pub fn available(kind: backend.Kind) bool {
    const b = toGpu(kind) orelse return false;
    return zimt.Device.probe(std.heap.smp_allocator, b);
}

fn toGpu(kind: backend.Kind) ?zimt.Backend {
    return switch (kind) {
        .cpu => null,
        .metal => .metal,
        .cuda => .cuda,
        .vulkan => .vulkan,
    };
}

/// Upper bound on pairs scored in lock-step per accelerator round trip.
const MAX_CHUNK = 16;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    options: visqol.Options,
    model_text: []const u8,
    gpu_accel: *GpuAccel,
    main: visqol.Visqol,

    pub fn init(allocator: std.mem.Allocator, kind: backend.Kind, options: visqol.Options, model_text: []const u8) !Engine {
        const b = toGpu(kind) orelse return error.BackendUnavailable;
        const ga = try GpuAccel.create(allocator, b);
        errdefer ga.destroy();
        return .{
            .allocator = allocator,
            .options = options,
            .model_text = model_text,
            .gpu_accel = ga,
            .main = try visqol.Visqol.init(allocator, options, try backend.makeMapper(allocator, options, model_text)),
        };
    }

    pub fn deinit(self: *Engine) void {
        self.main.deinit();
        self.gpu_accel.destroy();
    }

    pub fn measure(self: *Engine, ref: []const f64, deg: []const f64, sample_rate: u32) !visqol.Result {
        var out: [1]anyerror!visqol.Result = undefined;
        try self.main.measureBatch(&.{.{ .ref = ref, .deg = deg }}, sample_rate, self.gpu_accel.accelerator(), &out);
        return out[0];
    }

    const Shared = struct {
        engine: *Engine,
        pairs: []const visqol.Pair,
        results: []anyerror!visqol.Result,
        sample_rate: u32,
        chunk: usize,
        next: std.atomic.Value(usize) = .init(0),
        failed: ?anyerror = null,
    };

    fn worker(shared: *Shared, v: *visqol.Visqol) void {
        const acc = shared.engine.gpu_accel.accelerator();
        while (true) {
            const c = shared.next.fetchAdd(1, .monotonic);
            const lo = c * shared.chunk;
            if (lo >= shared.pairs.len) return;
            const hi = @min(lo + shared.chunk, shared.pairs.len);
            v.measureBatch(shared.pairs[lo..hi], shared.sample_rate, acc, shared.results[lo..hi]) catch |e| {
                for (shared.results[lo..hi]) |*r| r.* = e;
                shared.failed = e;
            };
        }
    }

    fn workerOwned(shared: *Shared) void {
        const e = shared.engine;
        const mapper = backend.makeMapper(e.allocator, e.options, e.model_text) catch |err| return drain(shared, err);
        var v = visqol.Visqol.init(e.allocator, e.options, mapper) catch |err| return drain(shared, err);
        defer v.deinit();
        worker(shared, &v);
    }

    fn drain(shared: *Shared, err: anyerror) void {
        while (true) {
            const c = shared.next.fetchAdd(1, .monotonic);
            const lo = c * shared.chunk;
            if (lo >= shared.pairs.len) return;
            for (shared.results[lo..@min(lo + shared.chunk, shared.pairs.len)]) |*r| r.* = err;
        }
    }

    /// Lock-step chunks, up to `num_threads` concurrently, so CPU stages
    /// use every core while the accelerator batches kernels per chunk.
    pub fn measureBatch(self: *Engine, pairs: []const visqol.Pair, sample_rate: u32, num_threads: u32, results: []anyerror!visqol.Result) !void {
        if (pairs.len == 0) return;
        const cpus = std.Thread.getCpuCount() catch 1;
        const want: usize = if (num_threads == 0) cpus else num_threads;
        const chunk = std.math.clamp(std.math.divCeil(usize, pairs.len, want) catch 1, 1, MAX_CHUNK);
        const chunks = std.math.divCeil(usize, pairs.len, chunk) catch unreachable;
        const n_threads = @max(1, @min(want, chunks));
        var shared: Shared = .{ .engine = self, .pairs = pairs, .results = results, .sample_rate = sample_rate, .chunk = chunk };
        const threads = try self.allocator.alloc(std.Thread, n_threads - 1);
        defer self.allocator.free(threads);
        var spawned: usize = 0;
        defer for (threads[0..spawned]) |t| t.join();
        for (threads) |*t| {
            t.* = std.Thread.spawn(.{}, workerOwned, .{&shared}) catch break;
            spawned += 1;
        }
        worker(&shared, &self.main);
    }
};

/// Complex points per batched FFT submission (bounds device memory).
const FFT_BATCH_POINTS: usize = 1 << 22;
/// Below this size the lag search stays on the CPU.
const FFT_MIN_POINTS: usize = 1 << 10;

/// `VISQOL_GPU_LANES` sets the limit (default `defaultLanes`).
const MAX_LANES = 4;

/// CUDA lanes are streams on one context; Vulkan and Metal lanes are whole
/// devices, which past two cost more than they overlap (Vulkan, RTX 3080).
fn defaultLanes(b: zimt.Backend) usize {
    return if (b == .cuda) 4 else 2;
}

/// `accel.Accelerator` over zimt devices (lanes), opened as concurrent
/// callers need them, so batch threads don't queue on one.
pub const GpuAccel = struct {
    allocator: std.mem.Allocator,
    backend: zimt.Backend,
    lanes: [MAX_LANES]?*Lane = @splat(null),
    lane_count: std.atomic.Value(usize) = .init(0),
    max_lanes: usize,
    grow: std.Io.Mutex = .init,
    next_lane: std.atomic.Value(usize) = .init(0),

    const Twiddles = struct { n: usize, buf: zimt.Buffer };

    const Kernels = struct {
        gammatone_frames: zimt.Kernel(kernels.gammatone_frames),
        ref_stats: zimt.Kernel(kernels.ref_stats),
        patch_sims: zimt.Kernel(kernels.patch_sims),
        fft_radix2: zimt.Kernel(kernels.fft_radix2),
        fft_radix4: zimt.Kernel(kernels.fft_radix4),
        fft_radix16: zimt.Kernel(kernels.fft_radix16),
        xcorr_spectrum: zimt.Kernel(kernels.xcorr_spectrum),
        lag_pack: zimt.Kernel(kernels.lag_pack),
        lag_max: zimt.Kernel(kernels.lag_max),
        lag_cands: zimt.Kernel(kernels.lag_cands),
    };
    const kernel_fields = @typeInfo(Kernels).@"struct".field_names;

    const Lane = struct {
        allocator: std.mem.Allocator,
        device: *zimt.Device,
        k: Kernels,
        twiddles: [4]?Twiddles = @splat(null),
        twiddles_next: usize = 0,
        mutex: std.Io.Mutex = .init,

        fn create(allocator: std.mem.Allocator, b: zimt.Backend) !*Lane {
            const self = try allocator.create(Lane);
            errdefer allocator.destroy(self);
            const dev = try zimt.Device.open(allocator, b);
            errdefer dev.close();
            var ks: Kernels = undefined;
            var loaded: usize = 0;
            errdefer inline for (kernel_fields, 0..) |f, i| {
                if (i < loaded) dev.release(@field(ks, f));
            };
            inline for (kernel_fields) |f| {
                @field(ks, f) = try dev.kernel(@FieldType(Kernels, f).Def);
                loaded += 1;
            }
            self.* = .{ .allocator = allocator, .device = dev, .k = ks };
            return self;
        }

        fn destroy(self: *Lane) void {
            for (self.twiddles) |t| if (t) |x| self.device.free(x.buf);
            inline for (kernel_fields) |f| self.device.release(@field(self.k, f));
            self.device.close();
            self.allocator.destroy(self);
        }

        fn release(self: *Lane) void {
            self.mutex.unlock(std.Options.debug_io);
        }

        /// Stockham radix 2/4 for log2(n) mod 4, then radix 16; result in `cur`.
        ///
        fn fftPasses(self: *Lane, cur: *zimt.Buffer, oth: *zimt.Buffer, tw: zimt.Buffer, log2_n: u32, total: usize, sign: f32) !void {
            const dev = self.device;
            const n: u32 = @as(u32, 1) << @intCast(log2_n);
            const u: u32 = @intCast(total);
            var p: u32 = 1;
            if (log2_n & 1 == 1) {
                try dev.dispatch1d(self.k.fft_radix2, total / 2, .{ .x = cur.*, .y = oth.*, .tw = tw, .log2_n = log2_n, .p = p, .total = u / 2, .sign = sign });
                std.mem.swap(zimt.Buffer, cur, oth);
                p *= 2;
            }
            if (log2_n & 2 == 2) {
                try dev.dispatch1d(self.k.fft_radix4, total / 4, .{ .x = cur.*, .y = oth.*, .tw = tw, .log2_n = log2_n, .p = p, .total = u / 4, .sign = sign });
                std.mem.swap(zimt.Buffer, cur, oth);
                p *= 4;
            }
            while (p < n) : (p *= 16) {
                try dev.dispatch1d(self.k.fft_radix16, total / 16, .{ .x = cur.*, .y = oth.*, .tw = tw, .log2_n = log2_n, .p = p, .total = u / 16, .sign = sign });
                std.mem.swap(zimt.Buffer, cur, oth);
            }
        }

        /// Computed in f64 (layout in fft_common.slang).
        fn twiddleTable(self: *Lane, n: usize) !zimt.Buffer {
            for (self.twiddles) |t| if (t) |x| if (x.n == n) return x.buf;
            const log2_n = std.math.log2_int(usize, n);
            const lo: usize = @as(usize, 1) << @intCast((log2_n + 1) / 2);
            const host = try self.allocator.alloc([2]f32, lo + n / lo);
            defer self.allocator.free(host);
            const n_f: f64 = @floatFromInt(n);
            for (host, 0..) |*w, i| {
                const t = if (i < lo) i else (i - lo) * lo;
                const ang = 2.0 * std.math.pi * @as(f64, @floatFromInt(t)) / n_f;
                w.* = .{ @floatCast(@cos(ang)), @floatCast(@sin(ang)) };
            }
            const buf = try self.device.allocInit([2]f32, host);
            const slot = &self.twiddles[self.twiddles_next];
            if (slot.*) |old| self.device.free(old.buf);
            slot.* = .{ .n = n, .buf = buf };
            self.twiddles_next = (self.twiddles_next + 1) % self.twiddles.len;
            return buf;
        }
        /// Real part n · Σ_t a[t + i]·b[t]. Caller holds the mutex.
        fn correlate(self: *Lane, scope: *Scope, input: LagInput, rows: usize, n: usize) !zimt.Buffer {
            const dev = self.device;
            const total = rows * n;
            const log2_n: u32 = std.math.log2_int(usize, n);
            const u: u32 = @intCast(total);
            const d_signals = try scope.init(f32, input.signals);
            const d_layout = try scope.init(u32, input.layout);
            var cur = try scope.alloc(total * 8);
            var oth = try scope.alloc(total * 8);
            try dev.dispatch1d(self.k.lag_pack, total, .{ .signals = d_signals, .jobs = d_layout, .z = cur, .log2_n = log2_n, .total = u });
            const tw = try self.twiddleTable(n);
            try self.fftPasses(&cur, &oth, tw, log2_n, total, -1.0);
            try dev.dispatch1d(self.k.xcorr_spectrum, total, .{ .z = cur, .out = oth, .log2_n = log2_n, .total = u });
            std.mem.swap(zimt.Buffer, &cur, &oth);
            try self.fftPasses(&cur, &oth, tw, log2_n, total, 1.0);
            return cur;
        }
    };

    pub fn create(allocator: std.mem.Allocator, b: zimt.Backend) !*GpuAccel {
        const self = try allocator.create(GpuAccel);
        errdefer allocator.destroy(self);
        var max_lanes: usize = defaultLanes(b);
        if (std.c.getenv("VISQOL_GPU_LANES")) |v| {
            max_lanes = std.math.clamp(std.fmt.parseInt(usize, std.mem.span(v), 10) catch max_lanes, 1, MAX_LANES);
        }
        self.* = .{ .allocator = allocator, .backend = b, .max_lanes = max_lanes };
        // So an unusable backend fails here.
        self.lanes[0] = try Lane.create(allocator, b);
        self.lane_count.store(1, .release);
        return self;
    }

    pub fn destroy(self: *GpuAccel) void {
        for (self.lanes[0..self.lane_count.load(.acquire)]) |l| l.?.destroy();
        self.allocator.destroy(self);
    }

    /// The first free lane, else a new one, else wait for one in turn.
    fn acquire(self: *GpuAccel) *Lane {
        const io = std.Options.debug_io;
        var n = self.lane_count.load(.acquire);
        for (self.lanes[0..n]) |l| if (l.?.mutex.tryLock()) return l.?;
        if (n < self.max_lanes) grow: {
            self.grow.lockUncancelable(io);
            defer self.grow.unlock(io);
            n = self.lane_count.load(.acquire);
            if (n == self.max_lanes) break :grow;
            // A lane that fails to open just means fewer lanes.
            const l = Lane.create(self.allocator, self.backend) catch {
                self.max_lanes = n;
                break :grow;
            };
            l.mutex.lockUncancelable(io);
            self.lanes[n] = l;
            self.lane_count.store(n + 1, .release);
            return l;
        }
        n = self.lane_count.load(.acquire);
        const l = self.lanes[self.next_lane.fetchAdd(1, .monotonic) % n].?;
        l.mutex.lockUncancelable(io);
        return l;
    }

    pub fn accelerator(self: *GpuAccel) accel.Accelerator {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: accel.Accelerator.VTable = .{
        .spectrograms = spectrogramsImpl,
        .patchSimilarities = patchSimilaritiesImpl,
        .bestLags = bestLagsImpl,
    };

    /// Device buffers released together at the end of a call.
    const Scope = struct {
        dev: *zimt.Device,
        bufs: [16]zimt.Buffer = undefined,
        n: usize = 0,

        fn init(self: *Scope, comptime T: type, data: []const T) !zimt.Buffer {
            const b = try self.dev.allocInit(T, data);
            self.bufs[self.n] = b;
            self.n += 1;
            return b;
        }

        fn alloc(self: *Scope, bytes: usize) !zimt.Buffer {
            const b = try self.dev.alloc(@max(bytes, 4));
            self.bufs[self.n] = b;
            self.n += 1;
            return b;
        }

        fn deinit(self: *Scope) void {
            for (self.bufs[0..self.n]) |b| self.dev.free(b);
        }
    };

    fn spectrogramsImpl(ctx: *anyopaque, params: accel.SpecParams, jobs: []const accel.SpecJob) anyerror!void {
        const self: *GpuAccel = @ptrCast(@alignCast(ctx));
        const a = self.allocator;
        const nb = params.bands.len;

        var total_samples: usize = 0;
        var total_frames: usize = 0;
        var total_out: usize = 0;
        for (jobs) |j| {
            total_samples += j.signal.len;
            total_frames += j.num_frames;
            total_out += nb * j.num_frames;
        }
        if (total_frames == 0) return;
        if (total_samples > std.math.maxInt(u32) or total_out > std.math.maxInt(u32)) return error.BatchTooLarge;

        const signals = try a.alloc(f32, total_samples);
        defer a.free(signals);
        const frames = try a.alloc(u32, total_frames * 3);
        defer a.free(frames);
        {
            var s_off: usize = 0;
            var f_off: usize = 0;
            var o_off: usize = 0;
            for (jobs) |j| {
                for (j.signal, signals[s_off..][0..j.signal.len]) |x, *y| y.* = @floatCast(x);
                for (0..j.num_frames) |f| {
                    frames[(f_off + f) * 3 + 0] = @intCast(s_off + f * params.hop_size);
                    frames[(f_off + f) * 3 + 1] = @intCast(o_off + f);
                    frames[(f_off + f) * 3 + 2] = @intCast(j.num_frames);
                }
                s_off += j.signal.len;
                f_off += j.num_frames;
                o_off += nb * j.num_frames;
            }
        }
        const coeffs = try a.alloc(f32, nb * 8);
        defer a.free(coeffs);
        const coeffs2 = try a.alloc(f32, nb * 2);
        defer a.free(coeffs2);
        for (params.bands, 0..) |band, i| {
            const gi = 1.0 / band.gain;
            // Delta-form coefficients (see gammatone_frames.slang).
            const c = [8]f64{
                band.a0 * gi,
                (band.a0 + band.a11) * gi,
                gammatone.Band.a2 * gi,
                band.a0 + band.a12,
                band.a0 + band.a13,
                band.a0 + band.a14,
                band.b2 - 1.0,
                1.0 + band.b1 + band.b2,
            };
            for (c, coeffs[i * 8 ..][0..8]) |x, *y| y.* = @floatCast(x);
            coeffs2[i * 2] = @floatCast(band.a0);
            coeffs2[i * 2 + 1] = @floatCast(gammatone.Band.a2);
        }
        const hann = try a.alloc(f32, params.window_size);
        defer a.free(hann);
        for (params.hann[0..params.window_size], hann) |x, *y| y.* = @floatCast(x);
        const out = try a.alloc(f32, total_out);
        defer a.free(out);

        {
            const lane = self.acquire();
            defer lane.release();
            const dev = lane.device;
            var scope: Scope = .{ .dev = dev };
            defer scope.deinit();
            const d_signals = try scope.init(f32, signals);
            const d_frames = try scope.init(u32, frames);
            const d_coeffs = try scope.init(f32, coeffs);
            const d_coeffs2 = try scope.init(f32, coeffs2);
            const d_hann = try scope.init(f32, hann);
            const d_out = try scope.alloc(total_out * 4);
            try dev.dispatch1d(lane.k.gammatone_frames, total_frames * nb, .{
                .signals = d_signals,
                .frames = d_frames,
                .coeffs = d_coeffs,
                .coeffs2 = d_coeffs2,
                .hann = d_hann,
                .out = d_out,
                .num_frames = @intCast(total_frames),
                .num_bands = @intCast(nb),
                .window_size = @intCast(params.window_size),
            });
            try dev.download(d_out, 0, std.mem.sliceAsBytes(out));
        }

        var o_off: usize = 0;
        for (jobs) |j| {
            const n = nb * j.num_frames;
            for (out[o_off..][0..n], j.out[0..n]) |x, *y| y.* = x;
            o_off += n;
        }
    }

    fn patchSimilaritiesImpl(ctx: *anyopaque, jobs: []const accel.SimJob) anyerror!void {
        const self: *GpuAccel = @ptrCast(@alignCast(ctx));
        const a = self.allocator;
        const nb = jobs[0].num_bands;
        const ps = jobs[0].patch_size;
        for (jobs) |j| {
            if (j.num_bands != nb or j.patch_size != ps) return error.MixedPatchGeometry;
        }

        var ref_len: usize = 0;
        var deg_len: usize = 0;
        var num_rows: usize = 0;
        var num_tasks: usize = 0;
        for (jobs) |j| {
            ref_len += nb * j.nf_ref;
            deg_len += nb * j.nf_deg;
            num_rows += j.ref_indices.len;
            for (j.lo, j.hi) |lo, hi| num_tasks += hi - lo + 1;
        }
        if (num_rows == 0) return;
        if (ref_len > std.math.maxInt(u32) or deg_len > std.math.maxInt(u32) or num_tasks > std.math.maxInt(u32))
            return error.BatchTooLarge;

        const ref_f = try a.alloc(f32, ref_len);
        defer a.free(ref_f);
        const deg_f = try a.alloc(f32, deg_len);
        defer a.free(deg_f);
        const rows = try a.alloc(u32, num_rows * 8);
        defer a.free(rows);
        const stat_rows = try a.alloc(u32, num_rows * 3);
        defer a.free(stat_rows);
        {
            var r_off: usize = 0;
            var d_off: usize = 0;
            var row: usize = 0;
            var task: usize = 0;
            for (jobs) |j| {
                for (j.ref_spec[0 .. nb * j.nf_ref], ref_f[r_off..][0 .. nb * j.nf_ref]) |x, *y| y.* = @floatCast(x);
                for (j.deg_spec[0 .. nb * j.nf_deg], deg_f[d_off..][0 .. nb * j.nf_deg]) |x, *y| y.* = @floatCast(x);
                for (j.ref_indices, j.lo, j.hi) |ri, lo, hi| {
                    const r = rows[row * 8 ..][0..8];
                    r[0] = @intCast(task);
                    r[1] = @intCast(hi - lo + 1);
                    r[2] = @intCast(lo);
                    r[3] = @intCast(r_off);
                    r[4] = @intCast(j.nf_ref);
                    r[5] = @intCast(ri);
                    r[6] = @intCast(d_off);
                    r[7] = @intCast(j.nf_deg);
                    stat_rows[row * 3 + 0] = @intCast(r_off);
                    stat_rows[row * 3 + 1] = @intCast(j.nf_ref);
                    stat_rows[row * 3 + 2] = @intCast(ri);
                    task += hi - lo + 1;
                    row += 1;
                }
                r_off += nb * j.nf_ref;
                d_off += nb * j.nf_deg;
            }
        }
        // One per task: row r's window from rows[r * 8].
        const out = try a.alloc(f32, num_tasks);
        defer a.free(out);

        {
            const lane = self.acquire();
            defer lane.release();
            const dev = lane.device;
            var scope: Scope = .{ .dev = dev };
            defer scope.deinit();
            const d_ref = try scope.init(f32, ref_f);
            const d_deg = try scope.init(f32, deg_f);
            const d_rows = try scope.init(u32, rows);
            const d_stat_rows = try scope.init(u32, stat_rows);
            const cells = nb * ps;
            const d_mu = try scope.alloc(num_rows * cells * 4);
            const d_srs = try scope.alloc(num_rows * cells * 4);
            const d_out = try scope.alloc(num_tasks * 4);
            const u = struct {
                fn c(x: usize) u32 {
                    return @intCast(x);
                }
            }.c;
            try dev.dispatch1d(lane.k.ref_stats, num_rows * cells, .{
                .spec = d_ref,
                .rows = d_stat_rows,
                .mu = d_mu,
                .srs = d_srs,
                .num_rows = u(num_rows),
                .num_bands = u(nb),
                .patch_size = u(ps),
            });
            try dev.dispatch1d(lane.k.patch_sims, num_tasks, .{
                .ref_spec = d_ref,
                .deg_spec = d_deg,
                .rows = d_rows,
                .mu_ref = d_mu,
                .srs_ref = d_srs,
                .out = d_out,
                .num_rows = u(num_rows),
                .num_tasks = u(num_tasks),
                .num_bands = u(nb),
                .patch_size = u(ps),
            });
            try dev.download(d_out, 0, std.mem.sliceAsBytes(out));
        }

        var task: usize = 0;
        for (jobs) |j| {
            for (j.lo, j.hi, 0..) |lo, hi, p| {
                const n = hi - lo + 1;
                for (j.out[p * j.nf_deg + lo ..][0..n], out[task..][0..n]) |*y, x| y.* = x;
                task += n;
            }
        }
    }

    fn lagFftSize(j: accel.LagJob) usize {
        const biggest = @max(j.a.len, j.b.len);
        return if (biggest == 0) 0 else xcorr.fftSizeFor(biggest);
    }

    /// Exact like `refineLag`: f32 correlation and peak search on the device,
    /// f64 rescoring of the candidates.
    fn bestLagsImpl(ctx: *anyopaque, jobs: []const accel.LagJob) anyerror!void {
        const self: *GpuAccel = @ptrCast(@alignCast(ctx));
        const a = self.allocator;
        const order = try a.alloc(usize, jobs.len);
        defer a.free(order);
        var m: usize = 0;
        for (jobs, 0..) |j, i| {
            const n = lagFftSize(j);
            if (n < FFT_MIN_POINTS) {
                j.out.* = try xcorr.bestLag(a, j.a, j.b);
            } else {
                order[m] = i;
                m += 1;
            }
        }
        const SortCtx = struct {
            jobs: []const accel.LagJob,
            fn lt(c: @This(), x: usize, y: usize) bool {
                return lagFftSize(c.jobs[x]) < lagFftSize(c.jobs[y]);
            }
        };
        std.mem.sort(usize, order[0..m], SortCtx{ .jobs = jobs }, SortCtx.lt);
        var g: usize = 0;
        while (g < m) {
            const n = lagFftSize(jobs[order[g]]);
            var e = g + 1;
            while (e < m and lagFftSize(jobs[order[e]]) == n and (e - g + 1) * n <= FFT_BATCH_POINTS) e += 1;
            try self.lagGroup(jobs, order[g..e], n);
            g = e;
        }
    }

    fn lagGroup(self: *GpuAccel, jobs: []const accel.LagJob, idx: []const usize, n: usize) !void {
        const a = self.allocator;
        const rows = idx.len;
        const cap = xcorr.MAX_REFINE_CANDIDATES;
        var input = try LagInput.init(a, jobs, idx, n);
        defer input.deinit(a);
        const params = try a.alloc(u32, rows * 2);
        defer a.free(params);
        for (idx, 0..) |ji, c| {
            const j = jobs[ji];
            params[c * 2] = @intCast(@max(j.a.len, j.b.len) - 1);
            params[c * 2 + 1] = @bitCast(xcorr.refineSlack(j.a, j.b, @floatFromInt(n), lagTolerance(n)));
        }
        const counts = try a.alloc(u32, rows);
        defer a.free(counts);
        const cands = try a.alloc(i32, rows * cap);
        defer a.free(cands);
        {
            const lane = self.acquire();
            defer lane.release();
            const dev = lane.device;
            var scope: Scope = .{ .dev = dev };
            defer scope.deinit();
            const corr = try lane.correlate(&scope, input, rows, n);
            const d_params = try scope.init(u32, params);
            const d_top = try scope.alloc(rows * 4);
            const d_count = try scope.alloc(rows * 4);
            const d_cands = try scope.alloc(rows * cap * 4);
            try dev.zero(d_top, 0, rows * 4);
            try dev.zero(d_count, 0, rows * 4);
            const log2_n: u32 = std.math.log2_int(usize, n);
            const chunks = rows * (n / LAG_CHUNK);
            const uc: u32 = @intCast(chunks);
            try dev.dispatch1d(lane.k.lag_max, chunks, .{ .corr = corr, .params = d_params, .top = d_top, .log2_n = log2_n, .total_chunks = uc });
            try dev.dispatch1d(lane.k.lag_cands, chunks, .{
                .corr = corr,
                .params = d_params,
                .top = d_top,
                .count = d_count,
                .cands = d_cands,
                .log2_n = log2_n,
                .total_chunks = uc,
                .cap = cap,
            });
            try dev.download(d_count, 0, std.mem.sliceAsBytes(counts));
            try dev.download(d_cands, 0, std.mem.sliceAsBytes(cands));
        }
        var lags: [cap]i64 = undefined;
        for (idx, 0..) |ji, c| {
            const j = jobs[ji];
            // More than `cap` near-ties: refineLag gives up too.
            if (counts[c] > cap) {
                j.out.* = try xcorr.bestLag(a, j.a, j.b);
                continue;
            }
            const got = lags[0..counts[c]];
            for (got, cands[c * cap ..][0..got.len]) |*l, v| l.* = v;
            std.mem.sort(i64, got, {}, std.sort.asc(i64));
            j.out.* = xcorr.rescore(j.a, j.b, got);
        }
    }

    /// `LAG_CHUNK` in lag_common.slang.
    const LAG_CHUNK = 64;

    /// f32 correlation error bound relative to n·(‖a‖² + ‖b‖²).
    fn lagTolerance(n: usize) f64 {
        return 8.0 * std.math.floatEps(f32) * @as(f64, @floatFromInt(std.math.log2_int(usize, n)));
    }

    const LagInput = struct {
        signals: []f32,
        /// (rows, 4): s1 offset, s1 length, s2 offset, s2 length.
        layout: []u32,

        fn init(a: std.mem.Allocator, jobs: []const accel.LagJob, idx: []const usize, n: usize) !LagInput {
            var len: usize = 0;
            for (idx) |ji| len += jobs[ji].a.len + jobs[ji].b.len;
            if (len > std.math.maxInt(u32) or idx.len * n > std.math.maxInt(u32)) return error.BatchTooLarge;
            const signals = try a.alloc(f32, @max(len, 1));
            errdefer a.free(signals);
            const layout = try a.alloc(u32, idx.len * 4);
            var off: usize = 0;
            for (idx, 0..) |ji, c| {
                const j = jobs[ji];
                inline for (.{ j.a, j.b }, 0..) |sig, k| {
                    for (sig, signals[off..][0..sig.len]) |x, *y| y.* = @floatCast(x);
                    layout[c * 4 + 2 * k] = @intCast(off);
                    layout[c * 4 + 2 * k + 1] = @intCast(sig.len);
                    off += sig.len;
                }
            }
            return .{ .signals = signals, .layout = layout };
        }

        fn deinit(self: *LagInput, a: std.mem.Allocator) void {
            a.free(self.signals);
            a.free(self.layout);
        }
    };

    /// Tests only; `lagGroup` keeps the rows on the device.
    fn correlateGroup(self: *GpuAccel, jobs: []const accel.LagJob, idx: []const usize, n: usize) ![]f32 {
        const a = self.allocator;
        var input = try LagInput.init(a, jobs, idx, n);
        defer input.deinit(a);
        const out = try a.alloc(f32, idx.len * n * 2);
        errdefer a.free(out);
        const lane = self.acquire();
        defer lane.release();
        var scope: Scope = .{ .dev = lane.device };
        defer scope.deinit();
        const corr = try lane.correlate(&scope, input, idx.len, n);
        try lane.device.download(corr, 0, std.mem.sliceAsBytes(out));
        return out;
    }
};

/// Every compiled-in backend with a device; skips if there are none.
fn eachGpu(comptime body: fn (*GpuAccel) anyerror!void) !void {
    var ran = false;
    for (std.enums.values(zimt.Backend)) |b| {
        const ga = GpuAccel.create(std.testing.allocator, b) catch |e| switch (e) {
            error.BackendUnavailable => continue,
            else => return e,
        };
        defer ga.destroy();
        std.debug.print("GPU test: {t} on {s}\n", .{ b, ga.lanes[0].?.device.name() });
        try body(ga);
        ran = true;
    }
    if (!ran) return error.SkipZigTest;
}

test "GPU lag search: f32 correlation within tolerance, lags exact" {
    try eachGpu(struct {
        fn run(ga: *GpuAccel) !void {
            const allocator = std.testing.allocator;
            var prng = std.Random.DefaultPrng.init(3);
            const r = prng.random();
            // n = 2^11 .. 2^18: every log2(n) mod 4 pass schedule.
            for ([_]usize{ 1000, 3000, 9000, 20000, 70000, 130000 }, [_]i64{ 5, -17, 300, -1234, 999, -4000 }) |len, shift| {
                const s1 = try allocator.alloc(f64, len);
                defer allocator.free(s1);
                const s2 = try allocator.alloc(f64, len + 50);
                defer allocator.free(s2);
                var acc: f64 = 0;
                for (s1) |*x| {
                    acc = 0.9 * acc + r.float(f64);
                    x.* = acc;
                }
                for (s2, 0..) |*x, i| {
                    const src = @as(i64, @intCast(i)) - shift;
                    x.* = if (src >= 0 and src < len) s1[@intCast(src)] + 0.1 * r.float(f64) else r.float(f64);
                }
                var out: i64 = undefined;
                const jobs = [_]accel.LagJob{.{ .a = s1, .b = s2, .out = &out }};
                const n = GpuAccel.lagFftSize(jobs[0]);

                const flat = try ga.correlateGroup(&jobs, &.{0}, n);
                defer allocator.free(flat);
                var plan = try xcorr.Plan.init(allocator, n);
                defer plan.deinit();
                const exact = xcorr.xcorrCircular(&plan, s1, s2);
                var energy: f64 = 0;
                for (s1) |x| energy += x * x;
                for (s2) |x| energy += x * x;
                var max_err: f64 = 0;
                for (exact, 0..) |e, i| max_err = @max(max_err, @abs(flat[2 * i] / @as(f64, @floatFromInt(n)) - e) / energy);
                try std.testing.expect(max_err < GpuAccel.lagTolerance(n) / 10.0);

                try ga.accelerator().bestLags(&jobs);
                try std.testing.expectEqual(try xcorr.bestLag(allocator, s1, s2), out);
            }
        }
    }.run);
}

test "GPU spectrograms track the f64 CPU path in every band" {
    try eachGpu(struct {
        fn run(ga: *GpuAccel) !void {
            const allocator = std.testing.allocator;
            var prng = std.Random.DefaultPrng.init(11);
            const r = prng.random();
            // The 50 Hz band is the hard case: poles within ~4e-3 of z = 1 at 48 kHz.
            inline for (.{ .{ 48000, 32, 24000.0 }, .{ 16000, 21, 8000.0 } }) |cfg| {
                const sr: u32 = cfg[0];
                const NB = cfg[1];
                const f = gammatone.Filters(NB).init(sr, 50.0, cfg[2]);
                const ws: usize = @intFromFloat(@round(@as(f64, @floatFromInt(sr)) * 0.08));
                const hop = ws / 4;
                const hann = try allocator.alloc(f64, ws);
                defer allocator.free(hann);
                gammatone.hannWindow(ws, hann);
                const sig = try allocator.alloc(f64, sr);
                defer allocator.free(sig);
                for (sig, 0..) |*x, i| {
                    const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sr));
                    x.* = 0.3 * @sin(2.0 * std.math.pi * 60.0 * t) + 0.05 * (r.float(f64) * 2 - 1);
                }
                const nf = gammatone.numFrames(sig.len, ws, hop);
                const want = try allocator.alloc(f64, NB * nf);
                defer allocator.free(want);
                const got = try allocator.alloc(f64, NB * nf);
                defer allocator.free(got);
                const params: accel.SpecParams = .{ .bands = &f.bands, .window_size = ws, .hop_size = hop, .hann = hann };
                var cpu: accel.Cpu = .{ .allocator = allocator };
                defer cpu.deinit();
                try cpu.accelerator().spectrograms(params, &.{.{ .signal = sig, .num_frames = nf, .out = want }});
                try ga.accelerator().spectrograms(params, &.{.{ .signal = sig, .num_frames = nf, .out = got }});
                for (want, got) |x, y| try std.testing.expect(@abs(y - x) <= 5e-5 * x);
            }
        }
    }.run);
}
