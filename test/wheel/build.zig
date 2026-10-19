//! The wheel check's fixture: `setu_classes` (Setu's test extension) laid out the way
//! `tools/setu_build.py` expects a project (`[project].name`, `src/<name>/`, `build.zig.zon`'s
//! version, `zig build --prefix` installing `lib/<extension>.so` and `lib/<name>.pyi`).
//! `tools/check.sh` syncs the script into `tools/` here and builds wheels with it.
//!
//!   zig build setu-build-sync    copy Setu's tools/setu_build.py into tools/
//!   zig build setu-build-check   check that tools/setu_build.py is Setu's copy
//!   zig build --prefix <dir>     the extension and its stubs into <dir>/lib/ (what the script runs)

const std = @import("std");
const setu_build = @import("setu");

/// Takes the options `tools/setu_build.py` passes (`-Dfree-threaded`, `-Drelease`, `-Dstrip`,
/// `-Dtarget`) and installs Setu's test extension and stubs from the `setu` dependency.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const strip = b.option(bool, "strip", "Strip debug symbols from the extension") orelse false;
    const free_threaded = b.option(bool, "free-threaded", "Build for free-threaded 3.15t (default: true)") orelse
        true;

    const setu_dep = b.dependency("setu", .{
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .@"free-threaded" = free_threaded,
    });
    const name = b.fmt("setu_classes{s}", .{setu_build.defaultSuffix(b, target.result, free_threaded)});
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(setu_dep.namedLazyPath("setu_classes"), .lib, name).step);
    b.getInstallStep().dependOn(
        &b.addInstallFileWithDir(setu_dep.namedLazyPath("setu_classes.pyi"), .lib, "setu_classes.pyi").step,
    );
    setu_build.addSetuBuildSteps(b, setu_dep);
}
