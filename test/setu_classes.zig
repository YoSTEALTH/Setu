//! `setu_classes`: the test-only extension module for the classes in `classes.zig` and the functions
//! in `functions.zig`. Built by `zig build develop` into `test/` (with its stubs, `setu_classes.pyi`).

const setu = @import("setu");
const build_options = @import("build_options");
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

const abi_info: c.ABIInfo = .{
    .flags = if (build_options.free_threaded) c.PyABIInfo_FREETHREADED else c.PyABIInfo_GIL,
    .build_version = c.version_3_15,
    .abi_version = c.version_3_15,
};

const module_slots = [_]c.Slot{
    c.Slot.data(c.Py_mod_abi, &abi_info),
    c.Slot.data(c.Py_mod_name, "setu_classes"),
    c.Slot.data(c.Py_mod_doc, "Setu class hooks and parameter types, for the tests."),
    c.Slot.static(c.Py_mod_methods, &module_methods),
    c.Slot.func(c.Py_mod_exec, @ptrCast(&exec)),
    c.Slot.uint(c.Py_mod_gil, c.Py_MOD_GIL_NOT_USED),
    c.Slot.uint(c.Py_mod_multiple_interpreters, c.Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED),
    c.Slot.end,
};

/// PEP 793 entry point: CPython 3.15 looks up `PyModExport_<name>`.
export fn PyModExport_setu_classes() callconv(.c) [*]const c.Slot {
    return &module_slots;
}
