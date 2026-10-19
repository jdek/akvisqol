// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! `visqol` command-line tool. Flags follow google/visqol's CLI.
const std = @import("std");
const visqol = @import("visqol.zig");
const audio = @import("audio.zig");
const backend = @import("backend.zig");

const usage =
    \\usage: visqol --reference_file REF.wav --degraded_file DEG.wav [options]
    \\       visqol --batch_input_csv PAIRS.csv [--results_csv OUT.csv] [options]
    \\
    \\  --similarity_to_quality_model F   SVR model (audio) or TFLite lattice model
    \\                                    (speech); default: embedded
    \\  --use_speech_mode                 speech mode (21 bands, VAD)
    \\  --use_lattice_model[=true|false]   speech mode: TF-Lattice mapping (default
    \\                                    true); false (or --nouse_lattice_model)
    \\                                    uses the exponential mapping
    \\  --use_unscaled_speech_mos_mapping exponential mapping: NSIM=1 maps to
    \\                                    MOS≈4.x instead of 5
    \\  --search_window_radius N          DP search radius in frames (default 60)
    \\  --disable_global_alignment
    \\  --disable_realignment
    \\  --verbose                         print per-band and per-patch detail
    \\  --backend cpu|metal|cuda|vulkan   compute backend (default cpu)
    \\  --threads N                       batch worker threads (default: all cores)
    \\  --precision exact|balanced|fast   GPU arithmetic: f64, the CPU's scores bit for
    \\                                    bit (default); f32 with two-float where f32
    \\                                    loses most; or f32
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {};

    var ref_path: ?[]const u8 = null;
    var deg_path: ?[]const u8 = null;
    var batch_csv: ?[]const u8 = null;
    var results_csv: ?[]const u8 = null;
    var model_path: ?[]const u8 = null;
    var options: visqol.Options = .{ .use_lattice_model = true };
    var verbose = false;
    var kind: backend.Kind = .cpu;
    var threads: u32 = 0;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = struct {
            fn f(list: []const [:0]const u8, idx: *usize) ![]const u8 {
                idx.* += 1;
                if (idx.* >= list.len) return error.MissingArgument;
                return list[idx.*];
            }
        }.f;
        if (eq(a, "--reference_file")) {
            ref_path = try next(args, &i);
        } else if (eq(a, "--degraded_file")) {
            deg_path = try next(args, &i);
        } else if (eq(a, "--batch_input_csv")) {
            batch_csv = try next(args, &i);
        } else if (eq(a, "--results_csv")) {
            results_csv = try next(args, &i);
        } else if (eq(a, "--similarity_to_quality_model")) {
            model_path = try next(args, &i);
        } else if (eq(a, "--use_speech_mode")) {
            options.mode = .speech;
        } else if (eq(a, "--use_lattice_model") or eq(a, "--use_lattice_model=true")) {
            options.use_lattice_model = true;
        } else if (eq(a, "--nouse_lattice_model") or eq(a, "--use_lattice_model=false")) {
            options.use_lattice_model = false;
        } else if (eq(a, "--use_unscaled_speech_mos_mapping")) {
            options.use_unscaled_speech_mos_mapping = true;
        } else if (eq(a, "--search_window_radius")) {
            options.search_window_radius = try std.fmt.parseInt(i32, try next(args, &i), 10);
        } else if (eq(a, "--disable_global_alignment")) {
            options.disable_global_alignment = true;
        } else if (eq(a, "--disable_realignment")) {
            options.disable_realignment = true;
        } else if (eq(a, "--verbose")) {
            verbose = true;
        } else if (eq(a, "--backend")) {
            kind = std.meta.stringToEnum(backend.Kind, try next(args, &i)) orelse return fail(out, "unknown backend");
        } else if (eq(a, "--threads")) {
            threads = try std.fmt.parseInt(u32, try next(args, &i), 10);
        } else if (eq(a, "--precision")) {
            options.precision = std.meta.stringToEnum(visqol.Precision, try next(args, &i)) orelse return fail(out, "unknown precision");
        } else if (eq(a, "-h") or eq(a, "--help")) {
            try out.writeAll(usage);
            return;
        } else {
            try out.print("unknown flag: {s}\n\n", .{a});
            try out.writeAll(usage);
            std.process.exit(2);
        }
    }

    const model_text: []const u8 = if (model_path) |p|
        try std.Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(256 * 1024 * 1024))
    else
        backend.defaultModel(options);
    defer if (model_path != null) allocator.free(model_text);

    var engine = try backend.Engine.init(allocator, kind, options, model_text);
    defer engine.deinit();

    if (batch_csv) |csv| return runBatch(allocator, io, out, &engine, csv, results_csv, threads);

    const rp = ref_path orelse return fail(out, "--reference_file is required");
    const dp = deg_path orelse return fail(out, "--degraded_file is required");
    var ra = try audio.loadAsMono(allocator, rp);
    defer ra.deinit();
    var da = try audio.loadAsMono(allocator, dp);
    defer da.deinit();
    if (ra.sample_rate != da.sample_rate) return fail(out, "reference and degraded sample rates differ");

    var r = try engine.measure(ra.samples, da.samples, ra.sample_rate);
    defer r.deinit();
    try printResult(out, rp, dp, &r, verbose);
}

fn runBatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    engine: *backend.Engine,
    csv_path: []const u8,
    results_csv: ?[]const u8,
    threads: u32,
) !void {
    const csv = try std.Io.Dir.cwd().readFileAlloc(io, csv_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(csv);

    var names: std.ArrayList([2][]const u8) = .empty;
    defer names.deinit(allocator);
    var lines = std.mem.tokenizeAny(u8, csv, "\r\n");
    var first = true;
    while (lines.next()) |line| {
        var cols = std.mem.splitScalar(u8, line, ',');
        const r = std.mem.trim(u8, cols.next() orelse continue, " ");
        const d = std.mem.trim(u8, cols.next() orelse continue, " ");
        // Upstream expects a `reference,degraded` header row.
        if (first and std.mem.eql(u8, r, "reference")) {
            first = false;
            continue;
        }
        first = false;
        try names.append(allocator, .{ r, d });
    }

    const audios = try allocator.alloc([2]audio.Audio, names.items.len);
    defer allocator.free(audios);
    const load_errs = try allocator.alloc(?anyerror, names.items.len);
    defer allocator.free(load_errs);
    try loadAll(allocator, names.items, audios, load_errs, threads);
    defer for (audios, load_errs) |*a, e| if (e == null) {
        a[0].deinit();
        a[1].deinit();
    };
    // The first failure in CSV order.
    for (load_errs) |e| if (e) |err| return err;
    const pairs = try allocator.alloc(backend.Pair, names.items.len);
    defer allocator.free(pairs);
    var sample_rate: u32 = 0;
    for (audios, pairs) |*a, *p| {
        if (sample_rate == 0) sample_rate = a[0].sample_rate;
        if (a[0].sample_rate != sample_rate or a[1].sample_rate != sample_rate)
            return fail(out, "batch mode requires every file to share one sample rate");
        p.* = .{ .ref = a[0].samples, .deg = a[1].samples };
    }

    const results = try allocator.alloc(anyerror!visqol.Result, pairs.len);
    defer allocator.free(results);
    try engine.measureBatch(pairs, sample_rate, threads, results);
    defer for (results) |*r| {
        if (r.*) |*res| res.deinit() else |_| {}
    };

    var csv_out: std.ArrayList(u8) = .empty;
    defer csv_out.deinit(allocator);
    try csv_out.appendSlice(allocator, "reference,degraded,moslqo\n");
    for (names.items, results) |n, r| {
        if (r) |res| {
            try out.print("{s} {s} MOS-LQO: {d:.6}\n", .{ n[0], n[1], res.moslqo });
            const line = try std.fmt.allocPrint(allocator, "{s},{s},{d}\n", .{ n[0], n[1], res.moslqo });
            defer allocator.free(line);
            try csv_out.appendSlice(allocator, line);
        } else |e| {
            try out.print("{s} {s} error: {s}\n", .{ n[0], n[1], @errorName(e) });
        }
    }
    if (results_csv) |p| try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = csv_out.items });
}

/// `threads` 0: all cores.
fn loadAll(allocator: std.mem.Allocator, names: []const [2][]const u8, audios: [][2]audio.Audio, errs: []?anyerror, threads: u32) !void {
    const Loader = struct {
        allocator: std.mem.Allocator,
        names: []const [2][]const u8,
        audios: [][2]audio.Audio,
        errs: []?anyerror,
        next: std.atomic.Value(usize) = .init(0),

        fn run(l: *@This()) void {
            while (true) {
                const i = l.next.fetchAdd(1, .monotonic);
                if (i >= l.names.len) return;
                l.errs[i] = null;
                const ref = audio.loadAsMono(l.allocator, l.names[i][0]) catch |e| {
                    l.errs[i] = e;
                    continue;
                };
                const deg = audio.loadAsMono(l.allocator, l.names[i][1]) catch |e| {
                    var r = ref;
                    r.deinit();
                    l.errs[i] = e;
                    continue;
                };
                l.audios[i] = .{ ref, deg };
            }
        }
    };
    var loader: Loader = .{ .allocator = allocator, .names = names, .audios = audios, .errs = errs };
    const want: usize = if (threads == 0) std.Thread.getCpuCount() catch 1 else threads;
    const spawn = @min(want, names.len) -| 1;
    const pool = try allocator.alloc(std.Thread, spawn);
    defer allocator.free(pool);
    var started: usize = 0;
    defer for (pool[0..started]) |t| t.join();
    for (pool) |*t| {
        t.* = std.Thread.spawn(.{}, Loader.run, .{&loader}) catch break;
        started += 1;
    }
    loader.run();
}

fn printResult(out: *std.Io.Writer, rp: []const u8, dp: []const u8, r: *const visqol.Result, verbose: bool) !void {
    try out.print("Reference Filepath:\t{s}\nDegraded Filepath:\t{s}\nMOS-LQO:\t\t{d:.6}\n", .{ rp, dp, r.moslqo });
    if (!verbose) return;
    try out.print("VNSIM:\t\t\t{d:.6}\nAlignment lag (s):\t{d:.6}\n", .{ r.vnsim, r.alignment_lag_s });
    try out.writeAll("\n  band    freq (Hz)    fvnsim  fvnsim10  fstdnsim  fvdegenergy\n");
    for (0..r.fvnsim.len) |b| {
        try out.print("  {d:>4} {d:>12.2} {d:>9.6} {d:>9.6} {d:>9.6} {d:>12.6}\n", .{ b, r.center_freq_bands[b], r.fvnsim[b], r.fvnsim10[b], r.fstdnsim[b], r.fvdegenergy[b] });
    }
    try out.writeAll("\n  patch  ref_start  ref_end  deg_start  deg_end  similarity\n");
    for (r.patch_sims, 0..) |p, k| {
        try out.print("  {d:>5} {d:>10.4} {d:>8.4} {d:>10.4} {d:>8.4} {d:>11.6}\n", .{ k, p.ref_patch_start_time, p.ref_patch_end_time, p.deg_patch_start_time, p.deg_patch_end_time, p.similarity });
    }
}

fn fail(out: *std.Io.Writer, msg: []const u8) !void {
    try out.print("error: {s}\n", .{msg});
    try out.flush();
    std.process.exit(1);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
