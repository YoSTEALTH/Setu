//! Setu's stub generator: prints the `.pyi` of an extension, `setu.stub.module` of the `pub const
//! module: setu.Module` in its root file (imported as `ext`). Built for the build host by
//! `setu.addStubs` (`build.zig`); it never calls Python, so it needs no libpython: `py.exportModule`
//! does nothing under this root (`setu_stubgen`).

const std = @import("std");
const setu = @import("setu");
const ext = @import("ext");

/// The extension's module, for `setu.Class` / `setu.Exception` names (`__module__`).
pub const module = ext.module;
/// Tells `py.exportModule` (in `ext`) not to export anything.
pub const setu_stubgen = true;

/// Writes the whole `.pyi` to stdout.
pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    try setu.stub.module(&out.interface, module);
    try out.interface.flush();
}
