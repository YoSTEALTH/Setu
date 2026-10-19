//! Setu (सेतु, "bridge"): The generic Zig ⇄ CPython binding layer.
//!
//! Targets CPython 3.15 / 3.15t only (no backports), using what 3.15 offers:
//! PEP 793 module export (`PyModExport_<name>` + `PySlot`), PEP 697 type data
//! (`Py_tp_extra_basicsize`), free-threading (`Py_MOD_GIL_NOT_USED` / `Py_MOD_GIL_USED`,
//! `PyCriticalSection`). No `Python.h`: the C API is declared by hand in
//! `capi.zig`, with every object opaque.
//!
//!     const setu = @import("setu");
//!     const c = setu.c;   // the C API
//!     const py = setu.py; // `exportFns`, conversions, errors
//!     pub const PointType = setu.Class(Point, @embedFile("point.zig")); // struct -> type
//!     const pyi = setu.stub.class(PointType); // `.pyi` text (type stubs)
//!
//! It must not depend on Shakti (`build.zig` gives it no such import), so it
//! can become a separate dependency later.

pub const c = @import("capi.zig");
pub const py = @import("py.zig");
pub const stub = @import("stub.zig");
const class = @import("class.zig");

pub const Class = class.Class;
pub const Instance = class.Instance;
pub const CallArgs = class.CallArgs;
pub const Options = class.Options;
pub const Send = class.Send;
pub const Poll = class.Poll;
pub const Visit = class.Visit;
