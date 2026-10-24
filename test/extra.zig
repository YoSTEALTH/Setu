//! The exceptions of `setu_classes` (`setu.Exception`) and the functions that raise them, an
//! `IntEnum`, and what the `Module.from` filters drop (`.exclude`, `.prefixes`, `.only`; see
//! `setu_classes.zig`). `class_test.py` drives them.

const setu = @import("setu");

const c = setu.c;
const py = setu.py;
const Error = py.Error;

/// An `OSError` of the extension's own: `ExtraError(errno, msg)` sets `.errno` / `.strerror`.
pub const ExtraError = setu.Exception(.{
    .doc = "An `OSError` of the extension's own: `ExtraError(errno, msg)` sets `.errno` / `.strerror`.",
    .base = .OSError,
});

/// A plain `Exception` subclass.
pub const PlainError = setu.Exception(.{ .doc = "A plain `Exception` subclass." });

/// Raises `ExtraError(errno, msg)` (`raiseWith`).
///
/// Example
///     >>> raise_extra(95, 'not here')
///     ExtraError: [Errno 95] not here
pub fn raise_extra(errno: i32, msg: []const u8) Error!void {
    return ExtraError.raiseWith(.{ errno, msg });
}

/// Raises `PlainError` with a formatted message (`raise`).
///
/// Example
///     >>> raise_plain(3)
///     PlainError: plain 3
pub fn raise_plain(n: i64) Error!void {
    return PlainError.raise("plain {d}", .{n});
}

/// Is `exc` a `PlainError` (an instance or the class, or a subclass)? (`matches`)
///
/// Example
///     >>> is_plain(PlainError('x')), is_plain(ValueError())
///     (True, False)
pub fn is_plain(exc: *c.Object) bool {
    return PlainError.matches(exc);
}

/// How a call ended: an `IntEnum` (this file's `from` entry has `.enums = .int_enum`), every field a
/// member.
pub const Mode = enum(u8) { plain = 1, with_errno = 2, OTHER = 7 };

/// A function the `from` entry drops by name (`.exclude`).
pub fn excluded() i64 {
    return 0;
}

/// `1`; replaced by the root file's own `overridden` (`Module.methods`), which gives `2`.
pub fn overridden() i64 {
    return 1;
}

/// Constants taken by prefix (`.prefixes = &.{"K_"}`): `K_ONE`, `K_TWO`, not `OTHER`.
pub const kernel = struct {
    pub const K_ONE = 1;
    pub const K_TWO = 2;
    pub const OTHER = 3;
};

/// Constants taken by name (`.only = &.{"PICKED"}`): `PICKED`, not `DROPPED`.
pub const picked = struct {
    pub const PICKED = 5;
    pub const DROPPED = 6;
};
