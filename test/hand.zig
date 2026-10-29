//! `bench_nop` and `bench_recv` of `functions.zig` written by hand against the C API, the way a C extension would:
//! `_hand_nop` and `_hand_recv` (the `_` keeps them out of the stub and the docs). `zig build profile` runs both
//! next to Setu's (`tools/bench.py`), so the instructions per call compare Setu's generated code with code written
//! for the job (the performance rule: generated code costs the same as hand-written). Same arguments, keywords and
//! errors as Setu's, nothing more: `METH_FASTCALL | METH_KEYWORDS`, positional or keyword, ints range-checked.

const setu = @import("setu");
const classes = @import("classes.zig");

const c = setu.c;
const Object = c.Object;

/// The module's entries for the two functions (`Module.methods` in `setu_classes.zig`).
pub const methods = [_]c.MethodDef{
    .{ .name = "_hand_nop", .meth = @as(c.FastCallKw, &nop), .flags = fastcall, .doc = null },
    .{ .name = "_hand_recv", .meth = @as(c.FastCallKw, &recv), .flags = fastcall, .doc = null },
};

/// Both functions' calling convention.
const fastcall = c.METH_FASTCALL | c.METH_KEYWORDS;

/// `argv` / `nargs` / `kwnames` of a fastcall into `slots` (one per name of `names`, in order); false with a
/// `TypeError` set for too many positional arguments, an unknown or repeated keyword, or a missing one of the
/// first `required`.
fn parse(
    comptime names: []const [*:0]const u8,
    comptime required: usize,
    argv: ?[*]const *Object,
    nargs: c.ssize,
    kwnames: ?*Object,
    slots: *[names.len]?*Object,
) bool {
    if (nargs > names.len) {
        c.PyErr_SetString(c.PyExc_TypeError, "too many positional arguments");
        return false;
    }
    // cast: a count of arguments, never < 0
    const n: usize = @intCast(nargs);
    for (0..n) |i| slots[i] = argv.?[i];
    if (kwnames) |kw| {
        // cast: a tuple's size, never < 0
        const nkw: usize = @intCast(c.PyTuple_Size(kw));
        for (0..nkw) |j| {
            // cast: an index below `nkw`
            const key = c.PyTuple_GetItem(kw, @intCast(j)).?;
            const at = for (names, 0..) |name, i| {
                if (c.PyUnicode_EqualToUTF8(key, name) != 0) break i;
            } else {
                c.PyErr_SetString(c.PyExc_TypeError, "unexpected keyword argument");
                return false;
            };
            if (slots[at] != null) {
                c.PyErr_SetString(c.PyExc_TypeError, "argument given by position and by keyword");
                return false;
            }
            slots[at] = argv.?[n + j];
        }
    }
    for (slots[0..required]) |slot| {
        if (slot == null) {
            c.PyErr_SetString(c.PyExc_TypeError, "missing required argument");
            return false;
        }
    }
    return true;
}

/// `v` is a `Vec` (or a subclass); false with a `TypeError` set.
fn isVec(v: *Object) bool {
    if (c.PyType_IsSubtype(c.Py_TYPE(v), classes.VecType.tp.?) != 0) return true;
    c.PyErr_SetString(c.PyExc_TypeError, "v must be Vec");
    return false;
}

/// `obj` as an `i32`; null with `TypeError` / `OverflowError` set.
fn int32(obj: *Object) ?i32 {
    const n = c.PyLong_AsLongLong(obj);
    if (n == -1 and c.PyErr_Occurred() != null) return null;
    if (n < -0x8000_0000 or n > 0x7fff_ffff) {
        c.PyErr_SetString(c.PyExc_OverflowError, "value out of range for a 32-bit int");
        return null;
    }
    // cast: checked above
    return @intCast(n);
}

/// `None`, a new reference.
fn none() *Object {
    const obj = c.Py_GetConstantBorrowed(c.Py_CONSTANT_NONE);
    c.Py_IncRef(obj);
    return obj;
}

/// `_hand_nop(v)`: `bench_nop`.
fn nop(_: ?*Object, argv: ?[*]const *Object, nargs: c.ssize, kwnames: ?*Object) callconv(.c) ?*Object {
    var slots: [1]?*Object = @splat(null);
    if (!parse(&.{"v"}, 1, argv, nargs, kwnames, &slots)) return null;
    if (!isVec(slots[0].?)) return null;
    return none();
}

/// `_hand_recv(v, fd, buf=None, flags=None)`: `bench_recv`; `buf` a writable buffer, held for the call.
fn recv(_: ?*Object, argv: ?[*]const *Object, nargs: c.ssize, kwnames: ?*Object) callconv(.c) ?*Object {
    var slots: [4]?*Object = @splat(null);
    const names = [_][*:0]const u8{ "v", "fd", "buf", "flags" };
    if (!parse(&names, 2, argv, nargs, kwnames, &slots)) return null;
    if (!isVec(slots[0].?)) return null;
    const fd = int32(slots[1].?) orelse return null;
    const none_obj = c.Py_GetConstantBorrowed(c.Py_CONSTANT_NONE);
    var view: c.Buffer = undefined;
    const buf = slots[2] != null and slots[2].? != none_obj;
    if (buf and c.PyObject_GetBuffer(slots[2].?, &view, c.PyBUF_WRITABLE) < 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "buf must be a writable bytes-like object");
        return null;
    }
    defer if (buf) c.PyBuffer_Release(&view);
    if (slots[3]) |flags| {
        if (flags != none_obj) _ = int32(flags) orelse return null;
    }
    return c.PyLong_FromLong(fd);
}
