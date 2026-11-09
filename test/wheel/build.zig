//! The wheel check's fixture: `setu_classes` (Setu's test extension) laid out the way
//! `tool/setu_build.py` expects a project (`[project].name`, `src/<name>/`, `build.zig.zon`'s
//! version, `zig build --prefix` installing the extension as the package: `lib/__init__.so` and `lib/__init__.pyi`).
//! `tool/check.sh` syncs the script into `tool/` here and builds wheels with it.
//!
//!   zig build setu-build-sync    copy Setu's tool/setu_build.py into tool/
//!   zig build setu-build-check   check that tool/setu_build.py is Setu's copy
//!   zig build setu-guide-sync    copy Setu's doc/setu-guide.md into doc/ (`setu-guide-check` compares)
//!   zig build --prefix <dir>     the extension, its stubs and `py.typed` into <dir>/lib/ (what the script runs)

const std = @import("std");
const setu_build = @import("setu");

/// Takes the options `tool/setu_build.py` passes (`-Drelease`, `-Dstrip`, `-Dtarget`) and installs Setu's test
/// extension and stubs from the `setu` dependency.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .fast });
    const strip = b.option(bool, "strip", "Strip debug symbols from the extension") orelse false;

    const setu_dep = b.dependency("setu", .{
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    const name = "__init__" ++ setu_build.ext_suffix;
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(setu_dep.namedLazyPath("setu_classes"), .lib, name).step);
    b.getInstallStep().dependOn(
        &b.addInstallFileWithDir(setu_dep.namedLazyPath("setu_classes.pyi"), .lib, "__init__.pyi").step,
    );
    // `src/setu_classes/` has a `py.typed` too: the wheel must still hold one (the built copy).
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("src/setu_classes/py.typed"), .lib, "py.typed").step);
    setu_build.addSetuBuildSteps(b, setu_dep);
    setu_build.addSetuGuideSteps(b, setu_dep);
}
