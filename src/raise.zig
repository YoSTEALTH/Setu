//! Raising Python exceptions from Zig: every helper sets the exception and returns
//! `error.PythonError` ("a Python exception is set"), so a binding can `return py.raise...(...)`.
//! Re-exported by `py.zig`.

const std = @import("std");
const c = @import("capi.zig");
const py = @import("py.zig");
const toPython = @import("convert.zig").toPython;

const Object = py.Object;
const Error = py.Error;
const decref = py.decref;

/// Sets `exc` with a formatted message and returns `error.PythonError`.
/// For built-in exceptions use the shortcuts (`raiseValueError`, `raiseTypeError`, ...).
pub fn raise(exc: *Object, comptime fmt: []const u8, args: anytype) Error {
    setString(exc, fmt, args);
    return error.PythonError;
}

/// Sets `exc` with a formatted message (up to 511 bytes; longer ones are cut).
///
/// Note
///     - A message without arguments or braces is a constant: set as is, with no formatting.
pub fn setString(exc: *Object, comptime fmt: []const u8, args: anytype) void {
    if (comptime isConstant(fmt, @TypeOf(args))) return c.PyErr_SetString(exc, (fmt ++ "\x00")[0..fmt.len :0]);
    var buf: [512]u8 = undefined;
    const room = buf[0 .. buf.len - 1];
    const msg = std.mem.print(room, fmt, args) catch room;
    buf[msg.len] = 0;
    c.PyErr_SetString(exc, buf[0..msg.len :0]);
}

/// Is `fmt` with arguments of type `Args` its own text: no arguments and no `{` / `}` (escapes)?
fn isConstant(comptime fmt: []const u8, comptime Args: type) bool {
    return @typeInfo(Args).@"struct".field_names.len == 0 and std.mem.findAny(u8, fmt, "{}") == null;
}

/// Raises `exc(*args)` and returns `error.PythonError`. Each item of the tuple `args` is
/// converted like a result (`toPython`), a string (`[]const u8` or a literal) to `str`.
///
/// Example
///     >>> return py.raiseWith(c.PyExc_OSError, .{ ENFILE, "file table is full" });
///
/// Note
///     - The exception gets the args as given, so `OSError(errno, msg)` sets `.errno`.
pub fn raiseWith(exc: *Object, args: anytype) Error {
    const names = @typeInfo(@TypeOf(args)).@"struct".field_names;
    const tuple = c.PyTuple_New(names.len) orelse return error.PythonError;
    defer decref(tuple);
    inline for (names, 0..) |name, i| {
        const item = toPython(@field(args, name)) orelse return error.PythonError;
        _ = c.PyTuple_SetItem(tuple, i, item); // steals `item`
    }
    c.PyErr_SetObject(exc, tuple);
    return error.PythonError;
}

/// Raises `OSError(errno, msg)` with a formatted `msg` and returns `error.PythonError`.
///
/// Example
///     >>> return py.raiseOSError(ENFILE, "file table is full", .{});
///
/// Note
///     - CPython picks the errno subclass (`FileExistsError` for `EEXIST`, ...) and sets `.errno`.
///     - For an `OSError` subclass of your own, use `raiseWith(exc, .{ errno, msg })`.
pub fn raiseOSError(errno: i32, comptime fmt: []const u8, args: anytype) Error {
    var buf: [512]u8 = undefined;
    const msg = std.mem.print(&buf, fmt, args) catch &buf;
    return raiseWith(c.PyExc_OSError, .{ errno, msg });
}

/// Raises `MemoryError` and returns `error.PythonError`; for a failed Zig allocation.
///
/// Example
///     >>> const buf = allocator.alloc(u8, len) catch return py.raiseNoMemory();
///     MemoryError
pub fn raiseNoMemory() Error {
    @branchHint(.cold);
    _ = c.PyErr_NoMemory();
    return error.PythonError;
}

/// Raises `OSError(errno, strerror(errno))` and returns `error.PythonError`; for a failed
/// syscall or a negative io_uring result (`raiseErrno(-res)`).
///
/// Example
///     >>> if (res < 0) return py.raiseErrno(-res);
///     FileNotFoundError: [Errno 2] No such file or directory
///
/// Note
///     - CPython picks the errno subclass and sets `.errno` / `.strerror`.
///     - Not `inline`: it is the error path, so one cold copy keeps the callers small.
pub fn raiseErrno(errno: c_int) Error {
    @branchHint(.cold);
    std.c._errno().* = errno;
    _ = c.PyErr_SetFromErrno(c.PyExc_OSError);
    return error.PythonError;
}

/// `res` when it is `>= 0`, else `OSError` for the errno `-res` (`raiseErrno`): for the result of
/// a liburing call or a raw syscall, which is a negative errno on failure.
///
/// Example
///     >>> return py.checkErrno(c.io_uring_submit(ring));
///     >>> try py.checkErrno(@as(i32, 3))
///     3
///     >>> try py.checkErrno(@as(i32, -11))
///     BlockingIOError: [Errno 11] Resource temporarily unavailable
///     >>> try py.checkErrno(@as(i64, -1 << 40))
///     OverflowError: result -1099511627776 is out of errno range
///
/// Note
///     - `res` is any signed int type, and so is the result.
///     - An errno is a C `int`, so a result below `-INT_MAX` raises `OverflowError`.
pub fn checkErrno(res: anytype) Error!@TypeOf(res) {
    const T = @TypeOf(res);
    if (@typeInfo(T) != .int or @typeInfo(T).int.signedness != .signed)
        @compileError("`checkErrno` takes a signed int, not " ++ @typeName(T));
    if (res >= 0) return res;
    if (res < -std.math.maxInt(c_int)) return raiseOverflowError("result {d} is out of errno range", .{res});
    return raiseErrno(@intCast(-res)); // cast: `-res` is in 1..INT_MAX (checked above)
}

/// Raises `TypeError` with a formatted message (`raiseTypeError(...)`).
pub fn raiseTypeError(comptime fmt: []const u8, args: anytype) Error {
    return raise(c.PyExc_TypeError, fmt, args);
}

/// Raises `ValueError` with a formatted message (`raiseValueError(...)`).
///
/// Example
///     >>> return py.raiseValueError("`length` must be > 0, got {d}", .{length});
pub fn raiseValueError(comptime fmt: []const u8, args: anytype) Error {
    return raise(c.PyExc_ValueError, fmt, args);
}

/// Raises `IndexError` with a formatted message (`raiseIndexError(...)`).
pub fn raiseIndexError(comptime fmt: []const u8, args: anytype) Error {
    return raise(c.PyExc_IndexError, fmt, args);
}

/// Raises `RuntimeError` with a formatted message (`raiseRuntimeError(...)`).
pub fn raiseRuntimeError(comptime fmt: []const u8, args: anytype) Error {
    return raise(c.PyExc_RuntimeError, fmt, args);
}

/// Raises `OverflowError` with a formatted message (`raiseOverflowError(...)`).
pub fn raiseOverflowError(comptime fmt: []const u8, args: anytype) Error {
    return raise(c.PyExc_OverflowError, fmt, args);
}

/// Raises `NotImplementedError` with a formatted message (`raiseNotImplementedError(...)`).
pub fn raiseNotImplementedError(comptime fmt: []const u8, args: anytype) Error {
    return raise(c.PyExc_NotImplementedError, fmt, args);
}

/// Raises `AttributeError` with a formatted message (`raiseAttributeError(...)`).
pub fn raiseAttributeError(comptime fmt: []const u8, args: anytype) Error {
    return raise(c.PyExc_AttributeError, fmt, args);
}

/// Turns any Zig error into a Python exception (no-op for `PythonError`).
pub fn setError(err: anyerror) void {
    if (err == error.PythonError) return;
    if (err == error.OutOfMemory) {
        _ = c.PyErr_NoMemory();
        return;
    }
    setString(c.PyExc_RuntimeError, "{s}", .{@errorName(err)});
}

test {
    @import("std").testing.refAllDecls(@This());
}
