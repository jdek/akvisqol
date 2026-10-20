// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! C ABI (see `src/include/visqol.h`). Backs the Python bindings.
const std = @import("std");
const build_options = @import("build_options");
const visqol = @import("visqol.zig");
const svr = @import("svr.zig");
const lattice = @import("lattice.zig");
const realign = @import("realign.zig");
const dp = @import("dp.zig");
const zimt = @import("zimt");
const backend = @import("backend.zig");

const allocator = std.heap.smp_allocator;

const OK: c_int = 0;
const E_INVALID_ARGUMENT: c_int = -1;
const E_OUT_OF_MEMORY: c_int = -2;
const E_IO: c_int = -3;
const E_MODEL: c_int = -4;
const E_SIGNAL: c_int = -5;
const E_BACKEND: c_int = -6;
const E_INTERNAL: c_int = -7;

const PRECISION_AUTO: u32 = 3;

pub const Options = extern struct {
    mode: u32,
    search_window_radius: i32,
    use_unscaled_speech_mos_mapping: u8,
    disable_global_alignment: u8,
    disable_realignment: u8,
    use_lattice_model: u8,
    model_path: ?[*:0]const u8,
    backend: u32,
    precision: u32 = PRECISION_AUTO,
};

pub const Patch = extern struct {
    similarity: f64,
    ref_patch_start_time: f64,
    ref_patch_end_time: f64,
    deg_patch_start_time: f64,
    deg_patch_end_time: f64,
    freq_band_means: [*]const f64,
    freq_band_stddevs: [*]const f64,
    freq_band_deg_energy: [*]const f64,
};

pub const CResult = extern struct {
    moslqo: f64,
    vnsim: f64,
    alignment_lag_s: f64,
    num_bands: usize,
    fvnsim: [*]const f64,
    fvnsim10: [*]const f64,
    fstdnsim: [*]const f64,
    fvdegenergy: [*]const f64,
    center_freq_bands: [*]const f64,
    num_patches: usize,
    patch_sims: [*]const Patch,
};

/// Heap box tying the C view to the Zig result that owns its storage.
const ResultBox = struct {
    c: CResult,
    inner: visqol.Result,
    patches: []Patch,
};

const Ctx = struct {
    options: visqol.Options,
    /// Re-parsed per batch worker.
    model_text: []const u8,
    model_text_owned: bool,
    backend: backend.Kind,
    engine: backend.Engine,
};

// =============================================================================
// Errors
// =============================================================================

threadlocal var last_error_buf: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn setError(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(last_error_buf[0 .. last_error_buf.len - 1], fmt, args) catch last_error_buf[0 .. last_error_buf.len - 1];
    last_error_len = s.len;
    last_error_buf[s.len] = 0;
}

/// Codes by error-set membership, first match wins; anything unclassified
/// is a bug and reports E_INTERNAL.
const error_classes = .{
    .{ E_OUT_OF_MEMORY, error{OutOfMemory} },
    .{ E_INVALID_ARGUMENT, error{InvalidInput} },
    .{ E_IO, std.Io.Dir.ReadFileAllocError || error{ NotRiffWave, MissingFmtChunk, MissingDataChunk, UnsupportedFormat, TruncatedFile } },
    .{ E_MODEL, svr.Error || lattice.Error },
    .{ E_SIGNAL, visqol.Error || realign.Error || dp.Error || error{ TooFewSamples, EmptyAudio, ChannelCountZero } },
    .{ E_BACKEND, zimt.Error || error{ DriverError, BatchTooLarge, MixedPatchGeometry } },
};

fn errorCode(err: anyerror) c_int {
    inline for (error_classes) |class| {
        inline for (@typeInfo(class[1]).error_set.error_names.?) |name| {
            if (err == @field(anyerror, name)) return class[0];
        }
    }
    return E_INTERNAL;
}

fn mapError(err: anyerror) c_int {
    setError("{s}", .{@errorName(err)});
    return errorCode(err);
}

export fn visqol_last_error() [*:0]const u8 {
    if (last_error_len == 0) return "";
    return @ptrCast(&last_error_buf);
}

export fn visqol_abi_version() u32 {
    return 1;
}

export fn visqol_version() [*:0]const u8 {
    return build_options.version;
}

export fn visqol_available_backends() u32 {
    return backend.availableMask();
}

export fn visqol_options_default(opts: ?*Options) void {
    const o = opts orelse return;
    o.* = .{
        .mode = 0,
        .search_window_radius = visqol.constants.DEFAULT_SEARCH_WINDOW,
        .use_unscaled_speech_mos_mapping = 0,
        .disable_global_alignment = 0,
        .disable_realignment = 0,
        .use_lattice_model = 1,
        .model_path = null,
        .backend = 0,
        .precision = PRECISION_AUTO,
    };
}

// =============================================================================
// Context
// =============================================================================

export fn visqol_create(opts_in: ?*const Options, out: ?*?*Ctx) c_int {
    const out_ptr = out orelse {
        setError("out is NULL", .{});
        return E_INVALID_ARGUMENT;
    };
    out_ptr.* = null;
    var opts: Options = undefined;
    visqol_options_default(&opts);
    if (opts_in) |o| opts = o.*;

    if (opts.mode > 1) {
        setError("invalid mode {d}", .{opts.mode});
        return E_INVALID_ARGUMENT;
    }
    const kind = std.enums.fromInt(backend.Kind, opts.backend) orelse {
        setError("invalid backend {d}", .{opts.backend});
        return E_INVALID_ARGUMENT;
    };
    const precision: ?visqol.Precision = if (opts.precision == PRECISION_AUTO) null else std.enums.fromInt(visqol.Precision, opts.precision) orelse {
        setError("invalid precision {d}", .{opts.precision});
        return E_INVALID_ARGUMENT;
    };

    const options: visqol.Options = .{
        .mode = @fromBackingInt(@intCast(opts.mode)),
        .search_window_radius = if (opts.search_window_radius > 0) opts.search_window_radius else visqol.constants.DEFAULT_SEARCH_WINDOW,
        .use_unscaled_speech_mos_mapping = opts.use_unscaled_speech_mos_mapping != 0,
        .disable_global_alignment = opts.disable_global_alignment != 0,
        .disable_realignment = opts.disable_realignment != 0,
        .use_lattice_model = opts.use_lattice_model != 0,
        .precision = precision,
    };

    var model_text: []const u8 = backend.defaultModel(options);
    var model_owned = false;
    if (options.mode == .audio or options.use_lattice_model) {
        if (opts.model_path) |p| {
            const path = std.mem.span(p);
            if (path.len > 0) {
                const io = std.Options.debug_io;
                model_text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024 * 1024)) catch |e| {
                    const rc = mapError(e);
                    setError("cannot read model '{s}': {s}", .{ path, @errorName(e) });
                    return rc;
                };
                model_owned = true;
            }
        }
    }
    errdefer if (model_owned) allocator.free(model_text);

    const ctx = allocator.create(Ctx) catch return mapError(error.OutOfMemory);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .options = options,
        .model_text = model_text,
        .model_text_owned = model_owned,
        .backend = kind,
        .engine = undefined,
    };
    ctx.engine = backend.Engine.init(allocator, kind, options, model_text) catch |e| {
        const rc = mapError(e);
        if (model_owned) allocator.free(model_text);
        allocator.destroy(ctx);
        return rc;
    };
    out_ptr.* = ctx;
    return OK;
}

export fn visqol_destroy(ctx: ?*Ctx) void {
    const c = ctx orelse return;
    c.engine.deinit();
    if (c.model_text_owned) allocator.free(c.model_text);
    allocator.destroy(c);
}

// =============================================================================
// Measure
// =============================================================================

fn boxResult(r: visqol.Result) !*CResult {
    var inner = r;
    errdefer inner.deinit();
    const box = try allocator.create(ResultBox);
    errdefer allocator.destroy(box);
    const patches = try allocator.alloc(Patch, inner.patch_sims.len);
    for (inner.patch_sims, patches) |p, *c| c.* = .{
        .similarity = p.similarity,
        .ref_patch_start_time = p.ref_patch_start_time,
        .ref_patch_end_time = p.ref_patch_end_time,
        .deg_patch_start_time = p.deg_patch_start_time,
        .deg_patch_end_time = p.deg_patch_end_time,
        .freq_band_means = p.freq_band_means.ptr,
        .freq_band_stddevs = p.freq_band_stddevs.ptr,
        .freq_band_deg_energy = p.freq_band_deg_energy.ptr,
    };
    box.* = .{
        .inner = inner,
        .patches = patches,
        .c = .{
            .moslqo = inner.moslqo,
            .vnsim = inner.vnsim,
            .alignment_lag_s = inner.alignment_lag_s,
            .num_bands = inner.fvnsim.len,
            .fvnsim = inner.fvnsim.ptr,
            .fvnsim10 = inner.fvnsim10.ptr,
            .fstdnsim = inner.fstdnsim.ptr,
            .fvdegenergy = inner.fvdegenergy.ptr,
            .center_freq_bands = inner.center_freq_bands.ptr,
            .num_patches = patches.len,
            .patch_sims = patches.ptr,
        },
    };
    return &box.c;
}

export fn visqol_result_free(result: ?*CResult) void {
    const c = result orelse return;
    const box: *ResultBox = @fieldParentPtr("c", c);
    box.inner.deinit();
    allocator.free(box.patches);
    allocator.destroy(box);
}

export fn visqol_measure(
    ctx: ?*Ctx,
    ref: ?[*]const f64,
    ref_len: usize,
    deg: ?[*]const f64,
    deg_len: usize,
    sample_rate: u32,
    out: ?*?*CResult,
) c_int {
    const c = ctx orelse return invalid("ctx is NULL");
    const o = out orelse return invalid("out is NULL");
    o.* = null;
    if ((ref == null and ref_len > 0) or (deg == null and deg_len > 0)) return invalid("signal pointer is NULL");
    const r_s: []const f64 = if (ref) |p| p[0..ref_len] else &.{};
    const d_s: []const f64 = if (deg) |p| p[0..deg_len] else &.{};
    const r = c.engine.measure(r_s, d_s, sample_rate) catch |e| return mapError(e);
    o.* = boxResult(r) catch |e| return mapError(e);
    return OK;
}

export fn visqol_measure_files(ctx: ?*Ctx, ref_path: ?[*:0]const u8, deg_path: ?[*:0]const u8, out: ?*?*CResult) c_int {
    const c = ctx orelse return invalid("ctx is NULL");
    const o = out orelse return invalid("out is NULL");
    o.* = null;
    const rp = std.mem.span(ref_path orelse return invalid("ref_path is NULL"));
    const dp_ = std.mem.span(deg_path orelse return invalid("deg_path is NULL"));
    const audio = @import("audio.zig");
    var ra = audio.loadAsMono(allocator, rp) catch |e| return fileError(e, rp);
    defer ra.deinit();
    var da = audio.loadAsMono(allocator, dp_) catch |e| return fileError(e, dp_);
    defer da.deinit();
    if (ra.sample_rate != da.sample_rate) {
        setError("Input audio signals have different sample rates! Reference audio sample rate: {d}. Degraded audio sample rate: {d}", .{ ra.sample_rate, da.sample_rate });
        return E_SIGNAL;
    }
    const r = c.engine.measure(ra.samples, da.samples, ra.sample_rate) catch |e| return mapError(e);
    o.* = boxResult(r) catch |e| return mapError(e);
    return OK;
}

fn fileError(e: anyerror, path: []const u8) c_int {
    const rc = mapError(e);
    setError("{s}: {s}", .{ path, @errorName(e) });
    return rc;
}

fn invalid(msg: []const u8) c_int {
    setError("{s}", .{msg});
    return E_INVALID_ARGUMENT;
}

export fn visqol_measure_batch(
    ctx: ?*Ctx,
    n: usize,
    refs: ?[*]const [*]const f64,
    ref_lens: ?[*]const usize,
    degs: ?[*]const [*]const f64,
    deg_lens: ?[*]const usize,
    sample_rate: u32,
    num_threads: u32,
    out: ?[*]?*CResult,
    status: ?[*]i32,
) c_int {
    const c = ctx orelse return invalid("ctx is NULL");
    if (n == 0) return OK;
    const o = out orelse return invalid("out is NULL");
    const rs = refs orelse return invalid("refs is NULL");
    const rl = ref_lens orelse return invalid("ref_lens is NULL");
    const ds = degs orelse return invalid("degs is NULL");
    const dl = deg_lens orelse return invalid("deg_lens is NULL");

    const pairs = allocator.alloc(backend.Pair, n) catch |e| return mapError(e);
    defer allocator.free(pairs);
    for (pairs, 0..) |*p, i| p.* = .{ .ref = rs[i][0..rl[i]], .deg = ds[i][0..dl[i]] };
    const results = allocator.alloc(anyerror!visqol.Result, n) catch |e| return mapError(e);
    defer allocator.free(results);

    c.engine.measureBatch(pairs, sample_rate, num_threads, results) catch |e| return mapError(e);

    var first_err: c_int = OK;
    for (results, 0..) |r, i| {
        o[i] = null;
        var rc: c_int = OK;
        if (r) |res| {
            if (boxResult(res)) |boxed| {
                o[i] = boxed;
            } else |e| rc = mapError(e);
        } else |e| rc = mapError(e);
        if (status) |s| s[i] = rc;
        if (rc != OK and first_err == OK) first_err = rc;
    }
    return first_err;
}

/// Batched per sample rate; per-pair failures land in `status`.
export fn visqol_measure_files_batch(
    ctx: ?*Ctx,
    n: usize,
    ref_paths: ?[*]const [*:0]const u8,
    deg_paths: ?[*]const [*:0]const u8,
    num_threads: u32,
    out: ?[*]?*CResult,
    status: ?[*]i32,
) c_int {
    const c = ctx orelse return invalid("ctx is NULL");
    if (n == 0) return OK;
    const o = out orelse return invalid("out is NULL");
    const rp = ref_paths orelse return invalid("ref_paths is NULL");
    const dp_ = deg_paths orelse return invalid("deg_paths is NULL");
    const audio = @import("audio.zig");

    const Loaded = struct { ref: audio.Audio, deg: audio.Audio };
    const loaded = allocator.alloc(?Loaded, n) catch |e| return mapError(e);
    defer allocator.free(loaded);
    @memset(loaded, null);
    defer for (loaded) |*l| if (l.*) |*x| {
        x.ref.deinit();
        x.deg.deinit();
    };
    const codes = allocator.alloc(c_int, n) catch |e| return mapError(e);
    defer allocator.free(codes);
    @memset(codes, OK);
    for (0..n) |i| {
        o[i] = null;
        var ra = audio.loadAsMono(allocator, std.mem.span(rp[i])) catch |e| {
            codes[i] = fileError(e, std.mem.span(rp[i]));
            continue;
        };
        const da = audio.loadAsMono(allocator, std.mem.span(dp_[i])) catch |e| {
            ra.deinit();
            codes[i] = fileError(e, std.mem.span(dp_[i]));
            continue;
        };
        loaded[i] = .{ .ref = ra, .deg = da };
        if (ra.sample_rate != da.sample_rate) {
            setError("pair {d}: reference and degraded sample rates differ ({d} vs {d})", .{ i, ra.sample_rate, da.sample_rate });
            codes[i] = E_SIGNAL;
        }
    }

    const idx = allocator.alloc(usize, n) catch |e| return mapError(e);
    defer allocator.free(idx);
    const pairs = allocator.alloc(backend.Pair, n) catch |e| return mapError(e);
    defer allocator.free(pairs);
    const results = allocator.alloc(anyerror!visqol.Result, n) catch |e| return mapError(e);
    defer allocator.free(results);
    const done = allocator.alloc(bool, n) catch |e| return mapError(e);
    defer allocator.free(done);
    for (done, codes) |*d, code| d.* = code != OK;
    for (0..n) |first| {
        if (done[first]) continue;
        const rate = loaded[first].?.ref.sample_rate;
        var m: usize = 0;
        for (first..n) |i| {
            if (done[i] or loaded[i].?.ref.sample_rate != rate) continue;
            idx[m] = i;
            pairs[m] = .{ .ref = loaded[i].?.ref.samples, .deg = loaded[i].?.deg.samples };
            done[i] = true;
            m += 1;
        }
        c.engine.measureBatch(pairs[0..m], rate, num_threads, results[0..m]) catch |e| return mapError(e);
        for (idx[0..m], results[0..m]) |i, r| {
            if (r) |res| {
                if (boxResult(res)) |boxed| {
                    o[i] = boxed;
                } else |e| codes[i] = mapError(e);
            } else |e| codes[i] = mapError(e);
        }
    }

    var first_err: c_int = OK;
    for (codes, 0..) |rc, i| {
        if (status) |s| s[i] = rc;
        if (rc != OK and first_err == OK) first_err = rc;
    }
    return first_err;
}

test "errorCode: classes" {
    try std.testing.expectEqual(E_OUT_OF_MEMORY, errorCode(error.OutOfMemory));
    try std.testing.expectEqual(E_INVALID_ARGUMENT, errorCode(error.InvalidInput));
    try std.testing.expectEqual(E_IO, errorCode(error.FileNotFound));
    try std.testing.expectEqual(E_IO, errorCode(error.NotDir));
    try std.testing.expectEqual(E_IO, errorCode(error.StreamTooLong));
    try std.testing.expectEqual(E_IO, errorCode(error.NotRiffWave));
    try std.testing.expectEqual(E_MODEL, errorCode(error.InvalidModelFile));
    try std.testing.expectEqual(E_MODEL, errorCode(error.UnsupportedOp));
    try std.testing.expectEqual(E_SIGNAL, errorCode(error.NoPatches));
    try std.testing.expectEqual(E_SIGNAL, errorCode(error.TooFewSamples));
    try std.testing.expectEqual(E_BACKEND, errorCode(error.DeviceError));
    try std.testing.expectEqual(E_BACKEND, errorCode(error.DriverError));
    try std.testing.expectEqual(E_INTERNAL, errorCode(error.OutputBufferTooSmall));
}
