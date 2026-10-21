//! PyOZ-style glue: write ordinary Zig functions, then expose every lowercase
//! `pub fn` of a file with `exportFns`, which generates the C-ABI trampolines and
//! converts arguments and return values (classes: `setu.Class`).
//!
//!     // math.zig
//!     /// Add two numbers.
//!     pub fn add(a: i64, b: ?i64) i64 { return a + (b orelse 0); }
//!
//!     // the module's root file
//!     const math = @import("math.zig");
//!     const methods = py.exportFns(math, @embedFile("math.zig")) ++ [_]c.MethodDef{py.method_end};
//!
//! Supported parameter types: integers, floats, `bool`, `[]const u8` / `[:0]const u8` (a
//! `str` as UTF-8, borrowed for the call), `Bytes` (a `bytes`), `Path` (`str` / `bytes` /
//! `os.PathLike`, released after the call), `Buffer` / `WritableBuffer` (a bytes-like object,
//! read-only / writable, locked for the call), `Sequence(T)` (a list / tuple / ... of `T`, freed
//! after the call), `*T` / `*const T` (an instance of the `setu.Class` of
//! the struct `T`, or of a subclass; `TypeError` otherwise), `*Object` (raw).
//! `?T` parameters are optional: omitted or `None` gives `null`
//! (for a raw `?*Object`, only omitted gives `null`; `None` is passed through).
//! Arguments are positional or keyword, by parameter name; a leading `Rest`
//! parameter collects `*args` (the rest are then keyword-only).
//! A `struct` parameter is an argument struct (like PyOZ's `Args`): each field is a
//! parameter, a field's default is the Python default (shown in `__text_signature__` as
//! written in the source), a field without one is required; see `Param`.
//! Supported return types: those plus `void`, optionals, error unions, tuples (`.{ a, b }`)
//! and slices (`[]const T` -> `list`; `[]const u8` is a `str`); see `toPython`.
//! Returning `error.PythonError` means "a Python exception is already set";
//! any other Zig error becomes `RuntimeError` (or `MemoryError`).
//!
//! The code is split by concern; this file is the one to import (`setu.py`):
//! `raise.zig` (exceptions), `convert.zig` (values), `args.zig` (parameters, argument
//! parsing), `source.zig` (reading the Zig source at comptime), `export.zig` (trampolines,
//! method tables).

const std = @import("std");
const c = @import("capi.zig");

pub const Object = c.Object;

/// "A Python exception is set": trampolines return NULL for it.
pub const Error = error{PythonError};

// --- references ---------------------------------------------------------------------

/// `Py_IncRef`: take a new reference.
pub fn incref(o: *Object) void {
    c.Py_IncRef(o);
}

/// `Py_DecRef`: drop a reference (`null` is fine).
pub fn decref(o: ?*Object) void {
    c.Py_DecRef(o);
}

/// Borrowed `None` (immortal).
pub fn none() *Object {
    return c.Py_GetConstantBorrowed(c.Py_CONSTANT_NONE);
}

/// Borrowed `True` (immortal).
pub fn trueObj() *Object {
    return c.Py_GetConstantBorrowed(c.Py_CONSTANT_TRUE);
}

/// Borrowed `False` (immortal).
pub fn falseObj() *Object {
    return c.Py_GetConstantBorrowed(c.Py_CONSTANT_FALSE);
}

/// A new reference to `None` (for returning it).
pub fn newNone() *Object {
    const o = none();
    incref(o);
    return o;
}

/// Borrowed `NotImplemented` (immortal).
pub fn notImplemented() *Object {
    return c.Py_GetConstantBorrowed(c.Py_CONSTANT_NOT_IMPLEMENTED);
}

/// A new reference to `NotImplemented`: what a comparison or number hook returns for an
/// operand it does not handle, so Python tries the other operand.
pub fn newNotImplemented() *Object {
    const o = notImplemented();
    incref(o);
    return o;
}

const raise_zig = @import("raise.zig");
const convert = @import("convert.zig");
const args_zig = @import("args.zig");
const source_zig = @import("source.zig");
const export_zig = @import("export.zig");

pub const raise = raise_zig.raise;
pub const setString = raise_zig.setString;
pub const raiseWith = raise_zig.raiseWith;
pub const raiseOSError = raise_zig.raiseOSError;
pub const raiseNoMemory = raise_zig.raiseNoMemory;
pub const raiseErrno = raise_zig.raiseErrno;
pub const checkErrno = raise_zig.checkErrno;
pub const raiseTypeError = raise_zig.raiseTypeError;
pub const raiseValueError = raise_zig.raiseValueError;
pub const raiseIndexError = raise_zig.raiseIndexError;
pub const raiseRuntimeError = raise_zig.raiseRuntimeError;
pub const raiseOverflowError = raise_zig.raiseOverflowError;
pub const raiseNotImplementedError = raise_zig.raiseNotImplementedError;
pub const raiseAttributeError = raise_zig.raiseAttributeError;
pub const setError = raise_zig.setError;

pub const fromPython = convert.fromPython;
pub const fromPythonAs = convert.fromPythonAs;
pub const narrow = convert.narrow;
pub const toPython = convert.toPython;
pub const new = convert.new;
pub const Bytes = convert.Bytes;
pub const Path = convert.Path;
pub const Buffer = convert.Buffer;
pub const WritableBuffer = convert.WritableBuffer;
pub const Sequence = convert.Sequence;
pub const isSequence = convert.isSequence;

pub const releaseArgs = args_zig.releaseArgs;
pub const releases = convert.releases;
pub const Rest = args_zig.Rest;
pub const Kwargs = args_zig.Kwargs;
pub const KwOnly = args_zig.KwOnly;
pub const positionalCount = args_zig.positionalCount;
pub const paramNames = args_zig.paramNames;
pub const Param = args_zig.Param;
pub const paramList = args_zig.paramList;
pub const selfArg = args_zig.selfArg;
pub const fillArgs = args_zig.fillArgs;
pub const parseArgs = args_zig.parseArgs;

pub const FnSource = source_zig.FnSource;
pub const fnSource = source_zig.fnSource;
pub const docAbove = source_zig.docAbove;

pub const method_end = export_zig.method_end;
pub const getset_end = export_zig.getset_end;
pub const exportFns = export_zig.exportFns;
pub const isExported = export_zig.isExported;
pub const methodDef = export_zig.methodDef;
pub const MethodKind = export_zig.MethodKind;
pub const methodKind = export_zig.methodKind;
pub const kindDef = export_zig.kindDef;
pub const hasRest = export_zig.hasRest;
pub const restIndex = export_zig.restIndex;
pub const leadCount = args_zig.leadCount;
pub const hasKwargs = export_zig.hasKwargs;
pub const paramText = export_zig.paramText;
pub const getter = export_zig.getter;
pub const Constant = export_zig.Constant;
pub const constants = export_zig.constants;
pub const addConstants = export_zig.addConstants;
pub const isUpperName = export_zig.isUpperName;
pub const Module = export_zig.Module;
pub const exportModule = export_zig.exportModule;

/// Pointer to a type's extra instance data (`Py_tp_extra_basicsize`).
pub fn typeData(comptime T: type, obj: *Object, tp: *c.TypeObject) *T {
    return @ptrCast(@alignCast(c.PyObject_GetTypeData(obj, tp).?));
}

/// `isinstance(obj, tp)` without going through `__instancecheck__`.
pub fn isInstance(obj: *Object, tp: *c.TypeObject) bool {
    return c.PyType_IsSubtype(c.Py_TYPE(obj), tp) != 0;
}
