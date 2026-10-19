//! Python <-> Zig value conversion: `fromPython` for arguments, `toPython` / `new` for
//! results, and the `Bytes` / `Path` argument types. Re-exported by `py.zig`.

const std = @import("std");
const c = @import("capi.zig");
const py = @import("py.zig");
const raise = @import("raise.zig");

const Object = py.Object;
const Error = py.Error;
const incref = py.incref;
const decref = py.decref;
const newNone = py.newNone;
const raiseTypeError = raise.raiseTypeError;
const raiseOverflowError = raise.raiseOverflowError;
const setError = raise.setError;

/// Converts a Python argument to `T`: `bool` (truthiness), an integer type, a float
/// type, `[]const u8` / `[:0]const u8` (a `str`'s UTF-8, borrowed from it), `Bytes` (a
/// `bytes`' contents, borrowed), `Path` (a new reference: `deinit` it), or `*Object` as is.
///
/// Example
///     >>> const fd = try fromPython(i32, arg);
///     >>> const on = try fromPython(bool, arg);
///     >>> const host = try fromPython([:0]const u8, arg); // valid while `arg` lives
///
/// Note
///     - An integer that does not fit raises `OverflowError` (`300 is out of range 0..255`);
///       `fromPythonAs` names the argument in it.
///     - A wrong type for `str` / `bytes` raises `TypeError` (`expected `str``).
pub fn fromPython(comptime T: type, obj: *Object) Error!T {
    return fromPythonAs(T, obj, "");
}

/// `fromPython`, with `what` (a parameter, like `narrow`'s) naming the value in an
/// `OverflowError`. Setu calls it for every argument, with `` `f(x)` ``.
///
/// Example
///     >>> const n = try fromPythonAs(i64, arg, "`SQE(num)`");
///     >>> try fromPythonAs(u8, arg, "`f(x)`") // arg: 2**64
///     OverflowError: `f(x)` = 18446744073709551616 is out of range 0..255
///
/// Note
///     - Every integer width gives the same message, also for values past 64 bits (read with
///       `PyLong_AsNativeBytes`, which takes `__index__` objects like `PyLong_AsLongLong`).
pub fn fromPythonAs(comptime T: type, obj: *Object, comptime what: []const u8) Error!T {
    if (T == Bytes) {
        if (c.PyBytes_Check(obj) == 0) return raiseTypeError("expected `bytes`", .{});
        var ptr: ?[*]u8 = null;
        var n: c.ssize = 0;
        if (c.PyBytes_AsStringAndSize(obj, &ptr, &n) < 0) return error.PythonError;
        return .{ .data = ptr.?[0..@intCast(n)] }; // cast: a size, never < 0
    }
    if (T == Path) return Path.from(obj);
    switch (@typeInfo(T)) {
        .bool => {
            const r = c.PyObject_IsTrue(obj);
            if (r < 0) return error.PythonError;
            return r != 0;
        },
        .int => |info| {
            if (info.bits > 64) @compileError("unsupported parameter type " ++ @typeName(T) ++ " (more than 64 bits)");
            var v: i128 = 0; // room for every `u64` and `i64` value, so only those can be out of range
            const flags = c.Py_ASNATIVEBYTES_NATIVE_ENDIAN | c.Py_ASNATIVEBYTES_ALLOW_INDEX;
            const n = c.PyLong_AsNativeBytes(obj, &v, @sizeOf(i128), flags);
            if (n < 0) return error.PythonError;
            if (n <= @sizeOf(i128)) if (std.math.cast(T, v)) |r| return r;
            return outOfRange(T, obj, if (n <= @sizeOf(i128)) v else null, n, what);
        },
        .float => {
            const v = c.PyFloat_AsDouble(obj);
            if (v == -1.0 and c.PyErr_Occurred() != null) return error.PythonError;
            return @floatCast(v);
        },
        .pointer => {
            if (T == []const u8 or T == [:0]const u8) {
                if (c.PyUnicode_Check(obj) == 0) return raiseTypeError("expected `str`", .{});
                var n: c.ssize = 0;
                const s = c.PyUnicode_AsUTF8AndSize(obj, &n) orelse return error.PythonError;
                return s[0..@intCast(n) :0]; // cast: a size, never < 0
            }
            if (T != *Object) @compileError("unsupported parameter type " ++ @typeName(T));
            return obj;
        },
        else => @compileError("unsupported parameter type " ++ @typeName(T)),
    }
}

/// Raises `OverflowError` for the int `obj` (`value`, or `null` past 128 bits: `n` bytes),
/// out of `T`'s range, in `narrow`'s style.
fn outOfRange(comptime T: type, obj: *Object, value: ?i128, n: c.ssize, comptime what: []const u8) Error {
    @branchHint(.cold);
    const head = if (what.len == 0) "" else what ++ " = ";
    const range = .{ std.math.minInt(T), std.math.maxInt(T) };
    if (value) |v| return raiseOverflowError(head ++ "{d} is out of range {d}..{d}", .{v} ++ range);
    // Past 128 bits: up to 32 bytes (77 digits) as `str()` shows it, longer ones by size.
    if (n <= 32) {
        const int = c.PyNumber_Index(obj) orelse return error.PythonError;
        defer decref(int);
        const str = c.PyObject_Str(int) orelse return error.PythonError;
        defer decref(str);
        var len: c.ssize = 0;
        const s = c.PyUnicode_AsUTF8AndSize(str, &len) orelse return error.PythonError;
        // cast: a size, never < 0
        return raiseOverflowError(head ++ "{s} is out of range {d}..{d}", .{s[0..@intCast(len)]} ++ range);
    }
    return raiseOverflowError(head ++ "an int of {d} bytes is out of range {d}..{d}", .{n} ++ range);
}

/// `value` as `T`, or `OverflowError` naming `what` (a parameter, in the style of the
/// other argument errors) with `T`'s range. For a value that an argument's own type can
/// not bound: one parameter read as two types (`close(fd, direct)`), or a check that
/// also covers internal state (`File.write(offset)` defaults to the tracked position).
///
/// Example
///     >>> const index = try narrow(u32, fd, "`close(fd)` with `direct=True`");
///     >>> try narrow(u32, @as(i32, -1), "`close(fd)` with `direct=True`")
///     OverflowError: `close(fd)` with `direct=True` = -1 is out of range 0..4294967295
///
/// Note
///     - Use it instead of `@intCast` on anything a caller can choose; `tools/check.sh`
///       rejects an `@intCast` without a `// cast:` reason.
pub fn narrow(comptime T: type, value: anytype, comptime what: []const u8) Error!T {
    return std.math.cast(T, value) orelse raiseOverflowError(
        what ++ " = {d} is out of range {d}..{d}",
        .{ value, std.math.minInt(T), std.math.maxInt(T) },
    );
}

/// Converts a Zig return value to a new Python reference: `void` -> `None`, `bool`,
/// integers, floats, optionals (`null` -> `None`), `*Object` as is (a new reference, which
/// this takes), error unions (an error sets the Python exception), strings (`[]const u8`,
/// string literals) -> `str`, `Bytes` -> `bytes`, tuples -> `tuple`, other slices -> `list`.
/// Returns `null` with an exception set on failure.
///
/// Example
///     >>> toPython(@as(i32, 3)) // a new `int` reference
///     3
///     >>> toPython(.{ host, @as(u16, 80) }) // `host`: a new `str` reference, taken
///     ('example.com', 80)
///     >>> toPython(Bytes{ .data = "hi" })
///     b'hi'
///
/// Note
///     - A tuple or list takes its `*Object` items even when it fails (they are dropped).
pub fn toPython(value: anytype) ?*Object {
    const T = @TypeOf(value);
    // cast: a slice length fits `isize`
    if (T == Bytes) return c.PyBytes_FromStringAndSize(value.data.ptr, @intCast(value.data.len));
    if (comptime isString(T)) {
        const s: []const u8 = value;
        return c.PyUnicode_FromStringAndSize(s.ptr, @intCast(s.len)); // cast: a slice length fits `isize`
    }
    switch (@typeInfo(T)) {
        .error_union => {
            const v = value catch |err| {
                setError(err);
                return null;
            };
            return toPython(v);
        },
        .void => return newNone(),
        .bool => return c.PyBool_FromLong(@intFromBool(value)),
        .comptime_int => return c.PyLong_FromLongLong(value),
        .int => |info| {
            if (info.bits > 64) @compileError("unsupported result type " ++ @typeName(T) ++ " (more than 64 bits)");
            // cast: at most 64 bits (checked above)
            if (info.signedness == .signed) return c.PyLong_FromLongLong(@intCast(value));
            return c.PyLong_FromUnsignedLongLong(@intCast(value)); // cast: at most 64 bits
        },
        .float, .comptime_float => return c.PyFloat_FromDouble(@floatCast(value)),
        .optional => return if (value) |v| toPython(v) else newNone(),
        .pointer => |p| {
            if (T == *Object) return value; // already a new reference
            if (p.size != .slice) @compileError("unsupported return type " ++ @typeName(T));
            const list = c.PyList_New(@intCast(value.len)) orelse { // cast: a slice length fits `isize`
                dropItems(value, 0);
                return null;
            };
            for (value, 0..) |item, i| {
                const o = toPython(item) orelse {
                    dropItems(value, i + 1);
                    decref(list); // the items set so far go with it
                    return null;
                };
                _ = c.PyList_SetItem(list, @intCast(i), o); // steals `o`; cast: an index < `len`
            }
            return list;
        },
        .@"struct" => |info| {
            if (!info.is_tuple) @compileError("unsupported return type " ++ @typeName(T));
            const tuple = c.PyTuple_New(info.field_names.len) orelse {
                inline for (info.field_names) |n| dropItem(@field(value, n));
                return null;
            };
            inline for (info.field_names, 0..) |n, i| {
                const o = toPython(@field(value, n)) orelse {
                    inline for (info.field_names[i + 1 ..]) |rest| dropItem(@field(value, rest));
                    decref(tuple);
                    return null;
                };
                _ = c.PyTuple_SetItem(tuple, i, o); // steals `o`
            }
            return tuple;
        },
        else => @compileError("unsupported return type " ++ @typeName(T)),
    }
}

/// `toPython(value)`, with a failure as `error.PythonError`.
///
/// Example
///     >>> return .{ .done = try py.new(py.Bytes{ .data = buf[0..n] }) };
pub fn new(value: anytype) Error!*Object {
    return toPython(value) orelse error.PythonError;
}

/// Is `T` a string `toPython` makes a `str` of (a `u8` slice, `[:0]const u8`, a literal)?
fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

/// Drops the `*Object` items of `items[from..]` (a failed `toPython` of a list takes them).
fn dropItems(items: anytype, from: usize) void {
    for (items[from..]) |item| dropItem(item);
}

/// Drops `item` if it is a `*Object` (a new reference `toPython` would have taken).
fn dropItem(item: anytype) void {
    if (@TypeOf(item) == *Object) decref(item);
}

/// The contents of a `bytes` argument (borrowed for the call), or `bytes` made from a Zig
/// slice as a result (`toPython`).
///
/// Example
///     >>> pub fn join_bytes(path: py.Bytes, other: py.Bytes) Error!*Object
///     >>> join_bytes(b'/one', b'two')
///     b'/one/two'
///     >>> join_bytes('/one', b'two')
///     TypeError: expected `bytes`
pub const Bytes = struct {
    data: []const u8,
};

/// A file system path (`str`, `bytes` or `os.PathLike`, encoded like `os.fsencode`):
/// `path` points into `obj`, a `bytes` this holds. As a parameter it is released after
/// the call; `incref(p.obj)` to keep it.
///
/// Example
///     >>> const p = try py.Path.from(arg);
///     >>> defer p.deinit();
///     >>> std.posix.open(p.path, ...)
pub const Path = struct {
    obj: *Object,
    path: [:0]const u8,

    /// `obj` converted (`PyUnicode_FSConverter`); `TypeError` for other types.
    pub fn from(obj: *Object) Error!Path {
        var out: ?*Object = null;
        if (c.PyUnicode_FSConverter(obj, &out) == 0) return error.PythonError;
        var ptr: ?[*]u8 = null;
        var n: c.ssize = 0;
        if (c.PyBytes_AsStringAndSize(out.?, &ptr, &n) < 0) {
            decref(out);
            return error.PythonError;
        }
        return .{ .obj = out.?, .path = ptr.?[0..@intCast(n) :0] }; // cast: a size, never < 0
    }

    /// Drops the `bytes` object.
    pub fn deinit(self: Path) void {
        decref(self.obj);
    }
};
