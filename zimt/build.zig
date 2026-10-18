// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! zimt runtime module, `zimt-bindgen`, and build helpers for dependents:
//!
//!   const zimt_build = @import("zimt");
//!   const metal = zimt_build.resolveMetal(b, b.option(bool, "metal", "..."), target.result.os.tag);
//!   const dep = b.dependency("zimt", .{ .target = target, .metal = metal });
//!   const kernels = zimt_build.addKernels(b, .{ .zimt = dep, .sources = b.path("shaders"),
//!       .generated = b.path("shaders/generated"), .entries = &.{.{ .name = "saxpy" }}, .metal = metal });
//!   b.step("shaders", "...").dependOn(zimt_build.addRegenerate(b, .{ ... }));
//!
//! slangc is needed only for `addRegenerate` and CUDA; Metal builds need only Xcode's Metal toolchain.
//! CUDA and Vulkan builds fetch their API headers (lazy package dependencies, for translate-c).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const metal = b.option(bool, "metal", "Metal backend (default: on when macOS and the Metal toolchain works)") orelse
        resolveMetal(b, null, os);
    const cuda = b.option(bool, "cuda", "CUDA backend (loads libcuda at run time)") orelse false;
    const vulkan = b.option(bool, "vulkan", "Vulkan backend (loads the Vulkan loader at run time)") orelse false;
    if ((vulkan or cuda) and target.result.abi.isMusl())
        std.process.fatal("-D{s}: musl binaries cannot dlopen the system's (glibc) GPU drivers", .{if (cuda) "cuda" else "vulkan"});

    const opts = b.addOptions();
    opts.addOption(bool, "metal", metal);
    opts.addOption(bool, "cuda", cuda);
    opts.addOption(bool, "vulkan", vulkan);
    // No target or optimize mode: the module takes the importer's, which must
    // pass the same `target` here for translate-c.
    const mod = b.addModule("zimt", .{ .root_source_file = b.path("src/root.zig") });
    mod.addOptions("zimt_options", opts);
    const vulkan_c = if (vulkan) translateHeaders(b, target, "vulkan_headers",
        \\#define VK_NO_PROTOTYPES
        \\#include <vulkan/vulkan_core.h>
        \\
    ) else null;
    const cuda_c = if (cuda) translateHeaders(b, target, "cuda_headers",
        \\#include <cuda.h>
        \\#include <cudaTypedefs.h>
        \\
    ) else null;
    if (vulkan_c) |m| mod.addImport("vulkan_c", m);
    if (cuda_c) |m| mod.addImport("cuda_c", m);
    if (metal) {
        // Zig's own SDK detection fails under nix.
        switch (runXcrun(b, &.{ "-sdk", "macosx", "--show-sdk-path" })) {
            .ok => |sdk| {
                mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
                mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
                mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
            },
            .failed => |why| std.log.warn("macOS SDK not found ({s}); relying on Zig's own SDK detection", .{why}),
        }
        mod.addCSourceFile(.{ .file = b.path("src/metal/bridge.m"), .flags = &.{"-fobjc-arc"} });
        mod.link_libc = true;
        linkSystemLib(mod, "objc");
        mod.linkFramework("Metal", .{});
        mod.linkFramework("Foundation", .{});
    }
    // dlopen() and getenv() need libc.
    if (cuda or vulkan) mod.link_libc = true;

    const bindgen = b.addExecutable(.{
        .name = "zimt-bindgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bindgen.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    b.installArtifact(bindgen);

    const test_step = b.step("test", "Run zimt's tests");
    const unit_mod = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    unit_mod.addOptions("zimt_options", opts);
    if (vulkan_c) |m| unit_mod.addImport("vulkan_c", m);
    if (cuda_c) |m| unit_mod.addImport("cuda_c", m);
    if (cuda or vulkan) unit_mod.link_libc = true;
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = unit_mod })).step);
    const test_kernels = kernelsModule(b, bindgen, mod, b.path("src/slang"), .{
        .sources = b.path("test"),
        .generated = b.path("test/generated"),
        .entries = &test_entries,
        .metal = metal,
        .cuda = cuda,
        .vulkan = vulkan,
    });
    const e2e_mod = b.createModule(.{ .root_source_file = b.path("test/dispatch_test.zig"), .target = target, .optimize = optimize });
    e2e_mod.addImport("zimt", mod);
    e2e_mod.addImport("test_kernels", test_kernels);
    const e2e = b.addRunArtifact(b.addTest(.{ .root_module = e2e_mod }));
    // Results depend on the GPUs present and ZIMT_* variables.
    e2e.has_side_effects = metal or cuda or vulkan;
    test_step.dependOn(&e2e.step);
    b.step("shaders", "Regenerate test/generated/ from test/*.slang (needs slangc)").dependOn(addRegenerate(b, .{
        .sources = b.path("test"),
        .generated_dir = "test/generated",
        .entries = &test_entries,
    }));
}

const test_entries = [_]Entry{
    .{ .name = "saxpy" },
    .{ .name = "scale3" },
    .{ .name = "compact", .source = "indirect" },
    .{ .name = "plan", .source = "indirect" },
    .{ .name = "scale_listed", .source = "indirect" },
};

/// Null until the lazy dependency is fetched.
fn translateHeaders(b: *std.Build, target: std.Build.ResolvedTarget, dep_name: []const u8, source: []const u8) ?*std.Build.Module {
    const dep = b.lazyDependency(dep_name, .{}) orelse return null;
    const header = b.addWriteFiles().add(b.fmt("{s}.h", .{dep_name}), source);
    const tc = b.addTranslateC(.{ .root_source_file = header, .target = target, .optimize = .ReleaseFast });
    tc.addIncludePath(dep.path("include"));
    return tc.createModule();
}

/// `Module.linkSystemLibrary` without its libc-name check, which needs a
/// known target; the zimt module takes its target from the importer.
fn linkSystemLib(m: *std.Build.Module, name: []const u8) void {
    m.link_objects.append(m.owner.allocator, .{ .system_lib = .{
        .name = name,
        .needed = false,
        .weak = false,
        .use_pkg_config = .no,
        .preferred_link_mode = .dynamic,
        .search_strategy = .paths_first,
    } }) catch @panic("OOM");
}

/// A kernel named `name`: entry point `entry` (default `name`; a generic
/// one with its arguments, `fft_pass<Radix16>`) of `<source>.slang` (default
/// `<name>.slang`).
pub const Entry = struct {
    name: []const u8,
    source: ?[]const u8 = null,
    entry: ?[]const u8 = null,

    fn file(e: Entry) []const u8 {
        return e.source orelse e.name;
    }

    fn entryPoint(e: Entry) []const u8 {
        return e.entry orelse e.name;
    }
};

pub const Kernels = struct {
    /// `b.dependency("zimt", ...)`; unused inside zimt's own build.
    zimt: *std.Build.Dependency = undefined,
    /// Directory of `<source>.slang` files; also the include path, with zimt's
    /// own `src/slang`.
    sources: std.Build.LazyPath,
    /// From `addRegenerate`.
    generated: std.Build.LazyPath,
    entries: []const Entry,
    metal: bool,
    cuda: bool = false,
    vulkan: bool = false,
    /// Oldest macOS the `.metallib`s load on.
    macos_min: []const u8 = metal_min_macos,
    fast_math: bool = false,
};

/// Module with one binding per entry point, embedding a `.metallib` (from
/// the checked-in MSL), PTX (via slangc) and/or the checked-in SPIR-V per
/// enabled backend.
pub fn addKernels(b: *std.Build, k: Kernels) *std.Build.Module {
    return kernelsModule(b, k.zimt.artifact("zimt-bindgen"), k.zimt.module("zimt"), k.zimt.path("src/slang"), k);
}

fn kernelsModule(b: *std.Build, bindgen: *std.Build.Step.Compile, zimt: *std.Build.Module, slang_dir: std.Build.LazyPath, k: Kernels) *std.Build.Module {
    const wf = b.addWriteFiles();
    const sources = slangOnly(b, k.sources);
    const gen = b.addRunArtifact(bindgen);
    const bindings = gen.addOutputFileArg("kernels.zig");
    gen.addArgs(&.{ if (k.metal) "1" else "0", if (k.cuda) "1" else "0", if (k.vulkan) "1" else "0" });
    for (k.entries) |entry| {
        const e = entry.name;
        gen.addArg(e);
        gen.addFileArg(k.generated.path(b, b.fmt("{s}.json", .{e})));
        gen.addFileArg(k.generated.path(b, b.fmt("{s}.spirv.json", .{e})));
        gen.addFileArg(k.generated.path(b, b.fmt("{s}.spv", .{e})));
        if (k.vulkan) _ = wf.addCopyFile(k.generated.path(b, b.fmt("{s}.spv", .{e})), b.fmt("{s}.spv", .{e}));
        if (k.metal) {
            const run = b.addSystemCommand(&(xcrun_metal ++ .{
                if (k.fast_math) "-ffast-math" else "-fno-fast-math",
                b.fmt("-mmacosx-version-min={s}", .{k.macos_min}),
                "-o",
            }));
            for (xcrun_unset_env) |key| run.removeEnvironmentVariable(key);
            const lib = run.addOutputFileArg(b.fmt("{s}.metallib", .{e}));
            run.addFileArg(k.generated.path(b, b.fmt("{s}.metal", .{e})));
            _ = wf.addCopyFile(lib, b.fmt("{s}.metallib", .{e}));
        }
        if (k.cuda) {
            const run = b.addSystemCommand(&.{ "slangc", "-target", "ptx", "-line-directive-mode", "none", "-entry", entry.entryPoint(), "-I" });
            run.addDirectoryArg(sources);
            run.addArg("-I");
            run.addDirectoryArg(slang_dir);
            run.addFileArg(sources.path(b, b.fmt("{s}.slang", .{entry.file()})));
            run.addArg("-o");
            const ptx = run.addOutputFileArg(b.fmt("{s}.ptx", .{e}));
            _ = wf.addCopyFile(ptx, b.fmt("{s}.ptx", .{e}));
        }
    }
    const root = wf.addCopyFile(bindings, "kernels.zig");
    const mod = b.createModule(.{ .root_source_file = root });
    mod.addImport("zimt", zimt);
    return mod;
}

pub const Regenerate = struct {
    /// `b.dependency("zimt", ...)`; unused inside zimt's own build.
    zimt: ?*std.Build.Dependency = null,
    sources: std.Build.LazyPath,
    /// Relative to the build root.
    generated_dir: []const u8,
    entries: []const Entry,
};

/// Rewrites the checked-in MSL, SPIR-V and reflection (needs slangc and
/// spirv-val).
pub fn addRegenerate(b: *std.Build, r: Regenerate) *std.Build.Step {
    const update = b.addUpdateSourceFiles();
    const sources = slangOnly(b, r.sources);
    const slang_dir = if (r.zimt) |d| d.path("src/slang") else b.path("src/slang");
    for (r.entries) |entry| {
        const e = entry.name;
        const run = b.addSystemCommand(&.{ "slangc", "-target", "metal", "-line-directive-mode", "none", "-entry", entry.entryPoint(), "-I" });
        run.addDirectoryArg(sources);
        run.addArg("-I");
        run.addDirectoryArg(slang_dir);
        run.addFileArg(sources.path(b, b.fmt("{s}.slang", .{entry.file()})));
        run.addArg("-o");
        const msl = run.addOutputFileArg(b.fmt("{s}.metal", .{e}));
        run.addArg("-reflection-json");
        const json = run.addOutputFileArg(b.fmt("{s}.json", .{e}));
        update.addCopyFileToSource(msl, b.fmt("{s}/{s}.metal", .{ r.generated_dir, e }));
        update.addCopyFileToSource(json, b.fmt("{s}/{s}.json", .{ r.generated_dir, e }));

        const vk = b.addSystemCommand(&.{ "slangc", "-target", "spirv", "-line-directive-mode", "none", "-entry", entry.entryPoint(), "-I" });
        vk.addDirectoryArg(sources);
        vk.addArg("-I");
        vk.addDirectoryArg(slang_dir);
        vk.addFileArg(sources.path(b, b.fmt("{s}.slang", .{entry.file()})));
        vk.addArg("-o");
        const spv = vk.addOutputFileArg(b.fmt("{s}.spv", .{e}));
        vk.addArg("-reflection-json");
        const vk_json = vk.addOutputFileArg(b.fmt("{s}.spirv.json", .{e}));
        const val = b.addSystemCommand(&.{ "spirv-val", "--target-env", "vulkan1.2" });
        val.addFileArg(spv);
        update.step.dependOn(&val.step);
        update.addCopyFileToSource(spv, b.fmt("{s}/{s}.spv", .{ r.generated_dir, e }));
        update.addCopyFileToSource(vk_json, b.fmt("{s}/{s}.spirv.json", .{ r.generated_dir, e }));
    }
    return &update.step;
}

/// Only `*.slang`, so neighbouring files don't invalidate slangc runs.
fn slangOnly(b: *std.Build, dir: std.Build.LazyPath) std.Build.LazyPath {
    return b.addWriteFiles().addCopyDirectory(dir, "", .{ .include_extensions = &.{".slang"} });
}

pub const metal_min_macos = "13.0";

/// System xcrun: nix shells put xcbuild's xcrun first and point
/// DEVELOPER_DIR/SDKROOT at an SDK without the Metal compiler.
const xcrun_metal = [_][]const u8{ "/usr/bin/xcrun", "-sdk", "macosx", "metal" };
const xcrun_unset_env = [_][]const u8{ "DEVELOPER_DIR", "SDKROOT" };

/// Guards against a `metal` wrapper on PATH that re-invokes xcrun and recurses.
const xcrun_timeout_ms = 10_000;

/// `true` fails the build if the toolchain is broken; null enables Metal only if it works.
pub fn resolveMetal(b: *std.Build, requested: ?bool, os: std.Target.Os.Tag) bool {
    if (requested == false) return false;
    if (os != .macos) {
        if (requested == true) std.process.fatal("-Dmetal requires a macOS target", .{});
        return false;
    }
    if (@import("builtin").os.tag != .macos) {
        if (requested == true) std.process.fatal("-Dmetal needs a macOS host to compile shaders (xcrun metal)", .{});
        return false;
    }
    const problem = probeMetal(b) orelse return true;
    if (requested == true) std.process.fatal(
        "-Dmetal: the Metal shader compiler does not work: {s}\n" ++
            "Install it with `xcodebuild -downloadComponent MetalToolchain`, or build with -Dmetal=false.",
        .{problem},
    );
    std.log.warn("Metal backend disabled ({s}); `xcodebuild -downloadComponent MetalToolchain` enables it, -Dmetal=false silences this", .{problem});
    return false;
}

/// The child gets its own process group, killed whole on timeout.
const XcrunResult = union(enum) { ok: []const u8, failed: []const u8 };

fn runXcrun(b: *std.Build, args: []const []const u8) XcrunResult {
    // Comptime-dead elsewhere: the build runner links libc only on macOS.
    return if (@import("builtin").os.tag == .macos) runXcrunMacos(b, args) else .{ .failed = "xcrun needs a macOS host" };
}

fn runXcrunMacos(b: *std.Build, args: []const []const u8) XcrunResult {
    const io = b.graph.io;
    var env = b.graph.environ_map.clone(b.allocator) catch @panic("OOM");
    for (xcrun_unset_env) |k| _ = env.swapRemove(k);
    const argv = std.mem.concat(b.allocator, []const u8, &.{ &.{"/usr/bin/xcrun"}, args }) catch @panic("OOM");
    const child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |e| return .{ .failed = b.fmt("cannot run xcrun: {t}", .{e}) };
    const pid = child.id.?;
    const cmd = std.mem.join(b.allocator, " ", args) catch @panic("OOM");

    var status: c_int = 0;
    var waited: u32 = 0;
    while (true) {
        const r = std.c.waitpid(pid, &status, 1); // WNOHANG
        if (r == pid) break;
        if (r < 0) return .{ .failed = "waitpid failed" };
        if (waited >= xcrun_timeout_ms) {
            _ = std.c.kill(-pid, .KILL);
            _ = std.c.waitpid(pid, &status, 0);
            return .{ .failed = b.fmt("`xcrun {s}` did not finish within {d} s (a `metal` wrapper on PATH re-invoking xcrun?)", .{ cmd, xcrun_timeout_ms / 1000 }) };
        }
        io.sleep(.fromMilliseconds(20), .awake) catch {};
        waited += 20;
    }
    // Output fits in the pipe buffer.
    var buf: [4096]u8 = undefined;
    const exited_ok = status & 0x7f == 0 and (status >> 8) & 0xff == 0;
    const pipe = if (exited_ok) child.stdout.? else child.stderr.?;
    var reader = pipe.readerStreaming(io, &.{});
    const n = reader.interface.readSliceShort(&buf) catch 0;
    const text = b.dupe(std.mem.trim(u8, buf[0..n], " \t\r\n"));
    if (exited_ok) return .{ .ok = text };
    return .{ .failed = if (text.len > 0) text else b.fmt("`xcrun {s}` failed", .{cmd}) };
}

/// Null if `xcrun metal` works, else why not.
fn probeMetal(b: *std.Build) ?[]const u8 {
    return switch (runXcrun(b, &(xcrun_metal[1..].* ++ .{"--version"}))) {
        .ok => null,
        .failed => |why| why,
    };
}
