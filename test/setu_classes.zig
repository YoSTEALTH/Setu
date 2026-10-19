//! `setu_classes`: the test-only extension module for the classes in `classes.zig`. Built by
//! `zig build develop` into `test/setu/` (with its stubs, `setu_classes.pyi`).

const setu = @import("setu");
const build_options = @import("build_options");
const classes = @import("classes.zig");

const c = setu.c;
const py = setu.py;
const Object = c.Object;

/// Setu settings, read by `setu.Class` from the root file.
pub const setu_options = classes.setu_options;

const module_methods = [_]c.MethodDef{py.method_end};

/// `Py_mod_exec`: creates the classes.
fn exec(module: *Object) callconv(.c) c_int {
    inline for (classes.classes) |C| C.create(module) catch return -1;
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
    c.Slot.data(c.Py_mod_doc, "Setu class hooks, for the tests."),
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
