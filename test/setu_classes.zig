//! `setu_classes`: the test-only extension module for the classes in `classes.zig` and the functions
//! in `functions.zig`. Built by `zig build develop` into `test/` (with its stubs, `setu_classes.pyi`).

const setu = @import("setu");
const classes = @import("classes.zig");
const functions = @import("functions.zig");

const c = setu.c;
const py = setu.py;
const Object = c.Object;

/// Setu settings, read by `setu.Class` from the root file.
pub const setu_options = classes.setu_options;

const module_methods = py.exportFns(functions, @embedFile("functions.zig")) ++ [_]c.MethodDef{py.method_end};

/// `Py_mod_exec`: creates the classes and adds the constants of `functions.zig`.
fn exec(module: *Object) callconv(.c) c_int {
    inline for (classes.classes) |C| C.create(module) catch return -1;
    py.addConstants(module, functions) catch return -1;
    return 0;
}

comptime {
    py.exportModule(.{
        .name = "setu_classes",
        .doc = "Setu class hooks and parameter types, for the tests.",
        .methods = &module_methods,
        .exec = &exec,
    });
}
