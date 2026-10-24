//! Setu's test extension: module functions and constants for the parameter types that are not classes
//! of their own (instances of a `setu.Class`, buffers, sequences), `py.checkErrno` and typed constants.
//! This block is the module's docstring (the first `Module.from` entry with a `source`).

const std = @import("std");
const setu = @import("setu");
const classes = @import("classes.zig");

const c = setu.c;
const py = setu.py;
const Object = c.Object;
const Error = py.Error;
const Labeled = classes.Labeled;
const Vec = classes.Vec;
const VecType = classes.VecType;
const Secret = classes.Secret;

/// The squared length of `v` (a `Vec`, or a subclass).
///
/// Example
///     >>> vec_norm2(Vec(3, 4))
///     25
///     >>> vec_norm2((3, 4))
///     TypeError: vec_norm2() argument 'v' must be `Vec`
pub fn vec_norm2(v: *const Vec) i64 {
    return v.x * v.x + v.y * v.y;
}

/// Multiplies the coordinates of `v` by `k`, in place.
///
/// Example
///     >>> v = Vec(1, 2)
///     >>> vec_scale(v, 3)
///     >>> v
///     Vec(3, 6)
pub fn vec_scale(v: *Vec, k: i64) void {
    v.x *= k;
    v.y *= k;
}

/// `v` itself: the object back from its instance data (`VecType.object`).
///
/// Type
///     return: Vec
///
/// Example
///     >>> v = Vec()
///     >>> vec_self(v) is v
///     True
pub fn vec_self(v: *const Vec) *Object {
    const obj = VecType.object(v);
    py.incref(obj);
    return obj;
}

/// The label of `v`, or `None` without one (`v` is `None` or not given).
///
/// Type
///     return: object
///
/// Example
///     >>> label_of(Labeled('a'))
///     'a'
///     >>> label_of(None)
pub fn label_of(v: ?*const Labeled) *Object {
    const label = if (v) |d| d.label orelse py.none() else py.none();
    py.incref(label);
    return label;
}

/// The sum of the bytes of `data` (any bytes-like object).
///
/// Example
///     >>> buffer_sum(b'abc')
///     294
///     >>> buffer_sum(memoryview(b'abc')[1:])
///     197
pub fn buffer_sum(data: py.Buffer) u64 {
    var total: u64 = 0;
    for (data.data) |b| total += b;
    return total;
}

/// The length of `data`, or `None` without one.
///
/// Example
///     >>> buffer_len(bytearray(5))
///     5
///     >>> buffer_len(None)
pub fn buffer_len(data: ?py.Buffer) ?usize {
    return if (data) |d| d.data.len else null;
}

/// Sets every byte of `buf` (a writable bytes-like object) to `value`; returns how many.
///
/// Example
///     >>> b = bytearray(3)
///     >>> buffer_fill(b, 7)
///     3
///     >>> b
///     bytearray(b'\x07\x07\x07')
pub fn buffer_fill(buf: py.WritableBuffer, value: u8) usize {
    @memset(buf.data, value);
    return buf.data.len;
}

/// The sum of `values` (a list, tuple, range, ... of `u32`s).
///
/// Example
///     >>> seq_sum([1, 2, 3])
///     6
///     >>> seq_sum(range(4))
///     6
pub fn seq_sum(values: py.Sequence(u32)) u64 {
    var total: u64 = 0;
    for (values.items) |v| total += v;
    return total;
}

/// `parts` joined: `b''.join(parts)`.
///
/// Type
///     return: bytes
///
/// Example
///     >>> seq_join([b'ab', b'c'])
///     b'abc'
pub fn seq_join(parts: py.Sequence(py.Bytes)) Error!*Object {
    var n: usize = 0;
    for (parts.items) |p| n += p.data.len;
    // cast: the parts are in memory, so their total fits `isize`
    const out = c.PyBytes_FromStringAndSize(null, @intCast(n)) orelse return error.PythonError;
    var at: [*]u8 = c.PyBytes_AsString(out).?;
    for (parts.items) |p| {
        @memcpy(at[0..p.data.len], p.data);
        at += p.data.len;
    }
    return out;
}

/// The squared lengths of `vs` (`Vec`s), added up.
///
/// Example
///     >>> seq_norm2([Vec(3, 4), Vec(1, 0)])
///     26
pub fn seq_norm2(vs: py.Sequence(*const Vec)) i64 {
    var total: i64 = 0;
    for (vs.items) |v| total += vec_norm2(v);
    return total;
}

/// The total length of `bufs` (bytes-like objects), or `None` without them.
///
/// Example
///     >>> seq_buffer_len([b'ab', bytearray(3)])
///     5
pub fn seq_buffer_len(bufs: ?py.Sequence(py.Buffer)) ?usize {
    const list = bufs orelse return null;
    var n: usize = 0;
    for (list.items) |b| n += b.data.len;
    return n;
}

/// What `hold` keeps (`take`) until the next `hold`.
var held: struct {
    buf: ?py.WritableBuffer = null,
    data: ?py.Buffer = null,
    bufs: ?py.Sequence(py.Buffer) = null,
} = .{};

/// Releases what the last call kept, then keeps `buf`, `data` and `bufs` (`take`): locked until the
/// next call. `hold()` only releases.
///
/// Example
///     >>> b = bytearray(3)
///     >>> hold(b)
///     >>> b.append(1)
///     BufferError: Existing exports of data: object cannot be re-sized
///     >>> hold()
///     >>> b.append(1)
pub fn hold(buf: ?py.WritableBuffer, data: ?py.Buffer, bufs: ?py.Sequence(py.Buffer)) Error!void {
    if (held.buf) |b| b.deinit();
    if (held.data) |d| d.deinit();
    if (held.bufs) |l| l.deinit();
    held = .{};
    if (buf) |b| held.buf = try b.take();
    if (data) |d| held.data = try d.take();
    if (bufs) |l| held.bufs = try l.take();
}

/// What `own` keeps.
var owned: struct {
    buf: ?py.OwnedWritableBuffer = null,
    data: ?py.OwnedBuffer = null,
} = .{};

/// Releases what the last call kept, then keeps `buf` and `data` as they come (`py.OwnedWritableBuffer` /
/// `py.OwnedBuffer`, no second view): locked until the next call. `own()` only releases; with
/// `drop=True` the function releases them itself before returning.
///
/// Example
///     >>> b = bytearray(3)
///     >>> own(b)
///     >>> b.append(1)
///     BufferError: Existing exports of data: object cannot be re-sized
///     >>> own()
///     >>> b.append(1)
pub fn own(buf: ?py.OwnedWritableBuffer, data: ?py.OwnedBuffer, drop: ?bool) void {
    if (owned.buf) |b| b.deinit();
    if (owned.data) |d| d.deinit();
    owned = .{};
    if (drop orelse false) {
        if (buf) |b| b.deinit();
        if (data) |d| d.deinit();
        return;
    }
    owned = .{ .buf = buf, .data = data };
}

/// The sum of the bytes of `data`, kept by the call (`py.OwnedBuffer`) and released by it.
///
/// Example
///     >>> owned_sum(b'abc')
///     294
pub fn owned_sum(data: py.OwnedBuffer) u64 {
    defer data.deinit();
    var total: u64 = 0;
    for (data.data) |b| total += b;
    return total;
}

/// `v` converted, nothing else: the cheapest call for `tools/bench.py` (Liburing's `io_uring_prep_nop(sqe)`).
///
/// Example
///     >>> bench_nop(Vec())
pub fn bench_nop(v: *Vec) void {
    _ = v;
}

/// The arguments of Liburing's `io_uring_prep_recv(sqe, sockfd, buf, flags)`, converted and released
/// after the call (`tools/bench.py`); returns `fd`.
///
/// Example
///     >>> bench_recv(Vec(), -1, bytearray(4), 0)
///     -1
pub fn bench_recv(v: *Vec, fd: i32, buf: ?py.WritableBuffer, flags: ?i32) i32 {
    _ = .{ v, buf, flags };
    return fd;
}

/// What `bench_recv_take` / `bench_recv_owned` keep, until their next call (as an io_uring recv keeps
/// its buffer until the completion).
var bench_kept: struct {
    take: ?py.WritableBuffer = null,
    owned: ?py.OwnedWritableBuffer = null,
} = .{};

/// `bench_recv`, keeping `buf` until the next call with a second view (`take`); `buf=None` only
/// releases (`tools/bench.py`).
///
/// Example
///     >>> bench_recv_take(Vec(), -1, bytearray(4))
///     -1
pub fn bench_recv_take(v: *Vec, fd: i32, buf: ?py.WritableBuffer, flags: ?i32) Error!i32 {
    _ = .{ v, flags };
    if (bench_kept.take) |b| b.deinit();
    bench_kept.take = null;
    if (buf) |b| bench_kept.take = try b.take();
    return fd;
}

/// `bench_recv`, keeping `buf` until the next call as it comes (`py.OwnedWritableBuffer`); `buf=None`
/// only releases (`tools/bench.py`).
///
/// Example
///     >>> bench_recv_owned(Vec(), -1, bytearray(4))
///     -1
pub fn bench_recv_owned(v: *Vec, fd: i32, buf: ?py.OwnedWritableBuffer, flags: ?i32) i32 {
    _ = .{ v, flags };
    if (bench_kept.owned) |b| b.deinit();
    bench_kept.owned = buf;
    return fd;
}

/// The arguments of Liburing's `io_uring_prep_send(sqe, sockfd, buf, flags)`, converted and released
/// after the call (`tools/bench.py`); returns `fd`.
///
/// Example
///     >>> bench_send(Vec(), -1, b'abc')
///     -1
pub fn bench_send(v: *Vec, fd: i32, buf: ?py.Buffer, flags: ?i32) i32 {
    _ = .{ v, buf, flags };
    return fd;
}

/// A `Secret` (a hidden class) holding `value`.
///
/// Example
///     >>> type(make_secret(3)).__name__
///     'Secret'
pub fn make_secret(value: i64) Error!*Object {
    return classes.secret(value);
}

/// The value of `s` (a `Secret`, `Any` in the stub).
///
/// Example
///     >>> secret_value(make_secret(3))
///     3
pub fn secret_value(s: *const Secret) i64 {
    return s.read(s);
}

/// `res` itself when it is `>= 0`, else `OSError` for the errno `-res` (`py.checkErrno`).
///
/// Example
///     >>> check_errno(3)
///     3
///     >>> check_errno(-2)
///     FileNotFoundError: [Errno 2] No such file or directory
pub fn check_errno(res: i64) Error!i64 {
    return py.checkErrno(res);
}

/// `big` and `small` back: an `i64` takes the fast path, a larger `u64` the one past it.
///
/// Example
///     >>> int_pair(2**64 - 1, -128)
///     (18446744073709551615, -128)
///     >>> int_pair(-1, 0)
///     OverflowError: `int_pair(big)` = -1 is out of range 0..18446744073709551615
pub fn int_pair(big: u64, small: i8) struct { u64, i8 } {
    return .{ big, small };
}

// --- module constants (`py.addConstants`) -------------------------------------------------

/// A small constant.
pub const ANSWER = 42;
/// A negative one.
pub const NEGATIVE: i32 = -5;
/// One past `i64`: an int `PyModule_AddIntConstant` could not take.
pub const ALL_ONES: u64 = std.math.maxInt(u64);
/// A float.
pub const PI = 3.25;
/// A `bool`.
pub const FLAG = true;
/// A string.
pub const NAME = "setu";
/// The empty string (Liburing's `LIBURING_HAVE_DATA64`).
pub const EMPTY = "";
/// Not UPPER_CASE, so not exported.
pub const lower_case = 7;
/// A `pub var`, so not a constant.
pub var COUNTER: u32 = 0;

/// Its UPPER_CASE fields are module constants (`RED`, ...); `other` is not.
pub const Color = enum(u8) {
    RED = 1,
    GREEN,
    BLUE = 9,
    other,
};
