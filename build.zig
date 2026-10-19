//! zig build develop         build the test extension `setu_classes` (+ its stubs) into test/
//! zig build test            run the unit tests
//!
//! Options:
//!   -Dfree-threaded=false   build the test extension for the regular (GIL) 3.15 instead of 3.15t
//!   -Dext-suffix=...        Python extension suffix (default: CPython's `EXT_SUFFIX` for the target and ABI)
//!   -Dstrip                 drop debug info from the test extension
//!
//! Other projects use it as a dependency: `b.dependency("setu", .{})`, then `.module("setu")`.
//! Their `build.zig` can also `@import("setu")` for `addSetuBuildSteps` (keeping their copy of
//! `tools/setu_build.py`, the wheel build backend, the same as Setu's) and `defaultSuffix`.
//! The test extension and its stubs are the named lazy paths `setu_classes` / `setu_classes.pyi`
//! (`test/wheel/` packages them with `tools/setu_build.py`, for `tools/check.sh`).

const std = @import("std");

/// Declares the `setu` module and the `develop` and `test` steps (see the top of this file).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // `-Doptimize=...` (default Debug), so a dependent build can pass `.optimize` (`test/wheel/`).
    const optimize = b.standardOptimizeOption(.{});
    const free_threaded = b.option(bool, "free-threaded", "Build for free-threaded 3.15t (default: true)") orelse
        true;
    const ext_suffix = b.option([]const u8, "ext-suffix", "Python extension module suffix") orelse
        defaultSuffix(b, target.result, free_threaded);
    const strip = b.option(bool, "strip", "Strip debug symbols from the test extension") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "free_threaded", free_threaded);

    // No target / optimize: the module takes them from whatever compiles it (extension, host program, test).
    const setu = b.addModule("setu", .{ .root_source_file = b.path("src/setu.zig") });

    // `setu_classes`: a test-only extension using every `setu.Class` hook (`test/`), and its stubs.
    const setu_test = b.addLibrary(.{
        .name = "setu_classes",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/setu_classes.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
            .imports = &.{
                .{ .name = "setu", .module = setu },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    setu_test.linker_allow_shlib_undefined = true;
    const setu_stubgen = b.addExecutable(.{
        .name = "setu_stubgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/stubgen.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "setu", .module = setu }},
        }),
    });
    const setu_pyi = b.addRunArtifact(setu_stubgen).captureStdOut(.{ .basename = "setu_classes.pyi" });
    b.addNamedLazyPath("setu_classes", setu_test.getEmittedBin());
    b.addNamedLazyPath("setu_classes.pyi", setu_pyi);
    const test_dir: std.Build.InstallDir = .{ .custom = "../test" };
    const develop = b.step("develop", "Build the test extension and its stubs into test/");
    develop.dependOn(&b.addInstallFileWithDir(
        setu_test.getEmittedBin(),
        test_dir,
        b.fmt("setu_classes{s}", .{ext_suffix}),
    ).step);
    develop.dependOn(&b.addInstallFileWithDir(setu_pyi, test_dir, "setu_classes.pyi").step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/setu.zig"),
        .target = b.graph.host,
    }) });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}

/// Adds two steps to a project that keeps a copy of Setu's `tools/setu_build.py` (the wheel build
/// backend) in its own `tools/`: `setu-build-check` (fails unless the copy is the pinned Setu's)
/// and `setu-build-sync` (writes the pinned Setu's over it, after a Setu bump).
///
/// Example
///     >>> // the project's build.zig (`setu` in its build.zig.zon)
///     >>> const setu_dep = b.dependency("setu", .{});
///     >>> @import("setu").addSetuBuildSteps(b, setu_dep);
///     $ zig build setu-build-sync    # tools/setu_build.py = the pinned Setu's
///     $ zig build setu-build-check   # in tools/check.sh: `cmp` fails if they differ
pub fn addSetuBuildSteps(b: *std.Build, setu_dep: *std.Build.Dependency) void {
    const script = setu_dep.path("tools/setu_build.py");
    const same = b.addSystemCommand(&.{"cmp"});
    same.addFileArg(script);
    same.addFileArg(b.path("tools/setu_build.py"));
    b.step("setu-build-check", "Check that tools/setu_build.py is the pinned Setu's copy").dependOn(&same.step);
    const sync = b.addUpdateSourceFiles();
    sync.addCopyFileToSource(script, "tools/setu_build.py");
    b.step("setu-build-sync", "Copy the pinned Setu's tools/setu_build.py into tools/").dependOn(&sync.step);
}

/// CPython's `EXT_SUFFIX` for `target`, like `.cpython-315t-x86_64-linux-gnu.so`.
pub fn defaultSuffix(b: *std.Build, target: std.Target, free_threaded: bool) []const u8 {
    const libc = if (target.abi.isMusl()) "musl" else "gnu";
    return b.fmt(".cpython-315{s}-{s}-linux-{s}.so", .{
        if (free_threaded) "t" else "",
        @tagName(target.cpu.arch),
        libc,
    });
}
