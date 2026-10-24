//! zig build develop         build the test extension `setu_classes` (+ its stubs) into test/
//! zig build test            type-check every declaration and run the comptime unit tests
//!
//! Options:
//!   -Dstrip                 drop debug info from the test extension
//!
//! One build serves CPython 3.14, 3.14t, 3.15, 3.15t and later: the extension is `<name>.so`
//! (`ext_suffix`), which every one of them imports (see `src/capi.zig`).
//!
//! Other projects use it as a dependency: `b.dependency("setu", .{})`, then `.module("setu")`.
//! Their `build.zig` can also `@import("setu")` for `addStubs` (the extension's `.pyi`, from its root
//! file's `module`), `addSetuBuildSteps` (keeping their copy of `tools/setu_build.py`, the wheel build
//! backend, the same as Setu's), `addSetuDocsSteps` (the same for `tools/setu_docs.py`, the documentation
//! site helpers) and `ext_suffix`.
//! The test extension and its stubs are the named lazy paths `setu_classes` / `setu_classes.pyi`
//! (`test/wheel/` packages them with `tools/setu_build.py`, for `tools/check.sh`).

const std = @import("std");

/// Declares the `setu` module and the `develop` and `test` steps (see the top of this file).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // `-Doptimize=...` (default Debug), so a dependent build can pass `.optimize` (`test/wheel/`).
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols from the test extension") orelse false;

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
            .imports = &.{.{ .name = "setu", .module = setu }},
        }),
    });
    setu_test.linker_allow_shlib_undefined = true;
    const setu_pyi = stubs(b, b.path("src/stubgen.zig"), setu, .{
        .root_source_file = b.path("test/setu_classes.zig"),
    });
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

    // Compiled, never linked or run: Setu's functions call libpython, which only the interpreter provides.
    // Analysis type-checks every declaration (`refAllDecls` in each file) and runs the unit tests, which
    // are comptime (`@compileError` on failure); with no binary requested, nothing is emitted.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/setu.zig"),
        .target = b.graph.host,
        .link_libc = true,
    }) });
    b.step("test", "Type-check every declaration and run the comptime unit tests").dependOn(&tests.step);
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
    addCopySteps(b, setu_dep, "setu_build.py", "setu-build");
}

/// Like `addSetuBuildSteps`, for a project that builds a documentation site with Setu's `tools/setu_docs.py`:
/// the steps `setu-docs-check` and `setu-docs-sync`.
///
/// Example
///     >>> @import("setu").addSetuDocsSteps(b, setu_dep);
///     $ zig build setu-docs-sync     # tools/setu_docs.py = the pinned Setu's
///     $ zig build setu-docs-check    # in tools/check.sh: `cmp` fails if they differ
pub fn addSetuDocsSteps(b: *std.Build, setu_dep: *std.Build.Dependency) void {
    addCopySteps(b, setu_dep, "setu_docs.py", "setu-docs");
}

/// The `<step>-check` / `<step>-sync` steps for `tools/<file>`.
fn addCopySteps(
    b: *std.Build,
    setu_dep: *std.Build.Dependency,
    comptime file: []const u8,
    comptime step: []const u8,
) void {
    const script = setu_dep.path("tools/" ++ file);
    const same = b.addSystemCommand(&.{"cmp"});
    same.addFileArg(script);
    same.addFileArg(b.path("tools/" ++ file));
    b.step(step ++ "-check", "Check that tools/" ++ file ++ " is the pinned Setu's copy").dependOn(&same.step);
    const sync = b.addUpdateSourceFiles();
    sync.addCopyFileToSource(script, "tools/" ++ file);
    b.step(step ++ "-sync", "Copy the pinned Setu's tools/" ++ file ++ " into tools/").dependOn(&sync.step);
}

/// What `addStubs` takes.
pub const StubsOptions = struct {
    /// The extension's root file: the one with `pub const module: setu.Module`.
    root_source_file: std.Build.LazyPath,
    /// The modules it (and the files it imports) imports besides `setu`, for the build host: the stub
    /// generator runs there, while the extension may be cross-compiled (`c`, `build_options`, ...).
    imports: []const std.Build.Module.Import = &.{},
};

/// The `.pyi` of an extension: Setu's stub generator (`src/stubgen.zig`), built for the build host with
/// the extension's root file as `ext`, writes `setu.stub.module` of its `module`. Install it, or put it
/// in a wheel, next to the extension.
///
/// Note
///     - It links libc (scanned files may reach `extern "c"` functions or `std.heap.c_allocator`) but
///       not libpython: it only reads `module` at comptime, and is built so that the code that comptime
///       data points to (`Module.methods`' trampolines, a function-pointer field default of a class)
///       is dropped unless `main` reaches it (LLVM, function / data sections, `--gc-sections`, no
///       debug info), so a root file needs no `setu.stubgen` checks for that.
///
/// Example
///     >>> // the project's build.zig (`setu` in its build.zig.zon)
///     >>> const setu_dep = b.dependency("setu", .{});
///     >>> const pyi = @import("setu").addStubs(b, setu_dep, .{
///     >>>     .root_source_file = b.path("src/liburing/root.zig"),
///     >>>     .imports = &.{.{ .name = "build_options", .module = options.createModule() }},
///     >>> });
///     >>> b.getInstallStep().dependOn(&b.addInstallFileWithDir(pyi, .lib, "liburing.pyi").step);
pub fn addStubs(b: *std.Build, setu_dep: *std.Build.Dependency, options: StubsOptions) std.Build.LazyPath {
    return stubs(b, setu_dep.path("src/stubgen.zig"), setu_dep.module("setu"), options);
}

/// `addStubs` with Setu's `src/stubgen.zig` and `setu` module given (Setu's own build has no dependency).
fn stubs(
    b: *std.Build,
    stubgen: std.Build.LazyPath,
    setu: *std.Build.Module,
    options: StubsOptions,
) std.Build.LazyPath {
    const ext = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = b.graph.host,
        .optimize = .debug,
        .strip = true,
        .link_libc = true,
        .imports = options.imports,
    });
    ext.addImport("setu", setu);
    const exe = b.addExecutable(.{
        .name = "setu_stubgen",
        .root_module = b.createModule(.{
            .root_source_file = stubgen,
            .target = b.graph.host,
            .optimize = .debug,
            .strip = true, // debug info would refer to the dropped code (and to `c.PyExc_*`)
            .link_libc = true,
            .imports = &.{ .{ .name = "setu", .module = setu }, .{ .name = "ext", .module = ext } },
        }),
    });
    // Drop what only comptime data refers to (the self-hosted backend and linker keep it), so no libpython
    // symbol is left undefined. Costs about what the default Debug build does.
    exe.use_llvm = true;
    exe.use_lld = true;
    exe.link_function_sections = true;
    exe.link_data_sections = true;
    exe.link_gc_sections = true;
    return b.addRunArtifact(exe).captureStdOut(.{ .basename = "stubs.pyi" });
}

/// The extension module's suffix: `<name>.so`, the one name CPython 3.14, 3.14t, 3.15, 3.15t and
/// later all import (`.abi3.so` is refused by 3.15t, `.abi3t.so` unknown to 3.14). The wheel is
/// tagged `cp314.cp315-abi3.abi3t.cp314t.cp315t` (`tools/setu_build.py`).
pub const ext_suffix = ".so";
