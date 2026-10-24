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

/// The whole `.pyi`.
const text = setu.stub.module(module);

/// Writes `text` to stdout.
pub fn main() void {
    var rest: []const u8 = text;
    while (rest.len > 0) {
        const n = std.os.linux.write(1, rest.ptr, rest.len);
        if (@as(isize, @bitCast(n)) <= 0) std.process.exit(1);
        rest = rest[n..];
    }
}
