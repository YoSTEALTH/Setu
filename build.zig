//! zig build develop         build the test extension `setu_classes` (+ its stubs) into test/
//! zig build test            type-check every declaration, run the comptime unit tests and the tests of
//!                           tools/setu_docs_web.zig
//! zig build docs-web        the docs site's Wasm module (tools/setu_docs_web.zig) into zig-out/web/docs.wasm
//! zig build coverage        line coverage of the test extension under class_test.py (kcov; arguments
//!                           after `--` go to pytest)
//! zig build coverage-zig    line coverage of tools/setu_docs_web.zig's unit tests (kcov)
//! zig build profile         instructions per call of tools/bench.py's cases, per line (callgrind; needs
//!                           -Doptimize=fast -Dcpu=x86_64_v3; arguments after `--` go to check_profile.py)
//!
//! Options:
//!   -Dstrip                 drop debug info from the test extension
//!   -Dpython=<path>         the interpreter `coverage` runs pytest with, `profile` the cases (default python3)
//!
//! One build serves CPython 3.14, 3.14t, 3.15, 3.15t and later: the extension is `<name>.so`
//! (`ext_suffix`), which every one of them imports (see `src/capi.zig`).
//!
//! Other projects use it as a dependency: `b.dependency("setu", .{})`, then `.module("setu")`.
//! Their `build.zig` can also `@import("setu")` for `addStubs` (the extension's `.pyi`, from its root
//! file's `module`), `addSetuBuildSteps` (keeping their copy of `tools/setu_build.py`, the wheel build
//! backend, the same as Setu's), `addSetuDocsSteps` (the same for `tools/setu_docs.py`, the documentation
//! site builder, plus its `docs-web` step), `addSetuGuideSteps` (the same for `docs/setu-guide.md`, the guide
//! to writing an extension), `addCoverageSteps` (its `coverage` step: kcov over the project's pytest, by
//! `tools/check_coverage.py`), `addZigTestCoverage` (its `coverage-zig` step: kcov over Zig unit tests), `addProfileSteps` (its
//! `profile` step: callgrind over the project's cases, by `tools/check_profile.py`) and `ext_suffix`.
//! The test extension and its stubs are the named lazy paths `setu_classes` / `setu_classes.pyi`
//! (`test/wheel/` packages them with `tools/setu_build.py`, for `tools/check.sh`).

const std = @import("std");

/// Declares the `setu` module and the `develop`, `test` and `docs-web` steps (see the top of this file).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // `-Doptimize=...` (default Debug), so a dependent build can pass `.optimize` (`test/wheel/`).
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols from the test extension") orelse false;
    const python = b.option([]const u8, "python", "The interpreter for `coverage` and `profile`") orelse "python3";

    // No target / optimize: the module takes them from whatever compiles it (extension, host program, test).
    const setu = b.addModule("setu", .{ .root_source_file = b.path("src/root.zig") });

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
    coverage(b, b.path("tools/check_coverage.py"), setu_test, .{
        .module_name = "setu_classes",
        .include = &.{ b.path("src"), b.path("test") },
        .stub = setu_pyi, // `test_stub_matches_module` reads it next to the extension
        .python = python,
    });
    profile(b, b.path("tools/check_profile.py"), setu_test, .{
        .module_name = "setu_classes",
        .cases = b.path("tools/bench.py"),
        .python = python,
    });

    // Compiled, never linked or run: Setu's functions call libpython, which only the interpreter provides.
    // Analysis type-checks every declaration (`refAllDecls` in each file) and runs the unit tests, which
    // are comptime (`@compileError` on failure); with no binary requested, nothing is emitted.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .link_libc = true,
    }) });
    const test_step = b.step("test", "Type-check every declaration, run the comptime and docs-web unit tests");
    test_step.dependOn(&tests.step);

    // The docs site's Wasm module, for the fixture `test/docs/` (`tools/check_docs.py`), and its host tests.
    const web_source = b.path("tools/setu_docs_web.zig");
    docsWeb(b, web_source);
    const web_tests = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = web_source, .target = b.graph.host }),
    });
    test_step.dependOn(&b.addRunArtifact(web_tests).step);
    zigTestCoverage(b, b.path("tools/check_coverage.py"), web_tests, .{
        .include = &.{b.path("tools")},
        .python = python,
    });
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
    addCopySteps(b, setu_dep, "tools/setu_build.py", "setu-build");
}

/// Like `addSetuBuildSteps`, for a project that builds a documentation site with Setu's `tools/setu_docs.py`:
/// the steps `setu-docs-check` and `setu-docs-sync`, and `docs-web`, which builds the site's Wasm module
/// from the pinned Setu's `tools/setu_docs_web.zig` (`setu_docs.py` runs it; the Zig file is not copied).
///
/// Example
///     >>> @import("setu").addSetuDocsSteps(b, setu_dep);
///     $ zig build setu-docs-sync     # tools/setu_docs.py = the pinned Setu's
///     $ zig build setu-docs-check    # in tools/check.sh: `cmp` fails if they differ
///     $ zig build docs-web           # zig-out/web/docs.wasm
pub fn addSetuDocsSteps(b: *std.Build, setu_dep: *std.Build.Dependency) void {
    addCopySteps(b, setu_dep, "tools/setu_docs.py", "setu-docs");
    docsWeb(b, setu_dep.path("tools/setu_docs_web.zig"));
}

/// The `docs-web` step: `source` (`tools/setu_docs_web.zig`) as a wasm32 module with its `export fn`s,
/// installed as `web/docs.wasm` (`zig-out/web/docs.wasm`, or under `--prefix`).
fn docsWeb(b: *std.Build, source: std.Build.LazyPath) void {
    const web = b.addExecutable(.{
        .name = "docs",
        .root_module = b.createModule(.{
            .root_source_file = source,
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .small,
            .strip = true,
        }),
    });
    web.entry = .disabled;
    web.rdynamic = true; // keep the `export fn`s
    const step = b.step("docs-web", "Build the docs site's Wasm module into zig-out/web/docs.wasm");
    step.dependOn(&b.addInstallFileWithDir(web.getEmittedBin(), .{ .custom = "web" }, "docs.wasm").step);
}

/// Like `addSetuBuildSteps`, for Setu's guide to writing an extension (`docs/setu-guide.md`, what a session
/// working on the project's bindings reads): the steps `setu-guide-check` and `setu-guide-sync`.
///
/// Example
///     >>> @import("setu").addSetuGuideSteps(b, setu_dep);
///     $ zig build setu-guide-sync    # docs/setu-guide.md = the pinned Setu's
///     $ zig build setu-guide-check   # in tools/check.sh: `cmp` fails if they differ
pub fn addSetuGuideSteps(b: *std.Build, setu_dep: *std.Build.Dependency) void {
    addCopySteps(b, setu_dep, "docs/setu-guide.md", "setu-guide");
}

/// The `<step>-check` / `<step>-sync` steps for the project's copy of Setu's `path` (the same path there).
fn addCopySteps(
    b: *std.Build,
    setu_dep: *std.Build.Dependency,
    comptime path: []const u8,
    comptime step: []const u8,
) void {
    const original = setu_dep.path(path);
    const same = b.addSystemCommand(&.{"cmp"});
    same.addFileArg(original);
    same.addFileArg(b.path(path));
    b.step(step ++ "-check", "Check that " ++ path ++ " is the pinned Setu's copy").dependOn(&same.step);
    const sync = b.addUpdateSourceFiles();
    sync.addCopyFileToSource(original, path);
    b.step(step ++ "-sync", "Copy the pinned Setu's " ++ path ++ " into the project").dependOn(&sync.step);
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

/// What `addCoverageSteps` takes.
pub const CoverageOptions = struct {
    /// The name the tests import the extension by: `"setu_classes"`, `"liburing"` for a package's `__init__.so`
    /// (`package`), or `"pkg.ext"` for one inside a package (whose `from .ext import ...` then gets the coverage
    /// build).
    module_name: []const u8,
    /// The extension is its package's `__init__.so` (`liburing/__init__.so`): the coverage build is put there too,
    /// so it is imported as a package (`__path__`, its `__file__` in a `liburing/` directory).
    package: bool = false,
    /// The source directories to report: the extension's, and `setu_dep.path("src")` for Setu's code as the
    /// extension uses it.
    include: []const std.Build.LazyPath,
    /// The `.pyi` (`addStubs`), put next to the coverage build for tests that read it there.
    stub: ?std.Build.LazyPath = null,
    /// The interpreter that runs pytest (pytest installed).
    python: []const u8 = "python3",
    /// Fail when the total line coverage is lower (percent).
    min: ?f64 = null,
};

/// The step `coverage`: line coverage of the extension `ext`'s Zig code under the project's pytest, by kcov.
/// It runs Setu's `tools/check_coverage.py` from the pinned Setu in the project's root on `ext` as built: pytest
/// with the extension loaded first, a per-file table, the result in `zig-out/coverage.json`.
///
/// Note
///     - Needs kcov (43 tested); `ext.root_module` in Debug with debug info (else the step fails).
///     - Zig's default Debug backend (self-hosted x86_64) gives each line its own code, so every red line is
///       code that never ran. An LLVM build (`use_llvm`, or aarch64) folds a line like `orelse return ...` into
///       the one above, so its error path shows as run, and marks some comment and `fn` lines red.
///     - After `--`: the runner's `--missed` (red lines) / `--partial` (yellow lines) / `--python <path>` (the
///       tests under that interpreter too, merged; repeatable) / `--html <dir>` (kcov's HTML report too), the rest
///       goes to pytest.
///       Code between `// coverage-off` and `// coverage-on` is not counted.
///     - Not for CI as is: kcov is packaged for Ubuntu 25.04+ only.
///
/// Example
///     >>> // the project's build.zig (`setu` in its build.zig.zon)
///     >>> @import("setu").addCoverageSteps(b, setu_dep, ext, .{
///     >>>     .module_name = "liburing",
///     >>>     .package = true, // liburing/__init__.so
///     >>>     .include = &.{ b.path("src/liburing"), setu_dep.path("src") },
///     >>>     .python = b.option([]const u8, "python", "Python for `coverage`") orelse "python3",
///     >>> });
///     $ zig build coverage                    # the table; zig-out/coverage.json
///     $ zig build coverage -- --missed -k recv  # the lines never run; pytest's `-k recv`
///     $ zig build coverage -- --python /opt/python/3.14/bin/python3  # 3.14's paths too
pub fn addCoverageSteps(
    b: *std.Build,
    setu_dep: *std.Build.Dependency,
    ext: *std.Build.Step.Compile,
    options: CoverageOptions,
) void {
    coverage(b, setu_dep.path("tools/check_coverage.py"), ext, options);
}

/// `addCoverageSteps` with Setu's `tools/check_coverage.py` given (Setu's own build has no dependency).
fn coverage(
    b: *std.Build,
    runner: std.Build.LazyPath,
    ext: *std.Build.Step.Compile,
    options: CoverageOptions,
) void {
    const step = b.step("coverage", "Line coverage of the extension's Zig code under pytest (kcov)");
    const module = ext.root_module;
    if ((module.optimize orelse .debug) != .debug or module.strip == true) {
        step.dependOn(&b.addFail("coverage: the extension's module must be Debug, not stripped").step);
        return;
    }
    // `ext` as built: with the self-hosted x86_64 backend (the Debug default), whose line tables kcov reads once
    // `check_coverage.py` has fixed their padding (a copy), and which, unlike LLVM's, give each line its own code
    // (LLVM folds an `orelse return` into the line above and marks some comment and `fn` lines red).
    // `<name>.so` (or `<name>/__init__.so`), the file name the tests see (`__file__`), not `lib<name>.so`.
    const base = if (std.mem.findScalarLast(u8, options.module_name, '.')) |dot|
        options.module_name[dot + 1 ..]
    else
        options.module_name;
    const stem = if (options.package) b.fmt("{s}/__init__", .{base}) else base;
    const files = b.addWriteFiles();
    const so = files.addCopyFile(ext.getEmittedBin(), b.fmt("{s}{s}", .{ stem, ext_suffix }));
    if (options.stub) |pyi| _ = files.addCopyFile(pyi, b.fmt("{s}.pyi", .{stem}));

    const run = b.addSystemCommand(&.{options.python});
    run.setCwd(b.path("."));
    run.addFileArg2(runner, .{ .make_absolute = true });
    run.addArgs(&.{ "--name", options.module_name });
    for (options.include) |dir| run.addDirectoryArg2(dir, .{ .prefix = "--include=", .make_absolute = true });
    if (options.min) |min| run.addArg(b.fmt("--min={d}", .{min}));
    run.addFileArg2(so, .{ .make_absolute = true });
    run.addPassthruArgs(); // the runner's options (`--missed`), the rest is pytest's
    run.has_side_effects = true; // the tests are no input the step knows of
    step.dependOn(&run.step);
}

/// What `addZigTestCoverage` takes.
pub const ZigTestCoverageOptions = struct {
    /// The source directories to report.
    include: []const std.Build.LazyPath,
    /// The step's name; the result is `zig-out/<step_name>.json`.
    step_name: []const u8 = "coverage-zig",
    /// The interpreter that runs `tools/check_coverage.py` (no pytest needed).
    python: []const u8 = "python3",
    /// Fail when the total line coverage is lower (percent).
    min: ?f64 = null,
};

/// The step `coverage-zig` (`options.step_name`): line coverage of Zig unit tests, by kcov. It runs `tests`
/// (a `b.addTest`) under kcov with Setu's `tools/check_coverage.py --exe`, prints the per-file table and writes
/// `zig-out/coverage-zig.json`, in the format of `addCoverageSteps`' `coverage.json`.
///
/// Note
///     - Needs kcov (43 tested); `tests.root_module` in Debug with debug info (else the step fails).
///     - After `--`: the runner's `--missed` / `--partial` / `--html <dir>` / `--max-memory GB`, the rest goes to
///       the test executable. Code between `// coverage-off` and `// coverage-on` is not counted.
///     - For tests that do not call libpython: an extension's code runs under pytest (`addCoverageSteps`).
///
/// Example
///     >>> const tests = b.addTest(.{ .root_module = core });
///     >>> @import("setu").addZigTestCoverage(b, setu_dep, tests, .{ .include = &.{b.path("src/core")} });
///     $ zig build coverage-zig                # the table; zig-out/coverage-zig.json
///     $ zig build coverage-zig -- --missed    # the lines never run
pub fn addZigTestCoverage(
    b: *std.Build,
    setu_dep: *std.Build.Dependency,
    tests: *std.Build.Step.Compile,
    options: ZigTestCoverageOptions,
) void {
    zigTestCoverage(b, setu_dep.path("tools/check_coverage.py"), tests, options);
}

/// `addZigTestCoverage` with Setu's `tools/check_coverage.py` given (Setu's own build has no dependency).
fn zigTestCoverage(
    b: *std.Build,
    runner: std.Build.LazyPath,
    tests: *std.Build.Step.Compile,
    options: ZigTestCoverageOptions,
) void {
    const step = b.step(options.step_name, "Line coverage of the Zig unit tests (kcov)");
    const module = tests.root_module;
    if ((module.optimize orelse .debug) != .debug or module.strip == true) {
        const message = b.fmt("{s}: the tests' module must be Debug, not stripped", .{options.step_name});
        step.dependOn(&b.addFail(message).step);
        return;
    }
    // `tests` as built, as in `coverage` (`check_coverage.py` fixes a self-hosted build's line tables, in a copy)
    const run = b.addSystemCommand(&.{options.python});
    run.setCwd(b.path("."));
    run.addFileArg2(runner, .{ .make_absolute = true });
    run.addArgs(&.{ "--exe", b.fmt("--json=zig-out/{s}.json", .{options.step_name}) });
    for (options.include) |dir| run.addDirectoryArg2(dir, .{ .prefix = "--include=", .make_absolute = true });
    if (options.min) |min| run.addArg(b.fmt("--min={d}", .{min}));
    run.addArtifactArg2(tests, .{ .make_absolute = true });
    run.addPassthruArgs(); // the runner's options (`--missed`), the rest is the executable's
    run.has_side_effects = true; // kcov's run is no input the step knows of
    step.dependOn(&run.step);
}

/// What `addProfileSteps` takes.
pub const ProfileOptions = struct {
    /// The name the cases import the extension by: `"setu_classes"`, or `"liburing"` for a package's `__init__.so`
    /// (`package`).
    module_name: []const u8,
    /// The extension is its package's `__init__.so` (`liburing/__init__.so`): the profiled build is put there too.
    package: bool = false,
    /// The cases: a Python file with `CASES`, a list of `(label, statement)`, and `namespace(module)`, the names
    /// the statements use (Setu's `tools/bench.py` is one).
    cases: std.Build.LazyPath,
    /// The interpreter that runs `tools/check_profile.py` (and the cases; more with `-- --python <path>`).
    python: []const u8 = "python3",
};

/// The step `profile`: instructions per call of each case (a statement calling into the extension `ext`), in total
/// and per line of its Zig code, by callgrind. It runs Setu's `tools/check_profile.py` on `ext` as built, prints a
/// table per interpreter and writes `zig-out/profile.json`; with `--baseline <an earlier one>` it shows each case's
/// change and fails when one grew.
///
/// Note
///     - Needs valgrind (3.25 tested); `ext.root_module` optimized (not Debug), with debug info, for a CPU without
///       AVX-512 (valgrind can not run it): `-Doptimize=fast -Dcpu=x86_64_v3` (else the step fails).
///     - Counts instructions, not time: exact on every run, so a change of 1 per call shows. `tools/bench.py`
///       times the same cases.
///     - After `--`: the runner's `-k <text>` / `--lines <k>` (each case's costliest lines) / `--python <path>`
///       (that interpreter too; repeatable) / `--baseline <json>` / `--tolerance <n>` (default 2) / `--json <file>`.
///
/// Example
///     >>> @import("setu").addProfileSteps(b, setu_dep, ext, .{
///     >>>     .module_name = "liburing",
///     >>>     .package = true, // liburing/__init__.so
///     >>>     .cases = b.path("tools/bench_cases.py"),
///     >>> });
///     $ zig build profile -Doptimize=fast -Dcpu=x86_64_v3                  # the table; zig-out/profile.json
///     $ zig build profile -Doptimize=fast -Dcpu=x86_64_v3 -- -k recv --lines 8
///     $ cp zig-out/profile.json /tmp/before.json   # ... change the code ...
///     $ zig build profile -Doptimize=fast -Dcpu=x86_64_v3 -- --baseline /tmp/before.json
pub fn addProfileSteps(
    b: *std.Build,
    setu_dep: *std.Build.Dependency,
    ext: *std.Build.Step.Compile,
    options: ProfileOptions,
) void {
    profile(b, setu_dep.path("tools/check_profile.py"), ext, options);
}

/// `addProfileSteps` with Setu's `tools/check_profile.py` given (Setu's own build has no dependency).
fn profile(
    b: *std.Build,
    runner: std.Build.LazyPath,
    ext: *std.Build.Step.Compile,
    options: ProfileOptions,
) void {
    const step = b.step("profile", "Instructions per call of the extension's cases (callgrind)");
    const module = ext.root_module;
    const cpu = module.resolved_target.?.result.cpu;
    if ((module.optimize orelse .debug) == .debug or module.strip == true or
        (cpu.arch == .x86_64 and cpu.has(.x86, .avx512f)))
    {
        const message = "profile: build the extension optimized, with debug info, for a CPU valgrind runs: " ++
            "-Doptimize=fast -Dcpu=x86_64_v3";
        step.dependOn(&b.addFail(message).step);
        return;
    }
    // `<name>.so` (or `<name>/__init__.so`), the file name the cases import, not `lib<name>.so`
    const stem = if (options.package) b.fmt("{s}/__init__", .{options.module_name}) else options.module_name;
    const files = b.addWriteFiles();
    const so = files.addCopyFile(ext.getEmittedBin(), b.fmt("{s}{s}", .{ stem, ext_suffix }));

    const run = b.addSystemCommand(&.{options.python});
    run.setCwd(b.path("."));
    run.addFileArg2(runner, .{ .make_absolute = true });
    run.addArgs(&.{ "--name", options.module_name });
    run.addFileArg2(options.cases, .{ .prefix = "--cases=", .make_absolute = true });
    run.addFileArg2(so, .{ .make_absolute = true });
    run.addPassthruArgs(); // the runner's options (`-k`, `--baseline`, ...)
    run.has_side_effects = true; // valgrind's runs are no input the step knows of
    step.dependOn(&run.step);
}

/// The extension module's suffix: `<name>.so`, the one name CPython 3.14, 3.14t, 3.15, 3.15t and
/// later all import (`.abi3.so` is refused by 3.15t, `.abi3t.so` unknown to 3.14). The wheel is
/// tagged `cp314.cp315-abi3.abi3t.cp314t.cp315t` (`tools/setu_build.py`).
pub const ext_suffix = ".so";
