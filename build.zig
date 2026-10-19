// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const zimt = @import("zimt");

const version = "0.1.0";

pub fn build(b: *std.Build) void {
    // Default to the oldest macOS the Metal kernels support, for portable binaries.
    const target = b.standardTargetOptions(.{ .default_target = if (@import("builtin").os.tag == .macos)
        .{ .os_version_min = .{ .semver = std.SemanticVersion.parse(zimt.metal_min_macos ++ ".0") catch unreachable } }
    else
        .{} });
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from the library and CLI");
    const os = target.result.os.tag;

    const metal_opt = b.option(bool, "metal", "Build the Metal GPU backend (needs the Xcode Metal Toolchain; default: on when macOS and the toolchain works)");
    const enable_cuda = b.option(bool, "cuda", "Build the CUDA GPU backend (needs slangc with NVRTC at build time, libcuda at run time)") orelse false;
    const enable_vulkan = b.option(bool, "vulkan", "Build the Vulkan GPU backend (fetches the Vulkan headers at build time; loads the Vulkan loader at run time)") orelse false;
    const enable_metal = zimt.resolveMetal(b, metal_opt, os);

    const zimt_dep = b.dependency("zimt", .{ .target = target, .metal = enable_metal, .cuda = enable_cuda, .vulkan = enable_vulkan });
    const zimt_mod = zimt_dep.module("zimt");
    const kernels_mod = zimt.addKernels(b, .{
        .zimt = zimt_dep,
        .sources = b.path("src/gpu"),
        .generated = b.path("src/gpu/generated"),
        .entries = &kernels,
        .metal = enable_metal,
        .cuda = enable_cuda,
        .vulkan = enable_vulkan,
    });
    b.step("shaders", "Regenerate src/gpu/generated/ (MSL, SPIR-V + reflection) from the Slang sources (needs slangc, spirv-val)").dependOn(zimt.addRegenerate(b, .{
        .zimt = zimt_dep,
        .sources = b.path("src/gpu"),
        .generated_dir = "src/gpu/generated",
        .entries = &kernels,
    }));

    const options = b.addOptions();
    options.addOption([:0]const u8, "version", version);
    options.addOption(bool, "metal", enable_metal);
    options.addOption(bool, "cuda", enable_cuda);
    options.addOption(bool, "vulkan", enable_vulkan);
    options.addOption(u32, "gammatone_lanes", b.option(u32, "gammatone-lanes", "Frames filtered per SIMD vector in the CPU gammatone (default: per target)") orelse 0);

    // Default models embedded so the library needs no data files.
    const lattice_model = "lattice_tcditugenmeetpackhref_ls2_nl60_lr12_bs2048_learn.005_ep2400_train1_7_raw.tflite";
    const model_files = b.addWriteFiles();
    _ = model_files.addCopyFile(b.path("src/model/libsvm_nu_svr_model.txt"), "libsvm_nu_svr_model.txt");
    _ = model_files.addCopyFile(b.path("src/model/" ++ lattice_model), lattice_model);
    const model_zig = model_files.add("default_model.zig", "pub const svr = @embedFile(\"libsvm_nu_svr_model.txt\");\n" ++
        "pub const lattice = @embedFile(\"" ++ lattice_model ++ "\");\n");

    const Ctx = struct {
        opts: *std.Build.Step.Options,
        model: std.Build.LazyPath,
        zimt: *std.Build.Module,
        kernels: *std.Build.Module,
    };
    const cfg: Ctx = .{ .opts = options, .model = model_zig, .zimt = zimt_mod, .kernels = kernels_mod };
    const configure = struct {
        fn f(m: *std.Build.Module, c: Ctx, _: std.Build.LazyPath) void {
            m.addOptions("build_options", c.opts);
            m.addAnonymousImport("default_model", .{ .root_source_file = c.model });
            m.addImport("zimt", c.zimt);
            m.addImport("visqol_kernels", c.kernels);
        }
    }.f;

    const mod = b.addModule("visqol", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    configure(mod, cfg, model_zig);

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .strip = strip,
        // Loaded into foreign processes: worker threads must come from the
        // host's libc, or its TLS breaks on them.
        .link_libc = if (os == .windows) null else true,
    });
    configure(lib_mod, cfg, model_zig);

    const shared = b.addLibrary(.{ .name = "visqol", .linkage = .dynamic, .root_module = lib_mod, .version = std.SemanticVersion.parse(version) catch unreachable });
    const static = b.addLibrary(.{ .name = "visqol", .linkage = .static, .root_module = lib_mod });
    b.installArtifact(shared);
    b.installArtifact(static);
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("src/include/visqol.h"), "visqol.h").step);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    configure(exe_mod, cfg, model_zig);
    const exe = b.addExecutable(.{ .name = "visqol", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the visqol CLI").dependOn(&run.step);

    const py = b.step("python", "Copy the shared library into src/python/visqol/_lib");
    const install_py = b.addInstallFileWithDir(shared.getEmittedBin(), .{ .custom = "../src/python/visqol/_lib" }, sharedName(os));
    py.dependOn(&install_py.step);

    const pb2 = b.addUpdateSourceFiles();
    const gen_pb2 = b.addSystemCommand(&.{ "uv", "run", "-q", "--no-project", "--with", "grpcio-tools", "python" });
    gen_pb2.addFileArg(b.path("src/python/gen_pb2.py"));
    for ([_][]const u8{ "visqol_config", "similarity_result" }) |n| {
        gen_pb2.addFileArg(b.path(b.fmt("src/cpp/proto/{s}.proto", .{n})));
        pb2.addCopyFileToSource(gen_pb2.addOutputFileArg(b.fmt("{s}_pb2.py", .{n})), b.fmt("src/python/visqol/pb2/{s}_pb2.py", .{n}));
    }
    b.step("pb2", "Regenerate src/python/visqol/pb2 from src/cpp/proto (needs uv)").dependOn(&pb2.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    configure(test_mod, cfg, model_zig);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    // Results depend on the GPUs present and ZIMT_* variables.
    run_tests.has_side_effects = enable_metal or enable_cuda or enable_vulkan;
    b.step("test", "Run unit + conformance tests (conformance needs tests/fetch_data.sh)").dependOn(&run_tests.step);
}

fn sharedName(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .macos, .ios => "libvisqol.dylib",
        .windows => "visqol.dll",
        else => "libvisqol.so",
    };
}

const kernels = [_]zimt.Entry{
    // f32 only: the FFT lag search, and the hybrid path's DP similarities.
    .{ .name = "ref_stats" },
    .{ .name = "patch_sims" },
    .{ .name = "fft_radix2", .source = "fft", .entry = "fft_pass<Radix2>" },
    .{ .name = "fft_radix4", .source = "fft", .entry = "fft_pass<Radix4>" },
    .{ .name = "fft_radix16", .source = "fft", .entry = "fft_pass<Radix16>" },
    .{ .name = "xcorr_spectrum" },
    .{ .name = "lag_pack" },
    .{ .name = "lag_max" },
    .{ .name = "lag_cands" },
    .{ .name = "lag_first" },
    .{ .name = "lag_fast_pick", .source = "lag_first" },
    // f64 only.
    .{ .name = "lag_rescore", .float64 = true, .precise = true },
    .{ .name = "lag_pick", .source = "lag_rescore", .float64 = true, .precise = true },
    .{ .name = "to_f32", .source = "envelope", .float64 = true, .precise = true, .defines = &.{ "REAL=double", "EXACT=1", "BALANCED=0" } },
} ++ real(.{ "env_sums", "env_reduce", "env_nyq", "env_write", "lag_params" }, "envelope") ++
    real(.{"gammatone_frames"}, "gammatone_frames") ++
    real(.{"gammatone_patches"}, "gammatone_patches") ++
    real(.{"spec_prep"}, "spec_prep") ++
    real(.{ "deg_plane", "ref_terms", "nsim_table", "nsim_bands" }, "nsim") ++
    real(.{ "dp_search", "match_rows", "match_finalize" }, "dp") ++
    real(.{ "spl_energy", "apply_lag" }, "pre") ++
    real(.{ "realign_rows", "realign_frames", "realign_accept" }, "realign") ++
    balanced(.{ .{ "gammatone_frames", "gammatone_frames" }, .{ "gammatone_patches", "gammatone_patches" }, .{ "apply_lag", "pre" }, .{ "spec_prep", "spec_prep" }, .{ "nsim_bands", "nsim" } });

/// `<name>_bal`: f32 kernels in two-float arithmetic (df.slang), the
/// balanced build; `.{ name, source }`.
fn balanced(comptime names: anytype) [names.len]zimt.Entry {
    var out: [names.len]zimt.Entry = undefined;
    for (names, &out) |n, *e| e.* = .{ .name = n[0] ++ "_bal", .source = n[1], .entry = n[0], .precise = true, .defines = &.{ "REAL=float", "EXACT=0", "BALANCED=1" } };
    return out;
}

/// `<name>_f64`, CPU-exact (`EXACT`, no FMA contraction), and `<name>_f32`,
/// the fast build, of one source with `REAL` double and float.
fn real(comptime names: anytype, comptime source: []const u8) [names.len * 2]zimt.Entry {
    var out: [names.len * 2]zimt.Entry = undefined;
    for (names, 0..) |name, i| {
        out[2 * i] = .{ .name = name ++ "_f64", .source = source, .entry = name, .float64 = true, .precise = true, .defines = &.{ "REAL=double", "EXACT=1", "BALANCED=0" } };
        out[2 * i + 1] = .{ .name = name ++ "_f32", .source = source, .entry = name, .defines = &.{ "REAL=float", "EXACT=0", "BALANCED=0" } };
    }
    return out;
}
