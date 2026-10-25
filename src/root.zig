//! Setu (सेतु, "bridge"): The generic Zig ⇄ CPython binding layer.
//!
//! One binary for CPython 3.14, 3.14t, 3.15, 3.15t and later (a `cp314.cp315-abi3.abi3t.cp314t.cp315t`
//! wheel): only the 3.15 stable ABI for free-threading (abi3t, PEP 803) that 3.14 also exports is used.
//! `py.exportModule` gives both entry points (PEP 793 `PyModExport_<name>` for 3.15+,
//! `PyInit_<name>` for 3.14), types come from `PyType_Spec` with PEP 697 type data, and
//! free-threading is on (`Py_MOD_GIL_NOT_USED` / `Py_MOD_GIL_USED`, `PyCriticalSection`).
//! No `Python.h`: the C API is declared by hand in `capi.zig`, with every object opaque.
//!
//!     const setu = @import("setu");
//!     const c = setu.c;   // the C API
//!     const py = setu.py; // `exportModule`, conversions, errors
//!     pub const PointType = setu.Class(Point, @embedFile("point.zig")); // struct -> type
//!     pub const BadPoint = setu.Exception(.{ .doc = "Not a point.", .base = .ValueError });
//!
//!     // the root file: Setu finds the functions, classes, exceptions, constants of `from`
//!     pub const module: setu.Module = .{ .name = "point", .from = &.{
//!         .{ .ns = @import("point.zig"), .source = @embedFile("point.zig") },
//!     } };
//!     comptime {
//!         py.exportModule(module);
//!     }
//!     // `setu.stub.module(writer, module)` writes the `.pyi` (type stubs); `addStubs` in `build.zig`
//!
//! Setu never imports Shakti or Liburing: they depend on it (`b.dependency("setu", .{})`).

pub const c = @import("capi.zig");
pub const py = @import("py.zig");
pub const stub = @import("stub.zig");
const class = @import("class.zig");
const exception = @import("exception.zig");
const scan = @import("scan.zig");

pub const Class = class.Class;
pub const Instance = class.Instance;
pub const CallArgs = class.CallArgs;
pub const Send = class.Send;
pub const Poll = class.Poll;
pub const Visit = class.Visit;
pub const Exception = exception.Exception;
pub const ExceptionOptions = exception.ExceptionOptions;
pub const Kind = scan.Kind;
pub const From = scan.From;
pub const Module = py.Module;

/// Is this Setu's stub generator (`addStubs`), which has no libpython? See `py.stubgen`.
pub const stubgen = py.stubgen;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("args.zig");
    _ = @import("class.zig");
    _ = @import("convert.zig");
    _ = @import("exception.zig");
    _ = @import("export.zig");
    _ = @import("py.zig");
    _ = @import("raise.zig");
    _ = @import("scan.zig");
    _ = @import("source.zig");
    _ = @import("stub.zig");
}
