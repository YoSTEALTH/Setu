//! `setu_classes`: the test-only extension module, and Setu's model root file. `module` lists its
//! files once: Setu finds their functions, classes, exceptions, constants and `IntEnum`s, creates them
//! in its `Py_mod_exec` and writes `setu_classes.pyi` from the same declaration (`zig build develop`).

const setu = @import("setu");
const classes = @import("classes.zig");
const extra = @import("extra.zig");
const hand = @import("hand.zig");

const c = setu.c;
const py = setu.py;
const Object = c.Object;

/// The module (`py.exportModule` below, `setu.addStubs` in `build.zig`). Its docstring is the `//!` doc of
/// `functions.zig`, the first entry with a `source`.
pub const module: setu.Module = .{
    .name = "setu_classes",
    .version = "0.0",
    .from = &.{
        // classes only, so no `source`; `not_exported` there is dropped by `.functions = false`
        .{ .ns = classes, .functions = false },
        .{ .ns = @import("functions.zig"), .source = @embedFile("functions.zig") },
        .{ .ns = extra, .source = @embedFile("extra.zig"), .exclude = &.{"excluded"}, .enums = .int_enum },
        .{ .ns = extra.kernel, .prefixes = &.{"K_"} },
        .{ .ns = extra.picked, .only = &.{"PICKED"} },
    },
    // trampolines the stub generator must drop, not link (as `Secret.read`'s default; see `setu.addStubs`)
    // and `bench_nop` / `bench_recv` written by hand (`hand.zig`), which `zig build profile` compares them with
    .methods = &(py.exportFns(by_hand, @embedFile("setu_classes.zig")) ++ hand.methods),
    .init = init,
    .stub_extra =
    \\initialized: bool
    \\BY_HAND: int
    \\
    ,
};

/// What the module adds by hand: a function replacing `extra.overridden` (`Module.methods`, the old
/// `py.exportFns`; the stub keeps `extra.overridden`'s) and a constant `init` adds (`py.addConstants`,
/// declared in `stub_extra`).
const by_hand = struct {
    pub const BY_HAND = 1;

    /// `2` (`extra.zig`'s `overridden`, which it replaces, gives `1`).
    pub fn overridden() i64 {
        return 2;
    }
};

/// Runs after Setu's part of `Py_mod_exec`: `initialized` says whether the classes exist by then.
fn init(mod: *Object) py.Error!void {
    const done = try py.new(classes.VecType.tp != null);
    defer py.decref(done);
    if (c.PyModule_AddObjectRef(mod, "initialized", done) < 0) return error.PythonError;
    try py.addConstants(mod, by_hand);
}

comptime {
    py.exportModule(module);
}
