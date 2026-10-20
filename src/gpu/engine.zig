// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! GPU scoring on zimt (Metal, CUDA or Vulkan): the whole model on the
//! device (pipeline.zig) where it applies, else (exact without f64: Metal)
//! the CPU model.
const std = @import("std");
const zimt = @import("zimt");
const kernels = @import("visqol_kernels");
const visqol = @import("../visqol.zig");
const accel = @import("../accel.zig");
const gammatone = @import("../gammatone.zig");
const xcorr = @import("../xcorr.zig");
const realign = @import("../realign.zig");
const backend = @import("../backend.zig");
const pipeline = @import("pipeline.zig");

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

/// Threads in one of `k`'s thread groups (from its reflection).
pub fn threadsOf(k: anytype) usize {
    return @TypeOf(k).Def.threads[0];
}

/// Pairs scored in lock-step per chunk, at most.
const MAX_CHUNK = 16;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    options: visqol.Options,
    model_text: []const u8,
    gpu_accel: *GpuAccel,
    main: visqol.Visqol,

    pub fn init(allocator: std.mem.Allocator, kind: backend.Kind, options: visqol.Options, model_text: []const u8) !Engine {
        const b = toGpu(kind) orelse return error.BackendUnavailable;
        const ga = try GpuAccel.create(allocator, b, options.precision);
        errdefer ga.destroy();
        var opts = options;
        opts.precision = ga.precision;
        return .{
            .allocator = allocator,
            .options = opts,
            .model_text = model_text,
            .gpu_accel = ga,
            .main = try visqol.Visqol.init(allocator, opts, try backend.makeMapper(allocator, opts, model_text)),
        };
    }

    pub fn deinit(self: *Engine) void {
        self.main.deinit();
        self.gpu_accel.destroy();
    }

    pub fn measure(self: *Engine, ref: []const f64, deg: []const f64, sample_rate: u32) !visqol.Result {
        var out: [1]anyerror!visqol.Result = undefined;
        try self.score(&self.main, &.{.{ .ref = ref, .deg = deg }}, sample_rate, &out, null, null);
        return out[0];
    }

    /// On the device where it can (`pipeline.applies`), else the CPU model
    /// (no gradients there).
    fn score(self: *Engine, v: *visqol.Visqol, pairs: []const visqol.Pair, sample_rate: u32, results: []anyerror!visqol.Result, grads: ?[]const []f64, refs: ?[]const visqol.PreparedRef) !void {
        if (pipeline.applies(self.gpu_accel)) return pipeline.measureBatch(self.gpu_accel, v, pairs, sample_rate, results, grads, refs);
        if (grads != null) return error.Unsupported;
        return v.measureBatch(pairs, sample_rate, results);
    }

    const Shared = struct {
        engine: *Engine,
        pairs: []const visqol.Pair,
        results: []anyerror!visqol.Result,
        grads: ?[]const []f64,
        refs: ?[]const visqol.PreparedRef,
        sample_rate: u32,
        chunk: usize,
        next: std.atomic.Value(usize) = .init(0),
        failed: ?anyerror = null,
    };

    fn worker(shared: *Shared, v: *visqol.Visqol) void {
        while (true) {
            const c = shared.next.fetchAdd(1, .monotonic);
            const lo = c * shared.chunk;
            if (lo >= shared.pairs.len) return;
            const hi = @min(lo + shared.chunk, shared.pairs.len);
            const grads = if (shared.grads) |g| g[lo..hi] else null;
            const refs = if (shared.refs) |r| r[lo..hi] else null;
            shared.engine.score(v, shared.pairs[lo..hi], shared.sample_rate, shared.results[lo..hi], grads, refs) catch |e| {
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
    /// use every core while the device batches kernels per chunk.
    pub fn measureBatch(self: *Engine, pairs: []const visqol.Pair, sample_rate: u32, num_threads: u32, results: []anyerror!visqol.Result) !void {
        return self.batch(pairs, sample_rate, num_threads, results, null, null);
    }

    /// `refs` for `measurePrepared`; where the model runs on the device,
    /// each one's patches, energy and spectrogram are computed once.
    pub fn prepare(self: *Engine, refs: []const []const f64, sample_rate: u32) !visqol.Prepared {
        var prepared = try visqol.Prepared.init(self.allocator, refs, sample_rate, self.options.precision.?, self.options.mode);
        errdefer prepared.deinit();
        if (pipeline.applies(self.gpu_accel)) try pipeline.prepare(self.gpu_accel, &self.main, &prepared);
        return prepared;
    }

    /// `degs[i]` against `prepared.refs[i]`, as `measureBatch` (or, with
    /// `grads`, `measureBatchGrad`) would score them.
    pub fn measurePrepared(self: *Engine, prepared: *const visqol.Prepared, degs: []const []const f64, num_threads: u32, results: []anyerror!visqol.Result, grads: ?[]const []f64) !void {
        std.debug.assert(degs.len == prepared.refs.len);
        if (prepared.precision != self.options.precision.? or prepared.mode != self.options.mode) return error.InvalidInput;
        if (grads != null and !pipeline.applies(self.gpu_accel)) return error.Unsupported;
        const pairs = try self.allocator.alloc(visqol.Pair, degs.len);
        defer self.allocator.free(pairs);
        for (pairs, prepared.refs, degs) |*p, r, d| p.* = .{ .ref = r.samples, .deg = d };
        const cached = prepared.cache != null and pipeline.applies(self.gpu_accel);
        return self.batch(pairs, prepared.sample_rate, num_threads, results, grads, if (cached) prepared.refs else null);
    }

    /// `measureBatch`, with ∂moslqo/∂deg of each pair into `grads` (each its
    /// deg's length; `pipeline.measureBatch` has the details).
    pub fn measureBatchGrad(self: *Engine, pairs: []const visqol.Pair, sample_rate: u32, num_threads: u32, results: []anyerror!visqol.Result, grads: []const []f64) !void {
        if (!pipeline.applies(self.gpu_accel)) return error.Unsupported;
        return self.batch(pairs, sample_rate, num_threads, results, grads, null);
    }

    fn batch(self: *Engine, pairs: []const visqol.Pair, sample_rate: u32, num_threads: u32, results: []anyerror!visqol.Result, grads: ?[]const []f64, refs: ?[]const visqol.PreparedRef) !void {
        if (pairs.len == 0) return;
        const cpus = std.Thread.getCpuCount() catch 1;
        const want: usize = if (num_threads == 0) cpus else num_threads;
        const chunk = std.math.clamp(std.math.divCeil(usize, pairs.len, want) catch 1, 1, MAX_CHUNK);
        const chunks = std.math.divCeil(usize, pairs.len, chunk) catch unreachable;
        const n_threads = @max(1, @min(want, chunks));
        var shared: Shared = .{ .engine = self, .pairs = pairs, .results = results, .grads = grads, .refs = refs, .sample_rate = sample_rate, .chunk = chunk };
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
pub const FFT_BATCH_POINTS: usize = 1 << 22;
/// Below this size the lag search stays on the CPU.
const FFT_MIN_POINTS: usize = 1 << 10;

/// `VISQOL_GPU_LANES` sets the limit (default `defaultLanes`).
pub const MAX_LANES = 4;

/// CUDA lanes are streams on one context; Vulkan and Metal lanes are whole
/// devices, which past two cost more than they overlap (Vulkan, RTX 3080).
fn defaultLanes(b: zimt.Backend) usize {
    return if (b == .cuda) 4 else 2;
}

/// zimt devices (lanes), opened as concurrent
/// callers need them, so batch threads don't queue on one.
pub const GpuAccel = struct {
    allocator: std.mem.Allocator,
    backend: zimt.Backend,
    lanes: [MAX_LANES]?*Lane = @splat(null),
    lane_count: std.atomic.Value(usize) = .init(0),
    max_lanes: usize,
    precision: visqol.Precision,
    /// Whether the lanes loaded f64 kernels: exact precision, on a device
    /// with f64.
    float64: bool = false,
    /// Candidates rescored per lag; past it the CPU searches (tests lower it).
    lag_cap: u32 = xcorr.MAX_REFINE_CANDIDATES,
    grow: std.Io.Mutex = .init,
    next_lane: std.atomic.Value(usize) = .init(0),

    const Complex = zimt.Buffer([2]f32);
    const Twiddles = struct { n: usize, buf: Complex };

    /// f32 builds, and the lag search.
    pub const Kernels = struct {
        fft_radix2: zimt.Kernel(kernels.fft_radix2),
        fft_radix4: zimt.Kernel(kernels.fft_radix4),
        fft_radix16: zimt.Kernel(kernels.fft_radix16),
        xcorr_spectrum: zimt.Kernel(kernels.xcorr_spectrum),
        lag_pack: zimt.Kernel(kernels.lag_pack),
        lag_max: zimt.Kernel(kernels.lag_max),
        lag_cands: zimt.Kernel(kernels.lag_cands),
        lag_first: zimt.Kernel(kernels.lag_first),
        lag_fast_pick: zimt.Kernel(kernels.lag_fast_pick),
        env_sums_f32: zimt.Kernel(kernels.env_sums_f32),
        env_reduce_f32: zimt.Kernel(kernels.env_reduce_f32),
        env_nyq_f32: zimt.Kernel(kernels.env_nyq_f32),
        env_write_f32: zimt.Kernel(kernels.env_write_f32),
        lag_params_f32: zimt.Kernel(kernels.lag_params_f32),
        gammatone_frames_f32: zimt.Kernel(kernels.gammatone_frames_f32),
        gammatone_patches_f32: zimt.Kernel(kernels.gammatone_patches_f32),
        spec_prep_f32: zimt.Kernel(kernels.spec_prep_f32),
        deg_plane_f32: zimt.Kernel(kernels.deg_plane_f32),
        ref_terms_f32: zimt.Kernel(kernels.ref_terms_f32),
        nsim_table_f32: zimt.Kernel(kernels.nsim_table_f32),
        nsim_bands_f32: zimt.Kernel(kernels.nsim_bands_f32),
        spec_prep_bwd_f32: zimt.Kernel(kernels.spec_prep_bwd_f32),
        nsim_bands_bwd_f32: zimt.Kernel(kernels.nsim_bands_bwd_f32),
        nsim_cells_bwd_f32: zimt.Kernel(kernels.nsim_cells_bwd_f32),
        spec_grad_f32: zimt.Kernel(kernels.spec_grad_f32),
        gammatone_bwd_f32: zimt.Kernel(kernels.gammatone_bwd_f32),
        signal_grad_f32: zimt.Kernel(kernels.signal_grad_f32),
        copy_f32: zimt.Kernel(kernels.copy_f32),
        dp_search_f32: zimt.Kernel(kernels.dp_search_f32),
        match_rows_f32: zimt.Kernel(kernels.match_rows_f32),
        match_finalize_f32: zimt.Kernel(kernels.match_finalize_f32),
        spl_energy_f32: zimt.Kernel(kernels.spl_energy_f32),
        apply_lag_f32: zimt.Kernel(kernels.apply_lag_f32),
        realign_rows_f32: zimt.Kernel(kernels.realign_rows_f32),
        realign_frames_f32: zimt.Kernel(kernels.realign_frames_f32),
        realign_accept_f32: zimt.Kernel(kernels.realign_accept_f32),
    };

    /// Balanced precision: two-float gammatone, lag application, dB and
    /// band statistics.
    pub const KernelsBal = struct {
        gammatone_frames_bal: zimt.Kernel(kernels.gammatone_frames_bal),
        gammatone_patches_bal: zimt.Kernel(kernels.gammatone_patches_bal),
        apply_lag_bal: zimt.Kernel(kernels.apply_lag_bal),
        spec_prep_bal: zimt.Kernel(kernels.spec_prep_bal),
        nsim_bands_bal: zimt.Kernel(kernels.nsim_bands_bal),
    };

    /// Where the device has f64: the CPU-exact builds.
    pub const Kernels64 = struct {
        lag_rescore: zimt.Kernel(kernels.lag_rescore),
        lag_pick: zimt.Kernel(kernels.lag_pick),
        to_f32: zimt.Kernel(kernels.to_f32),
        env_sums_f64: zimt.Kernel(kernels.env_sums_f64),
        env_reduce_f64: zimt.Kernel(kernels.env_reduce_f64),
        env_nyq_f64: zimt.Kernel(kernels.env_nyq_f64),
        env_write_f64: zimt.Kernel(kernels.env_write_f64),
        lag_params_f64: zimt.Kernel(kernels.lag_params_f64),
        gammatone_frames_f64: zimt.Kernel(kernels.gammatone_frames_f64),
        gammatone_patches_f64: zimt.Kernel(kernels.gammatone_patches_f64),
        spec_prep_f64: zimt.Kernel(kernels.spec_prep_f64),
        deg_plane_f64: zimt.Kernel(kernels.deg_plane_f64),
        ref_terms_f64: zimt.Kernel(kernels.ref_terms_f64),
        nsim_table_f64: zimt.Kernel(kernels.nsim_table_f64),
        nsim_bands_f64: zimt.Kernel(kernels.nsim_bands_f64),
        spec_prep_bwd_f64: zimt.Kernel(kernels.spec_prep_bwd_f64),
        nsim_bands_bwd_f64: zimt.Kernel(kernels.nsim_bands_bwd_f64),
        nsim_cells_bwd_f64: zimt.Kernel(kernels.nsim_cells_bwd_f64),
        spec_grad_f64: zimt.Kernel(kernels.spec_grad_f64),
        gammatone_bwd_f64: zimt.Kernel(kernels.gammatone_bwd_f64),
        signal_grad_f64: zimt.Kernel(kernels.signal_grad_f64),
        copy_f64: zimt.Kernel(kernels.copy_f64),
        dp_search_f64: zimt.Kernel(kernels.dp_search_f64),
        match_rows_f64: zimt.Kernel(kernels.match_rows_f64),
        match_finalize_f64: zimt.Kernel(kernels.match_finalize_f64),
        spl_energy_f64: zimt.Kernel(kernels.spl_energy_f64),
        apply_lag_f64: zimt.Kernel(kernels.apply_lag_f64),
        realign_rows_f64: zimt.Kernel(kernels.realign_rows_f64),
        realign_frames_f64: zimt.Kernel(kernels.realign_frames_f64),
        realign_accept_f64: zimt.Kernel(kernels.realign_accept_f64),
    };

    /// All of `Ks`, or the error after releasing those loaded.
    fn loadKernels(comptime Ks: type, dev: *zimt.Device) !Ks {
        const fields = @typeInfo(Ks).@"struct".field_names;
        var ks: Ks = undefined;
        var loaded: usize = 0;
        errdefer inline for (fields, 0..) |f, i| {
            if (i < loaded) dev.release(@field(ks, f));
        };
        inline for (fields) |f| {
            @field(ks, f) = try dev.kernel(@FieldType(Ks, f).Def);
            loaded += 1;
        }
        return ks;
    }

    fn releaseKernels(ks: anytype, dev: *zimt.Device) void {
        inline for (@typeInfo(@TypeOf(ks)).@"struct".field_names) |f| dev.release(@field(ks, f));
    }

    fn Of(comptime precision: visqol.Precision, comptime name: []const u8) type {
        if (precision == .balanced and @hasField(KernelsBal, name ++ "_bal")) return @FieldType(KernelsBal, name ++ "_bal");
        const T = Real(precision);
        return @FieldType(if (T == f64) Kernels64 else Kernels, name ++ if (T == f64) "_f64" else "_f32");
    }

    pub const Lane = struct {
        allocator: std.mem.Allocator,
        device: *zimt.Device,
        k: Kernels,
        k64: ?Kernels64,
        kbal: ?KernelsBal,
        twiddles: [4]?Twiddles = @splat(null),
        twiddles_next: usize = 0,
        mutex: std.Io.Mutex = .init,

        /// With the f64 kernels for exact precision where the device has
        /// f64, the two-float ones for balanced.
        fn create(allocator: std.mem.Allocator, b: zimt.Backend, requested: ?visqol.Precision) !*Lane {
            const self = try allocator.create(Lane);
            errdefer allocator.destroy(self);
            const dev = try zimt.Device.open(allocator, b);
            errdefer dev.close();
            const precision = resolve(requested, dev);
            const ks = try loadKernels(Kernels, dev);
            errdefer releaseKernels(ks, dev);
            const k64 = if (precision == .exact and dev.float64) try loadKernels(Kernels64, dev) else null;
            errdefer if (k64) |k| releaseKernels(k, dev);
            const kbal = if (precision == .balanced) try loadKernels(KernelsBal, dev) else null;
            self.* = .{ .allocator = allocator, .device = dev, .k = ks, .k64 = k64, .kbal = kbal };
            return self;
        }

        fn destroy(self: *Lane) void {
            for (self.twiddles) |t| if (t) |x| self.device.free(x.buf);
            releaseKernels(self.k, self.device);
            if (self.k64) |k| releaseKernels(k, self.device);
            if (self.kbal) |k| releaseKernels(k, self.device);
            self.device.close();
            self.allocator.destroy(self);
        }

        pub fn release(self: *Lane) void {
            self.mutex.unlock(std.Options.debug_io);
        }

        /// Stockham radix 2/4 for log2(n) mod 4, then radix 16; result in `cur`.
        fn fftPasses(self: *Lane, cur: *Complex, oth: *Complex, tw: Complex, log2_n: u32, total: usize, sign: f32) !void {
            const dev = self.device;
            const n: u32 = @as(u32, 1) << @intCast(log2_n);
            const u: u32 = @intCast(total);
            var p: u32 = 1;
            if (log2_n & 1 == 1) {
                try dev.dispatch1d(self.k.fft_radix2, total / 2, .{ .x = cur.*, .y = oth.*, .tw = tw, .log2_n = log2_n, .p = p, .total = u / 2, .sign = sign });
                std.mem.swap(Complex, cur, oth);
                p *= 2;
            }
            if (log2_n & 2 == 2) {
                try dev.dispatch1d(self.k.fft_radix4, total / 4, .{ .x = cur.*, .y = oth.*, .tw = tw, .log2_n = log2_n, .p = p, .total = u / 4, .sign = sign });
                std.mem.swap(Complex, cur, oth);
                p *= 4;
            }
            while (p < n) : (p *= 16) {
                try dev.dispatch1d(self.k.fft_radix16, total / 16, .{ .x = cur.*, .y = oth.*, .tw = tw, .log2_n = log2_n, .p = p, .total = u / 16, .sign = sign });
                std.mem.swap(Complex, cur, oth);
            }
        }

        /// Computed in f64 (layout in fft_common.slang).
        fn twiddleTable(self: *Lane, n: usize) !Complex {
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
        fn correlate(self: *Lane, scope: *zimt.Arena, input: LagInput, rows: usize, n: usize) !Complex {
            const dev = self.device;
            const total = rows * n;
            const log2_n: u32 = std.math.log2_int(usize, n);
            const d_signals = try scope.allocInit(f32, input.signals);
            const d_rows = try scope.allocInit(kernels.LagRow, input.rows);
            var cur = try scope.alloc([2]f32, .device, total);
            var oth = try scope.alloc([2]f32, .device, total);
            try dev.dispatch1d(self.k.lag_pack, total, .{ .signals = d_signals, .rows = d_rows, .z = cur, .log2_n = log2_n, .total = @as(u32, @intCast(total)) });
            try self.correlateRows(&cur, &oth, n, total);
            return cur;
        }

        /// Rows a + i·b of `cur` to the real part n · Σ_t a[t + i]·b[t].
        fn correlateRows(self: *Lane, cur: *Complex, oth: *Complex, n: usize, total: usize) !void {
            const log2_n: u32 = std.math.log2_int(usize, n);
            const tw = try self.twiddleTable(n);
            try self.fftPasses(cur, oth, tw, log2_n, total, -1.0);
            try self.device.dispatch1d(self.k.xcorr_spectrum, total, .{ .z = cur.*, .out = oth.*, .log2_n = log2_n, .total = @as(u32, @intCast(total)) });
            std.mem.swap(Complex, cur, oth);
            try self.fftPasses(cur, oth, tw, log2_n, total, 1.0);
        }

        /// The `_f64` or `_f32` build of kernel `name`.
        pub fn real(self: *Lane, comptime T: type, comptime name: []const u8) @FieldType(if (T == f64) Kernels64 else Kernels, name ++ if (T == f64) "_f64" else "_f32") {
            return @field(if (T == f64) self.k64.? else self.k, name ++ if (T == f64) "_f64" else "_f32");
        }

        /// `name` for `precision`: the two-float build where balanced has
        /// one with the same arguments, else `real`'s.
        pub fn of(self: *Lane, comptime precision: visqol.Precision, comptime name: []const u8) Of(precision, name) {
            if (comptime precision == .balanced and @hasField(KernelsBal, name ++ "_bal")) return @field(self.kbal.?, name ++ "_bal");
            return self.real(Real(precision), name);
        }

        /// Lags of `rows` `first ..` (`limits`' count of them, FFT size `n`)
        /// into `lags` and `status` there: envelopes, f32 correlation, then
        /// f64 rescoring of the near-maxima (`exact`, T = f64) or the f32
        /// maximum.
        pub fn searchGroup(
            self: *Lane,
            comptime T: type,
            scope: *zimt.Arena,
            signals: zimt.Buffer(T),
            rows_buf: zimt.Buffer(kernels.LagRow),
            first: usize,
            limits: Limits,
            n: usize,
            lags: zimt.Buffer(i32),
            status: zimt.Buffer(u32),
            exact: bool,
            cap: u32,
        ) !void {
            const dev = self.device;
            const rows = limits.count();
            const total = rows * n;
            if (total > std.math.maxInt(u32)) return error.BatchTooLarge;
            const u = struct {
                fn c(x: usize) u32 {
                    return @intCast(x);
                }
            }.c;
            const log2_n: u32 = std.math.log2_int(usize, n);
            const blocks = n / ENV_BLOCK;
            const fst = u(first);
            const part = try scope.alloc(T, .device, rows * 2 * blocks);
            const stats = try scope.alloc(T, .device, rows * 4);
            const env = try scope.alloc(T, .device, total * 2);
            const energy = try scope.alloc(T, .device, rows * blocks);
            var cur = try scope.alloc([2]f32, .device, total);
            var oth = try scope.alloc([2]f32, .device, total);
            const d_params = switch (limits) {
                .device => |d| d,
                .host => |max_lags| blk: {
                    const params = try self.allocator.alloc(kernels.LagParams, rows);
                    defer self.allocator.free(params);
                    for (max_lags, params) |m, *p| p.* = .{ .max_lag = m, .slack = 0 };
                    break :blk try scope.allocInit(kernels.LagParams, params);
                },
            };
            const top = try scope.alloc(u32, .device, rows);
            try dev.zero(top, 0, rows);

            const sides = rows * 2 * blocks;
            const per = threadsOf(self.real(T, "env_sums"));
            try dev.dispatch1d(self.real(T, "env_sums"), sides * per, .{ .signals = signals, .rows = rows_buf, .part = part, .first = fst, .log2_n = log2_n, .block = ENV_BLOCK, .total = u(sides) });
            try dev.dispatch1d(self.real(T, "env_reduce"), rows * 2 * per, .{ .rows = rows_buf, .part = part, .stats = stats, .first = fst, .log2_n = log2_n, .block = ENV_BLOCK, .sides = u(rows * 2), .mode = 0 });
            try dev.dispatch1d(self.real(T, "env_nyq"), sides * per, .{ .signals = signals, .rows = rows_buf, .stats = stats, .part = part, .first = fst, .log2_n = log2_n, .block = ENV_BLOCK, .total = u(sides) });
            try dev.dispatch1d(self.real(T, "env_reduce"), rows * 2 * per, .{ .rows = rows_buf, .part = part, .stats = stats, .first = fst, .log2_n = log2_n, .block = ENV_BLOCK, .sides = u(rows * 2), .mode = 1 });
            try dev.dispatch1d(self.real(T, "env_write"), rows * blocks * per, .{
                .signals = signals,
                .rows = rows_buf,
                .stats = stats,
                .env = env,
                .z = cur,
                .energy = energy,
                .first = fst,
                .log2_n = log2_n,
                .block = ENV_BLOCK,
                .total = u(rows * blocks),
            });
            try self.correlateRows(&cur, &oth, n, total);
            const chunks = rows * (n / LAG_CHUNK);
            try dev.dispatch1d(self.k.lag_max, chunks, .{ .corr = cur, .params = d_params, .top = top, .log2_n = log2_n, .chunk = LAG_CHUNK, .total_chunks = u(chunks) });
            if (T == f64 and exact) {
                const n_f: f64 = @floatFromInt(n);
                try dev.dispatch1d(self.k64.?.lag_params_f64, rows * threadsOf(self.k64.?.lag_params_f64), .{ .energy = energy, .params = d_params, .log2_n = log2_n, .block = ENV_BLOCK, .num_rows = u(rows), .slack_scale = @floatCast(2.0 * lagTolerance(n) * n_f) });
                const count = try scope.alloc(u32, .device, rows);
                try dev.zero(count, 0, rows);
                const cands = try scope.alloc(i32, .device, rows * @max(cap, 1));
                // Overlaps are at most n / 2.
                const parts = std.math.divCeil(usize, n / 2, RESCORE_CHUNK) catch unreachable;
                const part_sums = try scope.alloc(f64, .device, rows * @max(cap, 1) * parts);
                try dev.dispatch1d(self.k.lag_cands, chunks, .{ .corr = cur, .params = d_params, .top = top, .count = count, .cands = cands, .log2_n = log2_n, .chunk = LAG_CHUNK, .total_chunks = u(chunks), .cap = cap });
                try dev.dispatch1d(self.k64.?.lag_rescore, rows * parts * threadsOf(self.k64.?.lag_rescore), .{
                    .env = env,
                    .rows = rows_buf,
                    .count = count,
                    .cands = cands,
                    .part = part_sums,
                    .first = fst,
                    .log2_n = log2_n,
                    .num_rows = u(rows),
                    .chunk = RESCORE_CHUNK,
                    .chunks = u(parts),
                    .cap = cap,
                });
                try dev.dispatch1d(self.k64.?.lag_pick, rows, .{ .count = count, .cands = cands, .part = part_sums, .lags = lags, .status = status, .first = fst, .num_rows = u(rows), .chunks = u(parts), .cap = cap });
            } else {
                const keys = try scope.alloc(u32, .device, rows);
                try dev.zero(keys, 0, rows);
                try dev.dispatch1d(self.k.lag_first, chunks, .{ .corr = cur, .params = d_params, .top = top, .keys = keys, .log2_n = log2_n, .chunk = LAG_CHUNK, .total_chunks = u(chunks) });
                try dev.dispatch1d(self.k.lag_fast_pick, rows, .{ .params = d_params, .keys = keys, .lags = lags, .status = status, .first = fst, .num_rows = u(rows) });
            }
        }
    };

    fn resolve(precision: ?visqol.Precision, dev: *const zimt.Device) visqol.Precision {
        return precision orelse if (dev.float64) .exact else .fast;
    }

    pub fn create(allocator: std.mem.Allocator, b: zimt.Backend, precision: ?visqol.Precision) !*GpuAccel {
        const self = try allocator.create(GpuAccel);
        errdefer allocator.destroy(self);
        var max_lanes: usize = defaultLanes(b);
        if (std.c.getenv("VISQOL_GPU_LANES")) |v| {
            max_lanes = std.math.clamp(std.fmt.parseInt(usize, std.mem.span(v), 10) catch max_lanes, 1, MAX_LANES);
        }
        // So an unusable backend fails here.
        const lane = try Lane.create(allocator, b, precision);
        self.* = .{ .allocator = allocator, .backend = b, .max_lanes = max_lanes, .precision = resolve(precision, lane.device), .float64 = lane.k64 != null };
        self.lanes[0] = lane;
        self.lane_count.store(1, .release);
        return self;
    }

    pub fn destroy(self: *GpuAccel) void {
        for (self.lanes[0..self.lane_count.load(.acquire)]) |l| l.?.destroy();
        self.allocator.destroy(self);
    }

    /// The first free lane, else a new one, else wait for one in turn.
    pub fn acquire(self: *GpuAccel) *Lane {
        const io = std.Options.debug_io;
        var n = self.lane_count.load(.acquire);
        for (self.lanes[0..n]) |l| if (l.?.mutex.tryLock()) return l.?;
        if (n < self.max_lanes) grow: {
            self.grow.lockUncancelable(io);
            defer self.grow.unlock(io);
            n = self.lane_count.load(.acquire);
            if (n == self.max_lanes) break :grow;
            // A lane that fails to open just means fewer lanes.
            const l = Lane.create(self.allocator, self.backend, self.precision) catch {
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

    fn lagFftSize(j: accel.LagJob) usize {
        return fftSize(j.a.len, j.b.len);
    }

    pub fn fftSize(la: usize, lb: usize) usize {
        const biggest = @max(la, lb);
        return if (biggest == 0) 0 else xcorr.fftSizeFor(biggest);
    }

    /// Each row's largest lag, or the rows' search parameters with those set.
    pub const Limits = union(enum) {
        host: []const u32,
        device: zimt.Buffer(kernels.LagParams),

        fn count(l: Limits) usize {
            return switch (l) {
                .host => |h| h.len,
                .device => |d| d.len,
            };
        }
    };

    /// Samples per envelope block, a multiple of its thread groups: also the
    /// smallest FFT size searched on the device.
    pub const ENV_BLOCK = 1024;
    /// Terms of a rescored dot product per thread group.
    const RESCORE_CHUNK = 4096;

    /// Bit k for lags k ≤ `half` that come back from seconds as k - 1
    /// (`realign.lagSamplesBack`): trim.slang's table.
    pub fn lagBackTable(a: std.mem.Allocator, half: usize, sample_rate: u32) ![]u32 {
        const words = try a.alloc(u32, half / 32 + 1);
        @memset(words, 0);
        for (1..half + 1) |k| {
            const lag: i64 = @intCast(k);
            if (realign.lagSamplesBack(lag, sample_rate) != lag) words[k / 32] |= @as(u32, 1) << @intCast(k % 32);
        }
        return words;
    }

    /// The type the pipeline computes in at `precision`.
    pub fn Real(comptime precision: visqol.Precision) type {
        return if (precision == .exact) f64 else f32;
    }

    /// Gammatone tables (gammatone_common.slang): exact in f64 in the CPU's
    /// direct form, fast in f32 in delta form, balanced the direct form in
    /// f32 hi + lo (coefficients 20 per band, hann twice its length).
    pub fn FilterTables(comptime precision: visqol.Precision) type {
        const T = Real(precision);
        return struct {
            const Self = @This();

            coeffs: []T,
            hann: []T,

            pub const Device = struct { coeffs: zimt.Buffer(T), hann: zimt.Buffer(T) };

            const split = precision == .balanced;

            pub fn init(a: std.mem.Allocator, params: accel.SpecParams) !Self {
                const width: usize = if (split) 20 else 10;
                const coeffs = try a.alloc(T, params.bands.len * width);
                errdefer a.free(coeffs);
                const hann = try a.alloc(T, params.window_size * @as(usize, if (split) 2 else 1));
                for (params.bands, 0..) |band, i| {
                    const gi = 1.0 / band.gain;
                    const a2 = gammatone.Band.a2;
                    // As `filterBandRmsFresh` forms them.
                    const c: [10]f64 = if (precision != .fast)
                        .{ band.a0 * gi, band.a11 * gi, band.a12, band.a13, band.a14, band.a0, band.b1, band.b2, 0, 0 }
                    else
                        .{ band.a0 * gi, (band.a0 + band.a11) * gi, a2 * gi, band.a0 + band.a12, band.a0 + band.a13, band.a0 + band.a14, band.b2 - 1.0, 1.0 + band.b1 + band.b2, band.a0, a2 };
                    splitInto(T, &c, coeffs[i * width ..][0..10], if (split) coeffs[i * width + 10 ..][0..10] else null);
                }
                const w = params.window_size;
                splitInto(T, params.hann[0..w], hann[0..w], if (split) hann[w..][0..w] else null);
                return .{ .coeffs = coeffs, .hann = hann };
            }

            pub fn deinit(self: *Self, a: std.mem.Allocator) void {
                a.free(self.coeffs);
                a.free(self.hann);
            }

            pub fn upload(self: Self, scope: *zimt.Arena) !Device {
                return .{ .coeffs = try scope.allocInit(T, self.coeffs), .hann = try scope.allocInit(T, self.hann) };
            }
        };
    }

    /// x as T, and with `lo` what that rounding left (as T).
    pub fn splitInto(comptime T: type, x: []const f64, hi: []T, lo: ?[]T) void {
        for (x, hi, 0..) |v, *h, i| {
            h.* = @floatCast(v);
            if (lo) |l| l[i] = @floatCast(v - @as(f64, h.*));
        }
    }

    /// `LagJob`s of signals, enveloped on the CPU.
    pub fn hostLags(self: *GpuAccel, jobs: []const accel.LagJob) !void {
        if (jobs.len == 0) return;
        const a = self.allocator;
        const envs = try a.alloc(realign.Envelopes, jobs.len);
        defer a.free(envs);
        var made: usize = 0;
        defer for (envs[0..made]) |e| {
            a.free(e.ref);
            a.free(e.deg);
        };
        const env_jobs = try a.alloc(accel.LagJob, jobs.len);
        defer a.free(env_jobs);
        for (jobs, envs, env_jobs) |j, *e, *ej| {
            e.* = try realign.alignmentEnvelopes(a, j.a, j.b);
            made += 1;
            ej.* = .{ .a = e.ref, .b = e.deg, .out = j.out };
        }
        try self.envelopeLags(env_jobs);
    }

    /// `LagJob` on the CPU, for rows with more near-ties than `lag_cap`.
    pub fn hostLag(a: std.mem.Allocator, sig_a: []const f64, sig_b: []const f64) !i64 {
        const env = try realign.alignmentEnvelopes(a, sig_a, sig_b);
        defer a.free(env.ref);
        defer a.free(env.deg);
        return xcorr.bestLag(a, env.ref, env.deg);
    }

    /// `LagJob`s whose `a` and `b` are envelopes: f32 correlation and peak
    /// search on the device, f64 rescoring of the candidates (`refineLag`).
    fn envelopeLags(self: *GpuAccel, jobs: []const accel.LagJob) !void {
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
        const params = try a.alloc(kernels.LagParams, rows);
        defer a.free(params);
        for (idx, params) |ji, *p| {
            const j = jobs[ji];
            p.* = .{ .max_lag = @intCast(@max(j.a.len, j.b.len) - 1), .slack = xcorr.refineSlack(j.a, j.b, @floatFromInt(n), lagTolerance(n)) };
        }
        const counts = try a.alloc(u32, rows);
        defer a.free(counts);
        const cands = try a.alloc(i32, rows * cap);
        defer a.free(cands);
        {
            const lane = self.acquire();
            defer lane.release();
            const dev = lane.device;
            var scope = dev.arena();
            defer scope.deinit();
            const corr = try lane.correlate(&scope, input, rows, n);
            const d_params = try scope.allocInit(kernels.LagParams, params);
            const d_top = try scope.alloc(u32, .device, rows);
            const d_count = try scope.alloc(u32, .device, rows);
            const d_cands = try scope.alloc(i32, .readback, rows * cap);
            try dev.zero(d_top, 0, rows);
            try dev.zero(d_count, 0, rows);
            const log2_n: u32 = std.math.log2_int(usize, n);
            const chunks = rows * (n / LAG_CHUNK);
            const uc: u32 = @intCast(chunks);
            try dev.dispatch1d(lane.k.lag_max, chunks, .{ .corr = corr, .params = d_params, .top = d_top, .log2_n = log2_n, .chunk = LAG_CHUNK, .total_chunks = uc });
            try dev.dispatch1d(lane.k.lag_cands, chunks, .{
                .corr = corr,
                .params = d_params,
                .top = d_top,
                .count = d_count,
                .cands = d_cands,
                .log2_n = log2_n,
                .chunk = LAG_CHUNK,
                .total_chunks = uc,
                .cap = cap,
            });
            try dev.download(d_count, 0, counts);
            try dev.download(d_cands, 0, cands);
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

    /// Correlation entries scanned per thread for the maximum and candidates.
    const LAG_CHUNK = 64;

    /// f32 correlation error bound relative to n·(‖a‖² + ‖b‖²).
    fn lagTolerance(n: usize) f64 {
        return 8.0 * std.math.floatEps(f32) * @as(f64, @floatFromInt(std.math.log2_int(usize, n)));
    }

    const LagInput = struct {
        signals: []f32,
        /// Each row's `a` and `b` in `signals`, unpadded.
        rows: []kernels.LagRow,

        fn init(a: std.mem.Allocator, jobs: []const accel.LagJob, idx: []const usize, n: usize) !LagInput {
            var len: usize = 0;
            for (idx) |ji| len += jobs[ji].a.len + jobs[ji].b.len;
            if (len > std.math.maxInt(u32) or idx.len * n > std.math.maxInt(u32)) return error.BatchTooLarge;
            const signals = try a.alloc(f32, @max(len, 1));
            errdefer a.free(signals);
            const rows = try a.alloc(kernels.LagRow, idx.len);
            var off: usize = 0;
            for (idx, rows) |ji, *r| {
                const j = jobs[ji];
                r.* = std.mem.zeroes(kernels.LagRow);
                inline for (.{ j.a, j.b }, .{ &r.a, &r.b }) |sig, side| {
                    for (sig, signals[off..][0..sig.len]) |x, *y| y.* = @floatCast(x);
                    side.* = .{ .start = @intCast(off), .pad = 0, .len = @intCast(sig.len) };
                    off += sig.len;
                }
            }
            return .{ .signals = signals, .rows = rows };
        }

        fn deinit(self: *LagInput, a: std.mem.Allocator) void {
            a.free(self.signals);
            a.free(self.rows);
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
        var scope = lane.device.arena();
        defer scope.deinit();
        const corr = try lane.correlate(&scope, input, idx.len, n);
        try lane.device.download(corr, 0, std.mem.bytesAsSlice([2]f32, std.mem.sliceAsBytes(out)));
        return out;
    }
};

/// Every compiled-in backend with a device; skips if there are none.
fn eachGpu(comptime body: fn (*GpuAccel) anyerror!void) !void {
    var ran = false;
    for (std.enums.values(zimt.Backend)) |b| {
        const ga = GpuAccel.create(std.testing.allocator, b, .exact) catch |e| switch (e) {
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

                const env = try realign.alignmentEnvelopes(allocator, s1, s2);
                defer allocator.free(env.ref);
                defer allocator.free(env.deg);
                const want = try xcorr.bestLag(allocator, env.ref, env.deg);
                out = 1 << 40;
                try ga.hostLags(&jobs);
                try std.testing.expectEqual(want, out);
            }
        }
    }.run);
}

/// Largest |gpu - cpu| / cpu, per band, of `precision`'s gammatone over a
/// 1 s signal with a strong 60 Hz tone (where f32 is hardest).
fn gammatoneError(ga: *GpuAccel, comptime precision: visqol.Precision, per_band: *[32]f64) !f64 {
    const allocator = std.testing.allocator;
    const T = GpuAccel.Real(precision);
    const sr: u32 = 48000;
    const NB = 32;
    const f = gammatone.Filters(NB).init(sr, 50.0, 24000.0);
    const ws: usize = 3840;
    const hop = ws / 4;
    const hann = try allocator.alloc(f64, ws);
    defer allocator.free(hann);
    gammatone.hannWindow(ws, hann);
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    const sig = try allocator.alloc(f64, sr);
    defer allocator.free(sig);
    for (sig, 0..) |*x, i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sr));
        x.* = 0.3 * @sin(2.0 * std.math.pi * 60.0 * t) + 0.05 * (r.float(f64) * 2 - 1);
    }
    const nf = gammatone.numFrames(sig.len, ws, hop);
    const want = try allocator.alloc(f64, NB * nf);
    defer allocator.free(want);
    const params: accel.SpecParams = .{ .bands = &f.bands, .window_size = ws, .hop_size = hop, .hann = hann };
    var cpu: accel.Cpu = .{ .allocator = allocator };
    defer cpu.deinit();
    try cpu.spectrograms(params, &.{.{ .signal = sig, .num_frames = nf, .out = want }});

    const hi = try allocator.alloc(T, sig.len);
    defer allocator.free(hi);
    const lo = try allocator.alloc(f32, sig.len);
    defer allocator.free(lo);
    GpuAccel.splitInto(T, sig, hi, if (precision == .balanced) lo else null);
    const frames = try allocator.alloc(kernels.Frame, nf);
    defer allocator.free(frames);
    for (frames, 0..) |*fr, i| fr.* = .{ .start = @intCast(i * hop), .out = @intCast(i), .stride = @intCast(nf) };
    var tables = try GpuAccel.FilterTables(precision).init(allocator, params);
    defer tables.deinit(allocator);
    const got = try allocator.alloc(T, NB * nf);
    defer allocator.free(got);
    {
        const lane = ga.acquire();
        defer lane.release();
        const dev = lane.device;
        var scope = dev.arena();
        defer scope.deinit();
        const t = try tables.upload(&scope);
        const out = try scope.alloc(T, .readback, NB * nf);
        const d_hi = try scope.allocInit(T, hi);
        const d_frames = try scope.allocInit(kernels.Frame, frames);
        const n: u32 = @intCast(nf);
        if (precision == .balanced) {
            try dev.dispatch1d(lane.kbal.?.gammatone_frames_bal, nf * NB, .{ .signals = d_hi, .signals_lo = try scope.allocInit(f32, lo), .frames = d_frames, .coeffs = t.coeffs, .hann = t.hann, .out = out, .num_frames = n, .num_bands = NB, .window_size = @intCast(ws) });
        } else {
            try dev.dispatch1d(lane.real(T, "gammatone_frames"), nf * NB, .{ .signals = d_hi, .frames = d_frames, .coeffs = t.coeffs, .hann = t.hann, .out = out, .num_frames = n, .num_bands = NB, .window_size = @intCast(ws) });
        }
        try dev.download(out, 0, got);
    }
    var worst: f64 = 0;
    @memset(per_band, 0);
    for (want, got, 0..) |x, y, i| {
        const e = @abs(@as(f64, y) - x) / x;
        worst = @max(worst, e);
        per_band[i / nf] = @max(per_band[i / nf], e);
    }
    return worst;
}

test "balanced gammatone tracks the f64 filterbank to f32 rounding" {
    for (std.enums.values(zimt.Backend)) |b| {
        var errs: [2]f64 = undefined;
        var bands: [2][32]f64 = undefined;
        inline for (.{ visqol.Precision.fast, visqol.Precision.balanced }, 0..) |precision, i| {
            const ga = GpuAccel.create(std.testing.allocator, b, precision) catch |e| switch (e) {
                error.BackendUnavailable => break,
                else => return e,
            };
            defer ga.destroy();
            errs[i] = try gammatoneError(ga, precision, &bands[i]);
        } else {
            std.debug.print("gammatone max relative error on {t}: fast {e:.2}, balanced {e:.2}\n", .{ b, errs[0], errs[1] });
            for (0..32) |k| std.debug.print("  band {d:2}: {e:.2} {e:.2}\n", .{ k, bands[0][k], bands[1][k] });
            try std.testing.expect(errs[0] < 5e-5);
            try std.testing.expect(errs[1] < 2e-7);
        }
    }
}

test "prepared references score as unprepared, bit for bit" {
    const allocator = std.testing.allocator;
    const audio = @import("../audio.zig");
    const sub = "tests/data/conformance_testdata_subset/";
    const files = [_][2][]const u8{
        .{ sub ++ "strauss48_stereo.wav", sub ++ "strauss48_stereo_lp35.wav" },
        .{ sub ++ "contrabassoon48_stereo.wav", sub ++ "contrabassoon48_stereo_24kbps_aac.wav" },
        .{ sub ++ "steely48_stereo.wav", sub ++ "steely48_stereo_lp7.wav" },
    };
    var sigs: [files.len][2]audio.Audio = undefined;
    var loaded: usize = 0;
    defer for (sigs[0..loaded]) |*p| {
        p[0].deinit();
        p[1].deinit();
    };
    for (files, &sigs) |f, *s| {
        s[0] = audio.loadAsMono(allocator, f[0]) catch return error.SkipZigTest;
        s[1] = audio.loadAsMono(allocator, f[1]) catch {
            s[0].deinit();
            return error.SkipZigTest;
        };
        loaded += 1;
    }
    var refs: [files.len][]const f64 = undefined;
    var degs: [files.len][]const f64 = undefined;
    var pairs: [files.len]visqol.Pair = undefined;
    for (sigs, &refs, &degs, &pairs) |s, *r, *d, *p| {
        r.* = s[0].samples;
        d.* = s[1].samples;
        p.* = .{ .ref = r.*, .deg = d.* };
    }
    var ran = false;
    for ([_]backend.Kind{ .cuda, .vulkan, .metal }) |kind| for ([_]visqol.Precision{ .exact, .balanced, .fast }) |precision| {
        const options: visqol.Options = .{ .mode = .audio, .precision = precision };
        var e = Engine.init(allocator, kind, options, backend.defaultModel(options)) catch continue;
        defer e.deinit();
        const gradients = pipeline.applies(e.gpu_accel);
        var want: [files.len]anyerror!visqol.Result = undefined;
        var got: [files.len]anyerror!visqol.Result = undefined;
        var g_want: [files.len][]f64 = undefined;
        var g_got: [files.len][]f64 = undefined;
        for (&g_want, &g_got, degs) |*a, *b, d| {
            a.* = try allocator.alloc(f64, d.len);
            b.* = try allocator.alloc(f64, d.len);
        }
        defer for (g_want, g_got) |a, b| {
            allocator.free(a);
            allocator.free(b);
        };
        if (gradients) try e.measureBatchGrad(&pairs, 48000, 2, &want, &g_want) else try e.measureBatch(&pairs, 48000, 2, &want);
        var prepared = try e.prepare(&refs, 48000);
        defer prepared.deinit();
        try e.measurePrepared(&prepared, &degs, 2, &got, if (gradients) &g_got else null);
        for (&want, &got) |*w, *gt| {
            var x = try w.*;
            defer x.deinit();
            var y = try gt.*;
            defer y.deinit();
            try std.testing.expectEqual(x.moslqo, y.moslqo);
            try std.testing.expectEqualSlices(f64, x.fvnsim, y.fvnsim);
            try std.testing.expectEqualSlices(f64, x.patch_band_data, y.patch_band_data);
        }
        if (gradients) for (g_want, g_got) |a, b| try std.testing.expectEqualSlices(f64, a, b);
        ran = true;
    };
    if (!ran) return error.SkipZigTest;
}
