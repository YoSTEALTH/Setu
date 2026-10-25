//! Exception types: `setu.Exception(.{ .doc, .base })` declares a Python exception class of the
//! extension, created in `Py_mod_exec` (by `py.exportModule` for a `Module.from` entry, or by hand
//! with `create`) and raised from Zig with `raise` / `raiseWith`. Re-exported by `root.zig`.
//!
//! Example
//!     pub const UnsupportedError = setu.Exception(.{
//!         .doc = "The kernel does not support the operation.",
//!         .base = .OSError,
//!     });
//!
//!     return UnsupportedError.raiseWith(.{ -res, "IORING_OP_FUTEX_WAIT" });
//!
//!     >>> liburing.UnsupportedError.__mro__
//!     (<class 'liburing.UnsupportedError'>, <class 'OSError'>, <class 'Exception'>, ...)

const c = @import("capi.zig");
const py = @import("py.zig");
const class_zig = @import("class.zig");
const scan_zig = @import("scan.zig");

const Object = c.Object;
const Error = py.Error;

/// What `Exception` takes.
pub const ExceptionOptions = struct {
    /// The docstring (`__doc__`).
    doc: ?[:0]const u8 = null,
    /// The base class: the name of one of `c.PyExc_*` (`.OSError` is `c.PyExc_OSError`), which is also
    /// what the stub writes.
    base: @EnumLiteral() = .Exception,
};

/// A Python exception class (see the top of this file). Its Python name is the name of the `pub const`
/// that holds it when a `Module.from` entry finds it, else the `name` given to `create`; its
/// `__module__` is the extension's (`Module.name`).
///
/// Note
///     - Zig gives two calls with the same `options` the same type, so two exceptions with the same
///       `doc` and `base` would share one `tp`: give each its own `doc` (the scan of `Module.from`
///       refuses one type under two names).
pub fn Exception(comptime options: ExceptionOptions) type {
    return struct {
        /// What the `Module.from` scan looks for.
        pub const setu_kind: scan_zig.Kind = .exception;
        /// The docstring, or `null`.
        pub const doc = options.doc;
        /// The base class as Python names it (`OSError`), for the stub.
        pub const base_name = @tagName(options.base);

        /// The exception class, set by `create`.
        pub var tp: ?*Object = null;

        /// Creates the class `<module>.<name>` and, with a `module`, adds it there as `name`.
        ///
        /// Example
        ///     >>> try UnsupportedError.create("UnsupportedError", module);
        pub fn create(comptime name: [:0]const u8, module: ?*Object) Error!void {
            const qualified = comptime blk: {
                const text = class_zig.moduleName(name) ++ "." ++ name;
                break :blk (text ++ "\x00")[0..text.len :0];
            };
            const base = @field(c, "PyExc_" ++ base_name);
            const t = c.PyErr_NewExceptionWithDoc(qualified, if (doc) |d| d.ptr else null, base, null) orelse
                return error.PythonError;
            tp = t; // keeps the new reference for the process lifetime
            if (module) |m| if (c.PyModule_AddObjectRef(m, name, t) < 0) return error.PythonError;
        }

        /// Raises the exception with a formatted message and returns `error.PythonError`.
        ///
        /// Example
        ///     >>> return CancelledError.raise("`{s}` was cancelled", .{name});
        pub fn raise(comptime fmt: []const u8, args: anytype) Error {
            return py.raise(tp.?, fmt, args);
        }

        /// Raises `Name(*args)` (each item converted like a result, see `py.raiseWith`) and returns
        /// `error.PythonError`. An `OSError` subclass raised with `.{ errno, msg }` gets `.errno`.
        ///
        /// Example
        ///     >>> return UnsupportedError.raiseWith(.{ 95, "not supported" });
        pub fn raiseWith(args: anytype) Error {
            return py.raiseWith(tp.?, args);
        }

        /// Is `exc` (an exception instance or class) this exception or a subclass of it?
        ///
        /// Example
        ///     >>> if (CancelledError.matches(exc)) return;
        pub fn matches(exc: ?*Object) bool {
            const t = tp orelse return false;
            return c.PyErr_GivenExceptionMatches(exc, t) != 0;
        }
    };
}

const testing = @import("testing.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

test "Exception: marker, doc and base name" {
    comptime {
        const E = Exception(.{ .doc = "Not supported.", .base = .OSError });
        testing.expect(E.setu_kind == .exception, "the `.exception` marker");
        testing.expectText(E.doc.?, "Not supported.");
        testing.expectText(E.base_name, "OSError");
        testing.expectText(Exception(.{}).base_name, "Exception");
        testing.expect(Exception(.{}).doc == null, "no doc");
    }
}
