//! Python <-> Zig value conversion: `fromPython` for arguments, `toPython` / `new` for
//! results, and the `Bytes` / `Path` / `Buffer` / `WritableBuffer` / `OwnedBuffer` / `OwnedWritableBuffer` /
//! `Sequence(T)` argument types.
//! Re-exported by `py.zig`.

const std = @import("std");
const c = @import("capi.zig");
const py = @import("py.zig");
const raise = @import("raise.zig");
const class_zig = @import("class.zig");

const Object = py.Object;
const Error = py.Error;
const incref = py.incref;
const decref = py.decref;
const newNone = py.newNone;
const raiseTypeError = raise.raiseTypeError;
const raiseOverflowError = raise.raiseOverflowError;
const raiseNoMemory = raise.raiseNoMemory;
const setError = raise.setError;

/// Converts a Python argument to `T`: `bool` (truthiness), an integer type, a float
/// type, `[]const u8` / `[:0]const u8` (a `str`'s UTF-8, borrowed from it), `Bytes` (a
/// `bytes`' contents, borrowed), `Path` / `Buffer` / `WritableBuffer` / `OwnedBuffer` /
/// `OwnedWritableBuffer` / `Sequence(T)` (`deinit` them; see `releases`), `*U` / `*const U` (the instance data of a `setu.Class(U, ...)` instance
/// or subclass, borrowed), or `*Object` as is.
///
/// Example
///     >>> const fd = try fromPython(i32, arg);
///     >>> const on = try fromPython(bool, arg);
///     >>> const host = try fromPython([:0]const u8, arg); // valid while `arg` lives
///     >>> const v = try fromPython(*const Vec, arg); // `VecType.object(v)` is `arg`
///
/// Note
///     - An integer that does not fit raises `OverflowError` (`300 is out of range 0..255`);
///       `fromPythonAs` names the argument in it.
///     - A wrong type for `str` / `bytes` / a class raises `TypeError` (`expected `str``).
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
    if (T == Buffer) return Buffer.from(obj);
    if (T == WritableBuffer) return WritableBuffer.from(obj);
    if (T == OwnedBuffer) return OwnedBuffer.from(obj);
    if (T == OwnedWritableBuffer) return OwnedWritableBuffer.from(obj);
    if (comptime isSequence(T)) return T.fromAs(obj, what);
    switch (@typeInfo(T)) {
        .bool => {
            const r = c.PyObject_IsTrue(obj);
            if (r < 0) return error.PythonError;
            return r != 0;
        },
        .int => |info| {
            if (info.bits > 64) @compileError("unsupported parameter type " ++ @typeName(T) ++ " (more than 64 bits)");
            // Fast path: an `i64` (most ints) in range; the rest out of line (`intArg`), so an inlined
            // call does not merge the paths' `Error!T` through the stack (a store-forwarding stall).
            const small = c.PyLong_AsLongLong(obj);
            if (small != -1 or c.PyErr_Occurred() == null) if (std.math.cast(T, small)) |r| return r;
            return @call(.never_inline, intArg, .{ T, obj, small, what });
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
            if (comptime class_zig.isInstancePtr(T)) return class_zig.Instance(@typeInfo(T).pointer.child).from(obj);
            if (T != *Object) @compileError("unsupported parameter type " ++ @typeName(T));
            return obj;
        },
        else => @compileError("unsupported parameter type " ++ @typeName(T)),
    }
}

/// `fromPythonAs` of an int, past its fast path: `PyLong_AsLongLong(obj)` gave `small` out of `T`'s
/// range, or failed (`OverflowError`: past 64 bits, read as bytes).
fn intArg(comptime T: type, obj: *Object, small: c_longlong, comptime what: []const u8) Error!T {
    if (small != -1 or c.PyErr_Occurred() == null) {
        return std.math.cast(T, small) orelse outOfRange(T, obj, small, @sizeOf(i64), what);
    }
    if (c.PyErr_ExceptionMatches(c.PyExc_OverflowError) == 0) return error.PythonError;
    c.PyErr_Clear();
    var v: i128 = 0; // room for every `u64` and `i64` value, so only those can be out of range
    const flags = c.Py_ASNATIVEBYTES_NATIVE_ENDIAN | c.Py_ASNATIVEBYTES_ALLOW_INDEX;
    const n = c.PyLong_AsNativeBytes(obj, &v, @sizeOf(i128), flags);
    if (n < 0) return error.PythonError;
    if (n <= @sizeOf(i128)) if (std.math.cast(T, v)) |r| return r;
    return outOfRange(T, obj, if (n <= @sizeOf(i128)) v else null, n, what);
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

    /// The same path, kept until its own `deinit` (a new reference to `obj`): a parameter kept past
    /// the call, like `Buffer.take` (also for the items of a `Sequence(Path)`).
    pub fn take(self: Path) Error!Path {
        incref(self.obj);
        return self;
    }

    /// Drops the `bytes` object.
    pub fn deinit(self: Path) void {
        decref(self.obj);
    }
};

/// A read-only bytes-like argument: `bytes`, `bytearray`, `memoryview`, `array.array`, `mmap`,
/// anything with the buffer protocol (`PyBUF_SIMPLE`). `data` points into the object, which stays
/// locked (a `bytearray` can not resize) until `deinit`; as a parameter it is released after the call,
/// unless `take` keeps it.
///
/// Example
///     >>> pub fn checksum(data: py.Buffer) u32
///     >>> checksum(b'abc')
///     294
///     >>> checksum(memoryview(bytearray(b'abc'))[1:])
///     197
///     >>> checksum('abc')
///     TypeError: checksum() argument 'data' must be a bytes-like object
pub const Buffer = struct {
    /// The bytes, valid until `deinit`.
    data: []const u8,
    /// The view `PyObject_GetBuffer` filled (it holds a reference to the object).
    view: c.Buffer,

    /// The bytes of `obj`; `TypeError` for an object without the buffer protocol.
    pub fn from(obj: *Object) Error!Buffer {
        var b: Buffer = undefined;
        try fill(obj, &b);
        return b;
    }

    /// `from`, into `out` (an argument's place): see `WritableBuffer.fill`.
    pub inline fn fill(obj: *Object, out: *Buffer) Error!void {
        if (c.PyObject_GetBuffer(obj, &out.view, c.PyBUF_SIMPLE) < 0) return error.PythonError;
        out.data = viewBytes(&out.view);
    }

    /// A view of its own on the same object, locked until its `deinit`: a parameter kept past the
    /// call (Setu releases the parameter's view as usual). See `WritableBuffer.take`.
    pub fn take(self: Buffer) Error!Buffer {
        return from(try viewObject(&self.view));
    }

    /// Releases the view (`PyBuffer_Release`).
    pub fn deinit(self: Buffer) void {
        var view = self.view;
        c.PyBuffer_Release(&view);
    }
};

/// A writable bytes-like argument: `bytearray`, a `memoryview` of one, `array.array`, a writable
/// `mmap`, ... (`PyBUF_WRITABLE`). Like `Buffer`, locked and released after the call, unless `take` keeps it.
///
/// Example
///     >>> pub fn fill(buf: py.WritableBuffer, value: u8) void
///     >>> b = bytearray(3)
///     >>> fill(b, 7)
///     >>> b
///     bytearray(b'\x07\x07\x07')
///     >>> fill(b'abc', 7)
///     TypeError: fill() argument 'buf' must be a writable bytes-like object
pub const WritableBuffer = struct {
    /// The bytes, valid (and writable) until `deinit`.
    data: []u8,
    /// The view `PyObject_GetBuffer` filled (it holds a reference to the object).
    view: c.Buffer,

    /// The bytes of `obj`; `TypeError` for an object without the buffer protocol or a read-only
    /// one (`bytes`), `BufferError` for one that is not contiguous.
    ///
    pub fn from(obj: *Object) Error!WritableBuffer {
        var b: WritableBuffer = undefined;
        try fill(obj, &b);
        return b;
    }

    /// `from`, into `out`: Setu fills a parameter where it lives in the arguments tuple (and
    /// releases it there). A copy of the view right after CPython wrote it reads it with loads
    /// wider than CPython's stores: a store-forwarding stall, +10-18 ns per buffer argument.
    pub inline fn fill(obj: *Object, out: *WritableBuffer) Error!void {
        if (c.PyObject_GetBuffer(obj, &out.view, c.PyBUF_WRITABLE) < 0) return notWritable(obj, error.PythonError);
        out.data = viewBytes(&out.view);
    }

    /// The error for `from`'s failed `PyObject_GetBuffer`: `TypeError` for a read-only buffer,
    /// else `err` as raised.
    fn notWritable(obj: *Object, err: Error) Error {
        @branchHint(.cold);
        if (c.PyErr_ExceptionMatches(c.PyExc_BufferError) == 0) return err;
        const raised = c.PyErr_GetRaisedException();
        if (!readOnly(obj)) {
            c.PyErr_SetRaisedException(raised);
            return err;
        }
        py.decref(raised);
        return raiseTypeError("expected a writable bytes-like object", .{});
    }

    /// A view of its own on the same object, locked until its `deinit`: a parameter kept past the
    /// call, for memory the kernel writes later (an io_uring read until its completion). Until then
    /// the object can not resize (`BufferError`) and stays alive (the view holds it). Setu releases
    /// the parameter's own view after the call as usual, so a parameter costs nothing extra unless taken.
    ///
    /// Example
    ///     >>> pub fn hold(ring: *Ring, buf: py.WritableBuffer) void {
    ///     ...     ring.buf = try buf.take(); // `ring.buf.deinit()` at the completion
    ///     ... }
    ///     >>> b = bytearray(5)
    ///     >>> hold(ring, b)
    ///     >>> b.append(1)
    ///     BufferError: Existing exports of data: object cannot be re-sized
    ///
    /// Note
    ///     - Each `take` is a view of its own, released by its own `deinit` (the same `data`).
    ///     - `BufferError` for a view without an object (`PyBuffer_FillInfo(NULL)`): nothing to lock.
    pub fn take(self: WritableBuffer) Error!WritableBuffer {
        return from(try viewObject(&self.view));
    }

    /// Releases the view (`PyBuffer_Release`).
    pub fn deinit(self: WritableBuffer) void {
        var view = self.view;
        c.PyBuffer_Release(&view);
    }
};

/// A `Buffer` argument the function keeps: converted the same way, but Setu does not release the
/// view after the call; the function stores it (released later with `deinit`) or calls `deinit`. No
/// second view, unlike `Buffer.take`: `PyObject_GetBuffer` once per argument, the release moved to
/// where the function lets go (an io_uring send, until its completion).
///
/// Example
///     >>> pub fn send(ring: *Ring, data: py.OwnedBuffer) void {
///     ...     ring.data = data; // `ring.data.deinit()` at the completion
///     ... }
///
/// Note
///     - When a later argument fails to convert, the function is not called and Setu releases the view.
///       Once the function runs it owns the view, on its error paths too (its own `errdefer`).
///     - Not a `Sequence(T)` item or a `setu.Class` hook parameter (`@compileError`).
pub const OwnedBuffer = struct {
    /// The bytes, valid until `deinit`.
    data: []const u8,
    /// The view `PyObject_GetBuffer` filled (it holds a reference to the object).
    view: c.Buffer,

    /// The bytes of `obj`, as `Buffer.from`.
    pub fn from(obj: *Object) Error!OwnedBuffer {
        var b: OwnedBuffer = undefined;
        try fill(obj, &b);
        return b;
    }

    /// `from`, into `out` (an argument's place): see `WritableBuffer.fill`.
    pub inline fn fill(obj: *Object, out: *OwnedBuffer) Error!void {
        if (c.PyObject_GetBuffer(obj, &out.view, c.PyBUF_SIMPLE) < 0) return error.PythonError;
        out.data = viewBytes(&out.view);
    }

    /// Releases the view (`PyBuffer_Release`).
    pub fn deinit(self: OwnedBuffer) void {
        var view = self.view;
        c.PyBuffer_Release(&view);
    }
};

/// A `WritableBuffer` argument the function keeps (the same checks: `TypeError` for `bytes`), like
/// `OwnedBuffer`: Setu does not release the view after the call. Until the function's `deinit` the
/// object can not resize (`BufferError`) and stays alive (the view holds it).
///
/// Example
///     >>> pub fn recv(ring: *Ring, buf: py.OwnedWritableBuffer) void {
///     ...     ring.buf = buf; // `ring.buf.deinit()` at the completion
///     ... }
///     >>> b = bytearray(5)
///     >>> recv(ring, b)
///     >>> b.append(1)
///     BufferError: Existing exports of data: object cannot be re-sized
pub const OwnedWritableBuffer = struct {
    /// The bytes, valid (and writable) until `deinit`.
    data: []u8,
    /// The view `PyObject_GetBuffer` filled (it holds a reference to the object).
    view: c.Buffer,

    /// The bytes of `obj`, as `WritableBuffer.from`.
    pub fn from(obj: *Object) Error!OwnedWritableBuffer {
        var b: OwnedWritableBuffer = undefined;
        try fill(obj, &b);
        return b;
    }

    /// `from`, into `out` (an argument's place): see `WritableBuffer.fill`.
    pub inline fn fill(obj: *Object, out: *OwnedWritableBuffer) Error!void {
        if (c.PyObject_GetBuffer(obj, &out.view, c.PyBUF_WRITABLE) < 0)
            return WritableBuffer.notWritable(obj, error.PythonError);
        out.data = viewBytes(&out.view);
    }

    /// Releases the view (`PyBuffer_Release`).
    pub fn deinit(self: OwnedWritableBuffer) void {
        var view = self.view;
        c.PyBuffer_Release(&view);
    }
};

/// `PyObject_GetBuffer(obj, flags)`.
fn getBuffer(obj: *Object, flags: c_int) Error!c.Buffer {
    var view: c.Buffer = undefined;
    if (c.PyObject_GetBuffer(obj, &view, flags) < 0) return error.PythonError;
    return view;
}

/// Is `obj` a read-only buffer (the reason `PyBUF_WRITABLE` failed)? Clears its own error.
fn readOnly(obj: *Object) bool {
    var view = getBuffer(obj, c.PyBUF_SIMPLE) catch {
        c.PyErr_Clear();
        return false;
    };
    defer c.PyBuffer_Release(&view);
    return view.readonly != 0;
}

/// The bytes `view` describes (one contiguous block: `PyBUF_SIMPLE` / `PyBUF_WRITABLE`).
fn viewBytes(view: *const c.Buffer) []u8 {
    const len: usize = @intCast(view.len); // cast: a size, never < 0
    if (len == 0) return &.{};
    const ptr: [*]u8 = @ptrCast(view.buf.?);
    return ptr[0..len];
}

/// A sequence argument (`list`, `tuple`, `range`, ...: what `PySequence_Check` accepts) as a Zig
/// slice: each item converted like a parameter of type `T` (an int, float, `bool`, `Bytes`,
/// `[]const u8`, `*U` of a `setu.Class`, `Buffer`, `*Object`, ...). As a parameter it is released
/// after the call, unless `take` keeps it.
///
/// Example
///     >>> pub fn total(values: py.Sequence(u32)) u64
///     >>> total([1, 2, 3])
///     6
///     >>> total((1, 2, 3))
///     6
///     >>> total([1, -2])
///     OverflowError: `total(values)` item = -2 is out of range 0..4294967295
///     >>> total(1)
///     TypeError: total() argument 'values' must be a sequence of `int`
///
/// Note
///     - The items are read from a tuple copy (`PySequence_Tuple`), held until `deinit`: a
///       borrowed item (`Bytes`, `[]const u8`, `*U`) stays valid even if the list changes.
///     - `items` lives in `PyMem_Malloc` memory (none for an empty sequence).
pub fn Sequence(comptime T: type) type {
    if (owns(T)) @compileError("`Sequence(" ++ @typeName(T) ++ ")`: the items are released with the " ++
        "sequence; use `Sequence(Buffer)` / `Sequence(WritableBuffer)` and `take`");
    return struct {
        const Self = @This();

        /// The item type.
        pub const Item = T;

        /// The converted items, valid until `deinit`.
        items: []T,
        /// The tuple the items come from (it keeps them alive).
        tuple: *Object,

        /// The items of `obj`; `TypeError` for an object that is not a sequence.
        pub fn from(obj: *Object) Error!Self {
            return fromAs(obj, "");
        }

        /// `from`, with `what` (as in `fromPythonAs`) naming the items in an `OverflowError`.
        pub fn fromAs(obj: *Object, comptime what: []const u8) Error!Self {
            if (c.PySequence_Check(obj) == 0) return raiseTypeError("expected a sequence", .{});
            const tuple = c.PySequence_Tuple(obj) orelse return error.PythonError;
            errdefer decref(tuple);
            const n: usize = @intCast(c.PyTuple_Size(tuple)); // cast: a size, never < 0
            if (n == 0) return .{ .items = &.{}, .tuple = tuple };
            const size = std.math.mul(usize, n, @sizeOf(T)) catch return raiseNoMemory();
            const mem = c.PyMem_Malloc(size) orelse return raiseNoMemory();
            const items = @as([*]T, @ptrCast(@alignCast(mem)))[0..n];
            for (items, 0..) |*item, i| {
                const o = c.PyTuple_GetItem(tuple, @intCast(i)).?; // cast: an index < `n`
                item.* = fromPythonAs(T, o, if (what.len == 0) "item" else what ++ " item") catch |err| {
                    if (comptime releases(T)) for (items[0..i]) |done| done.deinit();
                    c.PyMem_Free(mem);
                    return err;
                };
            }
            return .{ .items = items, .tuple = tuple };
        }

        /// A copy of its own, kept until its `deinit`: the items (a `Buffer` item with a view of its own,
        /// `take`), their memory and the tuple. For a parameter kept past the call (Setu releases the
        /// parameter as usual).
        ///
        /// Example
        ///     >>> pub fn register(ring: *Ring, bufs: py.Sequence(py.WritableBuffer)) void {
        ///     ...     ring.bufs = try bufs.take(); // the `iovec`s point into `bufs.items[i].data`
        ///     ... }
        ///     >>> b = bytearray(5)
        ///     >>> register(ring, [b])
        ///     >>> b.append(1)
        ///     BufferError: Existing exports of data: object cannot be re-sized
        pub fn take(self: Self) Error!Self {
            const n = self.items.len;
            if (n == 0) {
                incref(self.tuple);
                return .{ .items = &.{}, .tuple = self.tuple };
            }
            const mem = c.PyMem_Malloc(n * @sizeOf(T)) orelse return raiseNoMemory(); // `from` checked the size
            const items = @as([*]T, @ptrCast(@alignCast(mem)))[0..n];
            for (items, self.items, 0..) |*item, old, i| {
                item.* = if (comptime releases(T)) old.take() catch |err| {
                    for (items[0..i]) |done| done.deinit();
                    c.PyMem_Free(mem);
                    return err;
                } else old;
            }
            incref(self.tuple);
            return .{ .items = items, .tuple = self.tuple };
        }

        /// Releases the items (when `T` needs it), frees `items` and drops the tuple.
        pub fn deinit(self: Self) void {
            if (comptime releases(T)) for (self.items) |item| item.deinit();
            if (self.items.len > 0) c.PyMem_Free(@ptrCast(self.items.ptr));
            decref(self.tuple);
        }
    };
}

/// The object a view locks (`view.obj`), for `take`; `BufferError` without one.
fn viewObject(view: *const c.Buffer) Error!*Object {
    return view.obj orelse raise.raise(c.PyExc_BufferError, "a buffer without an object can not be kept", .{});
}

/// Is `T` a `Sequence(...)`?
pub fn isSequence(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "Item")) return false;
    return T == Sequence(T.Item);
}

/// Does an argument of type `T` (or `?T`) need a `deinit` after the call: a Setu argument type
/// that holds a reference or a lock (`Path`, `Buffer`, `WritableBuffer`, `Sequence(...)`)?
pub fn releases(comptime T: type) bool {
    const U = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
    return U == Path or U == Buffer or U == WritableBuffer or isSequence(U);
}

/// Is an argument of type `T` (or `?T`) the function's to release (`OwnedBuffer`,
/// `OwnedWritableBuffer`)? Setu releases it only when a later argument fails to convert.
pub fn owns(comptime T: type) bool {
    const U = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
    return U == OwnedBuffer or U == OwnedWritableBuffer;
}

/// Is `T` one of the buffer argument types, filled in place (`fill`)?
pub fn isBuffer(comptime T: type) bool {
    return T == Buffer or T == WritableBuffer or T == OwnedBuffer or T == OwnedWritableBuffer;
}

const testing = @import("testing.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

test "releases / owns / isBuffer / isSequence: which argument types Setu releases" {
    comptime {
        for ([_]type{ Path, Buffer, WritableBuffer, Sequence(u8), ?Buffer, ?Sequence(Bytes) }) |T|
            testing.expect(releases(T) and !owns(T), @typeName(T) ++ ": released after the call");
        for ([_]type{ OwnedBuffer, OwnedWritableBuffer, ?OwnedBuffer, ?OwnedWritableBuffer }) |T|
            testing.expect(owns(T) and !releases(T), @typeName(T) ++ ": the function's");
        for ([_]type{ u8, Bytes, []const u8, *Object, ?i32 }) |T|
            testing.expect(!releases(T) and !owns(T), @typeName(T) ++ ": nothing to release");
        for ([_]type{ Buffer, WritableBuffer, OwnedBuffer, OwnedWritableBuffer }) |T|
            testing.expect(isBuffer(T), @typeName(T) ++ ": a buffer");
        testing.expect(!isBuffer(?Buffer) and !isBuffer(Bytes), "`?Buffer` / `Bytes`: no buffer");
        testing.expect(isSequence(Sequence(Buffer)) and !isSequence(Buffer), "`Sequence(Buffer)` only");
    }
}
