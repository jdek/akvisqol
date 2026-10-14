// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! The CPU model with its `Accelerator` hot spots as f32 Slang kernels on
//! zimt (Metal or CUDA). Cheap delicate stages stay f64 on the CPU; MOS
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

/// `accel.Accelerator` over a `zimt.Device`.
pub const GpuAccel = struct {
    allocator: std.mem.Allocator,
    device: *zimt.Device,
    k: Kernels,
    /// Twiddle tables by FFT size (guarded by `mutex`).
    twiddles: [4]?Twiddles = @splat(null),
    twiddles_next: usize = 0,
    mutex: std.Io.Mutex = .init,

    const Twiddles = struct { n: usize, buf: zimt.Buffer };

    const Kernels = struct {
        gammatone_frames: zimt.Kernel(kernels.gammatone_frames),
        ref_stats: zimt.Kernel(kernels.ref_stats),
        patch_sims: zimt.Kernel(kernels.patch_sims),
        fft_radix2: zimt.Kernel(kernels.fft_radix2),
        fft_radix4: zimt.Kernel(kernels.fft_radix4),
        fft_radix16: zimt.Kernel(kernels.fft_radix16),
        xcorr_spectrum: zimt.Kernel(kernels.xcorr_spectrum),
    };
    const kernel_fields = @typeInfo(Kernels).@"struct".field_names;

    pub fn create(allocator: std.mem.Allocator, b: zimt.Backend) !*GpuAccel {
        const self = try allocator.create(GpuAccel);
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

    pub fn destroy(self: *GpuAccel) void {
        for (self.twiddles) |t| if (t) |x| self.device.free(x.buf);
        inline for (kernel_fields) |f| self.device.release(@field(self.k, f));
        self.device.close();
        self.allocator.destroy(self);
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
            const io = std.Options.debug_io;
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const dev = self.device;
            var scope: Scope = .{ .dev = dev };
            defer scope.deinit();
            const d_signals = try scope.init(f32, signals);
            const d_frames = try scope.init(u32, frames);
            const d_coeffs = try scope.init(f32, coeffs);
            const d_coeffs2 = try scope.init(f32, coeffs2);
            const d_hann = try scope.init(f32, hann);
            const d_out = try scope.alloc(total_out * 4);
            try dev.dispatch1d(self.k.gammatone_frames, total_frames * nb, .{
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
        var out_len: usize = 0;
        for (jobs) |j| {
            ref_len += nb * j.nf_ref;
            deg_len += nb * j.nf_deg;
            num_rows += j.ref_indices.len;
            out_len += j.ref_indices.len * j.nf_deg;
            for (j.lo, j.hi) |lo, hi| num_tasks += hi - lo + 1;
        }
        if (num_rows == 0) return;
        if (ref_len > std.math.maxInt(u32) or deg_len > std.math.maxInt(u32) or out_len > std.math.maxInt(u32) or num_tasks > std.math.maxInt(u32))
            return error.BatchTooLarge;

        const ref_f = try a.alloc(f32, ref_len);
        defer a.free(ref_f);
        const deg_f = try a.alloc(f32, deg_len);
        defer a.free(deg_f);
        const rows = try a.alloc(u32, num_rows * 8);
        defer a.free(rows);
        const stat_rows = try a.alloc(u32, num_rows * 3);
        defer a.free(stat_rows);
        const out_base = try a.alloc(u32, num_rows);
        defer a.free(out_base);
        {
            var r_off: usize = 0;
            var d_off: usize = 0;
            var row: usize = 0;
            var task: usize = 0;
            var o_off: usize = 0;
            for (jobs) |j| {
                for (j.ref_spec[0 .. nb * j.nf_ref], ref_f[r_off..][0 .. nb * j.nf_ref]) |x, *y| y.* = @floatCast(x);
                for (j.deg_spec[0 .. nb * j.nf_deg], deg_f[d_off..][0 .. nb * j.nf_deg]) |x, *y| y.* = @floatCast(x);
                for (j.ref_indices, j.lo, j.hi, 0..) |ri, lo, hi, p| {
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
                    out_base[row] = @intCast(o_off + p * j.nf_deg);
                    task += hi - lo + 1;
                    row += 1;
                }
                r_off += nb * j.nf_ref;
                d_off += nb * j.nf_deg;
                o_off += j.ref_indices.len * j.nf_deg;
            }
        }
        const out = try a.alloc(f32, out_len);
        defer a.free(out);

        {
            const io = std.Options.debug_io;
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const dev = self.device;
            var scope: Scope = .{ .dev = dev };
            defer scope.deinit();
            const d_ref = try scope.init(f32, ref_f);
            const d_deg = try scope.init(f32, deg_f);
            const d_rows = try scope.init(u32, rows);
            const d_stat_rows = try scope.init(u32, stat_rows);
            const d_out_base = try scope.init(u32, out_base);
            const cells = nb * ps;
            const d_mu = try scope.alloc(num_rows * cells * 4);
            const d_srs = try scope.alloc(num_rows * cells * 4);
            const d_out = try scope.alloc(out_len * 4);
            const u = struct {
                fn c(x: usize) u32 {
                    return @intCast(x);
                }
            }.c;
            try dev.dispatch1d(self.k.ref_stats, num_rows * cells, .{
                .spec = d_ref,
                .rows = d_stat_rows,
                .mu = d_mu,
                .srs = d_srs,
                .num_rows = u(num_rows),
                .num_bands = u(nb),
                .patch_size = u(ps),
            });
            try dev.dispatch1d(self.k.patch_sims, num_tasks, .{
                .ref_spec = d_ref,
                .deg_spec = d_deg,
                .rows = d_rows,
                .out_base = d_out_base,
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

        var o_off: usize = 0;
        for (jobs) |j| {
            for (j.lo, j.hi, 0..) |lo, hi, p| {
                for (lo..hi + 1) |off| j.out[p * j.nf_deg + off] = out[o_off + p * j.nf_deg + off];
            }
            o_off += j.ref_indices.len * j.nf_deg;
        }
    }

    fn lagFftSize(j: accel.LagJob) usize {
        const biggest = @max(j.a.len, j.b.len);
        return if (biggest == 0) 0 else xcorr.fftSizeFor(biggest);
    }

    /// f32 device FFT correlation batched by size; `refineLag` makes it exact.
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
        var result = try self.correlateGroup(jobs, idx, n);
        defer result.deinit(self);
        const flat = result.values();
        const tol = lagTolerance(n);
        for (idx, 0..) |ji, c| {
            const j = jobs[ji];
            j.out.* = xcorr.refineLag(j.a, j.b, flat[c * n * 2 ..][0 .. n * 2], 2, n, @floatFromInt(n), tol) orelse
                try xcorr.bestLag(a, j.a, j.b);
        }
    }

    /// f32 correlation error bound relative to n·(‖a‖² + ‖b‖²).
    fn lagTolerance(n: usize) f64 {
        return 8.0 * std.math.floatEps(f32) * @as(f64, @floatFromInt(std.math.log2_int(usize, n)));
    }

    /// Interleaved complex f32; real part = n · Σ_t a[t + i]·b[t].
    const Correlation = struct {
        bufs: [2]zimt.Buffer,
        view: StagedBuffer,

        fn values(self: *const Correlation) []const f32 {
            return @alignCast(std.mem.bytesAsSlice(f32, self.view.bytes));
        }

        fn deinit(self: *Correlation, ga: *GpuAccel) void {
            self.view.deinit(ga.allocator);
            ga.freeBuffers(&self.bufs);
        }
    };

    fn freeBuffers(self: *GpuAccel, bufs: []const zimt.Buffer) void {
        const io = std.Options.debug_io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (bufs) |b| self.device.free(b);
    }

    fn correlateGroup(self: *GpuAccel, jobs: []const accel.LagJob, idx: []const usize, n: usize) !Correlation {
        const a = self.allocator;
        const total = idx.len * n;
        if (total > std.math.maxInt(u32)) return error.BatchTooLarge;
        const log2_n: u32 = std.math.log2_int(usize, n);
        const dev = self.device;
        const io = std.Options.debug_io;

        var bufs: [2]zimt.Buffer = undefined;
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            bufs[0] = try dev.alloc(total * 8);
            bufs[1] = dev.alloc(total * 8) catch |e| {
                dev.free(bufs[0]);
                return e;
            };
        }
        errdefer self.freeBuffers(&bufs);

        // Stage directly into host-visible memory; fresh buffers have no queued work.
        const staged = try StagedBuffer.init(a, dev, bufs[0], total * 8);
        defer staged.deinit(a);
        const z: [][2]f32 = @alignCast(std.mem.bytesAsSlice([2]f32, staged.bytes));
        for (idx, 0..) |ji, c| {
            const j = jobs[ji];
            const zc = z[c * n ..][0..n];
            for (zc, 0..) |*v, t| v.* = .{
                if (t < j.a.len) @floatCast(j.a[t]) else 0,
                if (t < j.b.len) @floatCast(j.b[t]) else 0,
            };
        }

        var cur = bufs[0];
        var oth = bufs[1];
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            try staged.upload(dev);
            const tw = try self.twiddleTable(n);
            const u: u32 = @intCast(total);
            try self.fftPasses(&cur, &oth, tw, log2_n, total, -1.0);
            try dev.dispatch1d(self.k.xcorr_spectrum, total, .{ .z = cur, .out = oth, .log2_n = log2_n, .total = u });
            std.mem.swap(zimt.Buffer, &cur, &oth);
            try self.fftPasses(&cur, &oth, tw, log2_n, total, 1.0);
            try dev.synchronize();
        }
        return .{ .bufs = bufs, .view = try StagedBuffer.read(a, dev, cur, total * 8, &self.mutex) };
    }

    /// Device buffer's host mapping, or a host copy if unmapped.
    const StagedBuffer = struct {
        buf: zimt.Buffer,
        bytes: []align(16) u8,
        owned: bool,

        fn init(a: std.mem.Allocator, dev: *zimt.Device, buf: zimt.Buffer, len: usize) !StagedBuffer {
            _ = dev;
            if (buf.host) |h| return .{ .buf = buf, .bytes = @alignCast(h[0..len]), .owned = false };
            return .{ .buf = buf, .bytes = try a.alignedAlloc(u8, .@"16", len), .owned = true };
        }

        /// Read `buf` after the caller synchronised the device.
        fn read(a: std.mem.Allocator, dev: *zimt.Device, buf: zimt.Buffer, len: usize, mutex: *std.Io.Mutex) !StagedBuffer {
            const s = try init(a, dev, buf, len);
            if (s.owned) {
                errdefer a.free(s.bytes);
                const io = std.Options.debug_io;
                mutex.lockUncancelable(io);
                defer mutex.unlock(io);
                try dev.download(buf, 0, s.bytes);
            }
            return s;
        }

        /// Caller holds the device mutex.
        fn upload(self: StagedBuffer, dev: *zimt.Device) !void {
            if (self.owned) try dev.upload(self.buf, 0, self.bytes);
        }

        fn deinit(self: StagedBuffer, a: std.mem.Allocator) void {
            if (self.owned) a.free(self.bytes);
        }
    };

    /// Stockham radix 2/4 for log2(n) mod 4, then radix 16; result in `cur`.
    /// Caller holds the mutex.
    fn fftPasses(self: *GpuAccel, cur: *zimt.Buffer, oth: *zimt.Buffer, tw: zimt.Buffer, log2_n: u32, total: usize, sign: f32) !void {
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

    /// Computed in f64 (layout in fft_common.slang). Caller holds the mutex.
    fn twiddleTable(self: *GpuAccel, n: usize) !zimt.Buffer {
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
};

test "GPU lag search: f32 correlation within tolerance, lags exact" {
    const allocator = std.testing.allocator;
    const kind: backend.Kind = if (zimt.compiledIn(.metal)) .metal else .cuda;
    if (!available(kind)) return error.SkipZigTest;
    const ga = try GpuAccel.create(allocator, toGpu(kind).?);
    defer ga.destroy();
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

        var res = try ga.correlateGroup(&jobs, &.{0}, n);
        defer res.deinit(ga);
        const flat = res.values();
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

test "GPU spectrograms track the f64 CPU path in every band" {
    const allocator = std.testing.allocator;
    const kind: backend.Kind = if (zimt.compiledIn(.metal)) .metal else .cuda;
    if (!available(kind)) return error.SkipZigTest;
    const ga = try GpuAccel.create(allocator, toGpu(kind).?);
    defer ga.destroy();
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
