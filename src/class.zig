//! Classes: a Zig struct describes a Python type, and `Class` generates the type's
//! slots, GC support, method table, properties and base type from it.
//!
//! The struct's fields are the instance data (behind `Py_tp_extra_basicsize`). Every
//! field needs a default value: a new object starts as `.{}`. A `?*Object` or
//! `[N]?*Object` field is an owned (strong) reference: `tp_traverse` visits it and
//! `tp_clear` / dealloc drop it, so the type gets `Py_TPFLAGS_HAVE_GC`. A borrowed
//! reference is a plain `*Object` field, which Setu never touches.
//!
//! Declarations the struct may have (`pub`):
//!
//!     name          "pkg.Name"; default `<setu_options.module>.<struct name>` (see `Options`)
//!     base          another `Class(...)`: the base type, created first
//!     basetype      true: Python classes may subclass it
//!     instantiable  false: Python can not call the type (Zig creates it with `new`)
//!     getset        extra `c.GetSetDef`s (no terminator), for properties built at comptime
//!     slots         extra `c.Slot`s (no terminator), for protocol slots Setu has no hook for
//!     stub          extra `.pyi` lines for the class body (`setu.stub`), for what `getset` /
//!                   `slots` add
//!     weakref       true: instances support `weakref.ref` (`Py_TPFLAGS_MANAGED_WEAKREF`)
//!     dict          true: instances get a `__dict__` for arbitrary attributes
//!                   (`Py_TPFLAGS_MANAGED_DICT`; makes the type GC-tracked)
//!     pickle        true: generated `__getstate__` / `__setstate__` (a tuple of the fields
//!                   of this type and its bases: ints, floats, `bool`s, `?*Object`s), so
//!                   `pickle` / `copy` work; unpickling calls `Type.__new__(Type)`
//!     plain_methods names of `pub fn`s that are methods though they start with `get_` / `set_`
//!                   (`.{"get_nowait"}`)
//!     type_params   "T" / "K, V": the class is generic, `Name[int]` gives a
//!                   `types.GenericAlias` (`__class_getitem__`), the stub says `class Name[T]:`
//!     NAME          an UPPER_CASE `pub const` int, float, `bool` or string: a class attribute
//!
//!     get_x / set_x       the property `x` (the getter's `///` doc is its docstring)
//!     __new__(self, ...)  runs in `tp_new`, after allocation and the field defaults
//!     __init__(self, ...) `tp_init`
//!     __traverse__(self, *Visit), __clear__(self), __del__(self)
//!                         extra GC / dealloc work, after the generated part
//!     __finalize__(self)  `tp_finalize` (PEP 442): runs once, before the object is cleared
//!                         (by dealloc or by the GC breaking a cycle), with every field still
//!                         set, so it may call Python (report, warn, ...); the bases' run after.
//!                         It must not raise: report errors itself (`c.PyErr_WriteUnraisable`).
//!                         The current exception is kept.
//!     __send__(self, arg) Send
//!                         an iterator / awaitable's step: `am_send`, `tp_iternext`
//!                         (`send(None)`, the return value as `StopIteration`) and `tp_iter`
//!                         (`self`)
//!     __await__(self)     `am_await`: the iterator `await obj` drives (often `self`)
//!     __poll__(self, sent: ?*Object) Poll
//!                         a native awaitable that yields itself to its event loop until it
//!                         is done: Setu generates `__await__` (`self`), `__send__` and the
//!                         "already awaited" check (instead of a `__send__` hook); see `Poll`
//!     __bool__(self)      `nb_bool`
//!     __repr__(self)      `tp_repr`
//!     __getitem__(self, key)
//!                         `mp_subscript`; `key` is converted like a method argument
//!                         (`*Object` keeps it raw, `*T` / `*const T` takes an instance)
//!     __setitem__(self, key, value), __delitem__(self, key)
//!                         `mp_ass_subscript` (the missing one raises `TypeError`)
//!     __len__(self) usize `mp_length`
//!     __contains__(self, item) bool
//!                         `sq_contains`; an `item` of another type is not contained
//!     __str__(self)       `tp_str`
//!     __eq__, __ne__, __lt__, __le__, __gt__, __ge__ (self, other) bool
//!                         `tp_richcompare`; an `other` of another type gives `NotImplemented`
//!                         (Python then tries the reflected operation); without `__ne__` it
//!                         is `not __eq__`. As in Python, `__eq__` without `__hash__` makes
//!                         the type unhashable.
//!     __hash__(self)      `tp_hash` (any int type; -1 becomes -2)
//!     __call__(self, ...) `tp_call`, arguments parsed like a method's
//!     __iter__(self), __next__(self) ?R
//!                         `tp_iter` / `tp_iternext` for an iterator without `__send__`;
//!                         `__next__` returns `null` when exhausted (`StopIteration`), and
//!                         without `__iter__` the iterator is its own (`self`)
//!     __add__(self, other), __radd__(self, other), __iadd__(self, other), ...
//!                         number operators: `add`, `sub`, `mul`, `truediv`, `floordiv`, `mod`,
//!                         `divmod`, `pow`, `lshift`, `rshift`, `and`, `or`, `xor`, `matmul`
//!                         (`__r*__` when the instance is on the right, `__i*__` in place: a
//!                         `void` result returns `self`); `other` as for comparisons
//!     __neg__, __pos__, __abs__, __invert__, __int__, __float__, __index__ (self)
//!                         unary operators / conversions (`__index__` / `__int__` return an
//!                         int, `__float__` a float)
//!     __getattr__(self, name)
//!                         `tp_getattro`, called when normal lookup raises `AttributeError`
//!     __setattr__(self, name, value), __delattr__(self, name)
//!                         `tp_setattro` (every assignment / deletion; the missing one does
//!                         the normal one, `c.PyObject_GenericSetAttr`)
//!     __get__(self, instance: ?*Object, owner: ?*Object)
//!                         `tp_descr_get` (`instance` is null when read from the class)
//!     __set__(self, instance: *Object, value), __delete__(self, instance: *Object)
//!                         `tp_descr_set`
//!     any other lowercase `pub fn`: a method, as with `py.exportFns` (keywords, `?T`,
//!                         `py.Rest`, `py.KwOnly`, `///` docs, `__text_signature__`): an
//!                         instance method when the first parameter is named `self`, a class
//!                         method when it is `cls: *c.TypeObject`, else a static method
//!
//! `self` is `*Object`, `*T` or `*const T`. `__new__` / `__init__` take their
//! arguments by name like a method (`_: py.KwOnly` and argument structs included), or a
//! single `CallArgs` for the raw tuple and dict. The type's `__text_signature__` comes from
//! `__init__` (else `__new__`), defaults included (see `py.Param`).
//! camelCase `pub fn`s are Zig-only helpers, as in `py.exportFns`. Hooks may return
//! `Error!R`; results are converted like a method's (`*Object` is a new reference).
//!
//! Example
//!     /// A point in the plane.
//!     pub const Point = struct {
//!         x: i64 = 0,
//!         y: i64 = 0,
//!         label: ?*Object = null, // owned, GC-visible
//!
//!         /// Sets the coordinates: `Point(x=0, y=0)`.
//!         pub fn __init__(self: *Point, a: struct { x: i64 = 0, y: i64 = 0 }) void {
//!             self.x = a.x;
//!             self.y = a.y;
//!         }
//!
//!         /// The `x` coordinate.
//!         pub fn get_x(self: *const Point) i64 {
//!             return self.x;
//!         }
//!
//!         /// Distance from the origin, squared.
//!         pub fn norm2(self: *const Point) i64 {
//!             return self.x * self.x + self.y * self.y;
//!         }
//!     };
//!     pub const PointType = setu.Class(Point, @embedFile("point.zig"));
//!
//!     // in the root file (the type is then `pkg.Point`):
//!     pub const setu_options: setu.Options = .{ .module = "pkg" };
//!
//!     // in `Py_mod_exec`:
//!     try PointType.create(module);

const std = @import("std");
const c = @import("capi.zig");
const py = @import("py.zig");

const Object = c.Object;
const Error = py.Error;

/// The raw arguments of a `tp_new` / `tp_init` call, for a `__new__` / `__init__`
/// that parses them itself.
///
/// Example
///     >>> pub fn __init__(self: *Object, a: setu.CallArgs) Error!void {
///     ...     const n = c.PyTuple_Size(a.args);
///     ...     ...
///     ... }
pub const CallArgs = struct { args: *Object, kwargs: ?*Object };

/// What `__traverse__` gets: `add` each object the instance owns beyond its
/// `?*Object` fields.
///
/// Example
///     >>> pub fn __traverse__(self: *const Point, v: *setu.Visit) setu.Visit.Error!void {
///     ...     for (self.keep) |k| try v.add(k.extra);
///     ... }
pub const Visit = struct {
    proc: c.VisitProc,
    arg: ?*anyopaque,
    /// The visitor's non-zero result, returned by `tp_traverse` after `error.Stop`.
    code: c_int = 0,

    pub const Error = error{Stop};

    /// Visits `obj` (`null` is skipped); `error.Stop` ends the traversal when the
    /// visitor asks for it.
    pub fn add(self: *Visit, obj: ?*Object) Visit.Error!void {
        const o = obj orelse return;
        const r = self.proc(o, self.arg);
        if (r != 0) {
            self.code = r;
            return error.Stop;
        }
    }
};

/// What `__send__` returns (or `Error!Send`, which raises): one step of an iterator or
/// awaitable. Both values are new references.
///
/// Example
///     >>> /// Yields `self` once, then returns `None`.
///     ... pub fn __send__(self: *Object, _: *Object) Error!setu.Send {
///     ...     const d = OnceType.data(self);
///     ...     if (d.done) return .{ .done = py.newNone() };
///     ...     d.done = true;
///     ...     py.incref(self);
///     ...     return .{ .next = self };
///     ... }
pub const Send = union(enum) {
    /// Yield this value (`PYGEN_NEXT`): an `await` passes it up to the event loop.
    next: *Object,
    /// Finished with this value (`PYGEN_RETURN`): what `await` / `yield from` gives.
    done: *Object,
};

/// What `__poll__` returns (or `Error!Poll`, which raises): is the awaitable done?
///
/// Example
///     >>> /// A timer: `await Timer(deadline)` waits in the loop until `deadline` has passed.
///     ... pub fn __poll__(self: *Timer, sent: ?*Object) Error!setu.Poll {
///     ...     if (sent == null) return .pending; // first send: hand `self` to the loop
///     ...     if (now() < self.deadline) return .pending; // woken early: wait again
///     ...     return .{ .ready = py.newNone() };
///     ... }
///
/// Note
///     - `sent` is `null` on the first send (nothing waited for yet), else the value the
///       event loop sent back in (`None` from `next()`).
///     - `.pending` yields the awaitable itself, so the loop knows what to resume.
///     - After `.ready` or an error, awaiting it again raises `RuntimeError`.
pub const Poll = union(enum) {
    /// Not done: yield `self` to the event loop, which sends into it again later.
    pending,
    /// Done with this value (a new reference): what `await` gives.
    ready: *Object,
};

/// Where a `__poll__` awaitable is (Setu's own field next to the instance data).
const Phase = enum(u8) { fresh, waiting, done };

/// How a field of the instance data holds Python objects.
const Owned = enum { none, one, array };

/// `.one` for `?*Object`, `.array` for `[N]?*Object`, else `.none`.
fn owned(comptime F: type) Owned {
    if (F == ?*Object) return .one;
    if (@typeInfo(F) == .array and @typeInfo(F).array.child == ?*Object) return .array;
    return .none;
}

/// The comparison hooks, indexed by `Py_LT` ... `Py_GE`.
const compare_hooks = [_][]const u8{ "__lt__", "__le__", "__eq__", "__ne__", "__gt__", "__ge__" };

/// A number operator: its name in the hooks (`__add__`, `__radd__`, `__iadd__`) and slots.
const NumberOp = struct { name: []const u8, slot: u16, inplace: u16 };

/// The binary number operators (`__<name>__`, `__r<name>__`, `__i<name>__`).
pub const number_ops = [_]NumberOp{
    .{ .name = "add", .slot = c.Py_nb_add, .inplace = c.Py_nb_inplace_add },
    .{ .name = "sub", .slot = c.Py_nb_subtract, .inplace = c.Py_nb_inplace_subtract },
    .{ .name = "mul", .slot = c.Py_nb_multiply, .inplace = c.Py_nb_inplace_multiply },
    .{ .name = "truediv", .slot = c.Py_nb_true_divide, .inplace = c.Py_nb_inplace_true_divide },
    .{ .name = "floordiv", .slot = c.Py_nb_floor_divide, .inplace = c.Py_nb_inplace_floor_divide },
    .{ .name = "mod", .slot = c.Py_nb_remainder, .inplace = c.Py_nb_inplace_remainder },
    .{ .name = "divmod", .slot = c.Py_nb_divmod, .inplace = 0 },
    .{ .name = "pow", .slot = c.Py_nb_power, .inplace = c.Py_nb_inplace_power },
    .{ .name = "lshift", .slot = c.Py_nb_lshift, .inplace = c.Py_nb_inplace_lshift },
    .{ .name = "rshift", .slot = c.Py_nb_rshift, .inplace = c.Py_nb_inplace_rshift },
    .{ .name = "and", .slot = c.Py_nb_and, .inplace = c.Py_nb_inplace_and },
    .{ .name = "or", .slot = c.Py_nb_or, .inplace = c.Py_nb_inplace_or },
    .{ .name = "xor", .slot = c.Py_nb_xor, .inplace = c.Py_nb_inplace_xor },
    .{ .name = "matmul", .slot = c.Py_nb_matrix_multiply, .inplace = c.Py_nb_inplace_matrix_multiply },
};

/// The unary number hooks and their slots.
pub const unary_ops = [_]struct { []const u8, u16 }{
    .{ "__neg__", c.Py_nb_negative },  .{ "__pos__", c.Py_nb_positive }, .{ "__abs__", c.Py_nb_absolute },
    .{ "__invert__", c.Py_nb_invert }, .{ "__int__", c.Py_nb_int },      .{ "__float__", c.Py_nb_float },
    .{ "__index__", c.Py_nb_index },
};

/// Names Setu handles itself instead of exporting them as methods.
const hooks = blk: {
    var out: []const []const u8 = &.{
        "__new__",     "__init__",    "__traverse__", "__clear__",    "__del__",     "__finalize__",
        "__send__",    "__await__",   "__bool__",     "__repr__",     "__getitem__", "__poll__",
        "__setitem__", "__delitem__", "__len__",      "__contains__", "__str__",     "__hash__",
        "__call__",    "__iter__",    "__next__",     "__getattr__",  "__setattr__", "__delattr__",
        "__get__",     "__set__",     "__delete__",
    };
    out = out ++ compare_hooks;
    for (number_ops) |op| out = out ++ .{ "__" ++ op.name ++ "__", "__r" ++ op.name ++ "__", "__i" ++ op.name ++ "__" };
    for (unary_ops) |op| out = out ++ .{op[0]};
    break :blk out;
};

/// The number hooks (binary, reflected, in-place, unary), in stub order.
pub const number_names = blk: {
    var out: []const []const u8 = &.{};
    for (number_ops) |op| out = out ++ .{ "__" ++ op.name ++ "__", "__r" ++ op.name ++ "__", "__i" ++ op.name ++ "__" };
    for (unary_ops) |op| out = out ++ .{op[0]};
    break :blk out;
};

/// Is `name` one of the hooks Setu turns into slots?
pub fn isHook(comptime name: []const u8) bool {
    for (hooks) |h| if (std.mem.eql(u8, name, h)) return true;
    return false;
}

/// The declarations above (`name`, `getset`, ...): settings, never methods.
pub const settings = [_][]const u8{
    "name",        "base",          "basetype", "instantiable", "getset",
    "slots",       "stub",          "weakref",  "dict",         "pickle",
    "type_params", "plain_methods",
};

/// Is the declaration `name` of `T` a class attribute: an UPPER_CASE `pub const` int,
/// float, `bool` or string?
pub fn isClassAttr(comptime T: type, comptime name: []const u8) bool {
    var letter = false;
    for (name) |ch| {
        if (std.ascii.isLower(ch)) return false;
        if (std.ascii.isUpper(ch)) letter = true;
    }
    if (!letter) return false;
    const V = @TypeOf(@field(T, name));
    return switch (@typeInfo(V)) {
        .int, .comptime_int, .float, .comptime_float, .bool => true,
        .pointer => |p| p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8,
        else => false,
    };
}

/// The field types `pickle = true` can save: ints, floats, `bool`s and owned objects.
fn picklable(comptime F: type) bool {
    return switch (@typeInfo(F)) {
        .int, .float, .bool => true,
        else => F == ?*Object,
    };
}

/// Is the `pub fn name` of `T` a Python method (not a hook, property, setting or helper)?
pub fn isMethod(comptime T: type, comptime name: []const u8) bool {
    // Settings first: `@TypeOf` of `getset` would pull its getters into the program.
    for (settings) |n| if (std.mem.eql(u8, name, n)) return false;
    if (!py.isExported(T, name)) return false;
    if (isHook(name)) return false;
    return !isAccessor(T, name);
}

/// Is the `pub fn name` of `T` a property getter (exported `get_x`, see `isAccessor`)?
pub fn isGetter(comptime T: type, comptime name: []const u8) bool {
    return std.mem.startsWith(u8, name, "get_") and isAccessor(T, name) and py.isExported(T, name);
}

/// Is the `pub fn name` of `T` a property getter / setter: named `get_x` / `set_x`, and not
/// listed in `T.plain_methods` (a method whose name starts like one, e.g. `get_nowait`)?
pub fn isAccessor(comptime T: type, comptime name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "get_") and !std.mem.startsWith(u8, name, "set_")) return false;
    if (@hasDecl(T, "plain_methods")) for (T.plain_methods) |m| if (std.mem.eql(u8, m, name)) return false;
    return true;
}

/// The last dotted part of `name` (`"pkg.Point"` -> `"Point"`).
fn shortName(comptime name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[dot + 1 ..];
}

/// Settings for every `Class`, declared in the root file as `pub const setu_options`
/// (like `std_options`).
pub const Options = struct {
    /// The module a type names as its `__module__` (`"pkg"` makes `Point` `pkg.Point`),
    /// unless the struct declares `name`.
    module: []const u8,
};

/// The Python type name of `T`: `T.name`, else `<setu_options.module>.<struct name>`.
fn typeName(comptime T: type) [:0]const u8 {
    if (@hasDecl(T, "name")) return T.name;
    const root = @import("root");
    if (!@hasDecl(root, "setu_options")) @compileError(@typeName(T) ++
        ": a `setu.Class` needs `pub const name`, or `pub const setu_options: setu.Options` in the root file");
    const text = root.setu_options.module ++ "." ++ shortName(@typeName(T));
    return (text ++ "\x00")[0..text.len :0];
}

/// `(a, b=0, *, c=None)` for `T`: the parameters of its `__init__` (else `__new__`) hook
/// in `body`; null without either or for a `CallArgs` hook.
fn textSignature(comptime T: type, comptime body: []const u8) ?[]const u8 {
    const hook = if (@hasDecl(T, "__init__")) "__init__" else if (@hasDecl(T, "__new__")) "__new__" else return null;
    const f = @field(T, hook);
    const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
    if (params.len == 2 and params[1].? == CallArgs) return null;
    return "(" ++ py.paramText(f, true, hook, body) ++ ")";
}

/// The `Class` type for the Zig struct `T` (declared in `source`, its file's
/// `@embedFile`); see the top of this file.
///
/// Note
///     - Declare it once (`pub const PointType = setu.Class(Point, @embedFile("point.zig"))`)
///       and use that name everywhere: it holds the type object (`tp`).
pub fn Class(comptime T: type, comptime source: []const u8) type {
    @setEvalBranchQuota(1_000_000);
    const info = @typeInfo(T).@"struct";
    // `T`'s own part of `source`, so methods of other structs in the file don't match.
    const head = "const " ++ shortName(@typeName(T)) ++ " = struct {";
    const at = std.mem.indexOf(u8, source, head) orelse @compileError("no `" ++ head ++ "` in source");
    const body = source[at..];
    const poll = @hasDecl(T, "__poll__");
    if (poll and @hasDecl(T, "__send__")) @compileError(@typeName(T) ++ ": `__poll__` generates `__send__`; give one");
    const sends = poll or @hasDecl(T, "__send__");
    if (sends and (@hasDecl(T, "__iter__") or @hasDecl(T, "__next__")))
        @compileError(@typeName(T) ++ ": `__send__` / `__poll__` generate `__iter__` and `__next__`");
    const has_compare = for (compare_hooks) |h| {
        if (@hasDecl(T, h)) break true;
    } else false;
    // Comparisons without `__eq__` / `__hash__` keep the inherited hash, as in Python.
    const keep_hash = has_compare and !@hasDecl(T, "__eq__") and !@hasDecl(T, "__hash__");
    const pickle = @hasDecl(T, "pickle") and T.pickle;
    if (pickle and @hasDecl(T, "instantiable") and !T.instantiable)
        @compileError(@typeName(T) ++ ": `pickle` needs an instantiable type (unpickling calls `__new__`)");

    return struct {
        const This = @This();

        /// The instance data struct.
        pub const Data = T;
        /// The Python type name (`pkg.Name`).
        pub const name = typeName(T);
        /// The base `Class`, or `void`.
        pub const Base = if (@hasDecl(T, "base")) T.base else void;
        /// Do instances support weak references (`weakref` here or in a base)?
        pub const weakref = (@hasDecl(T, "weakref") and T.weakref) or (Base != void and Base.weakref);
        /// Do instances have a `__dict__` (`dict` here or in a base)?
        pub const dict = (@hasDecl(T, "dict") and T.dict) or (Base != void and Base.dict);
        /// Does the type take part in GC (owned fields here or in a base, `__traverse__`, or
        /// a `__dict__`)?
        pub const gc = blk: {
            if (dict) break :blk true;
            if (Base != void and Base.gc) break :blk true;
            if (@hasDecl(T, "__traverse__")) break :blk true;
            for (info.field_types) |F| if (owned(F) != .none) break :blk true;
            break :blk false;
        };
        /// Can Python call the type (no `instantiable = false`)?
        pub const instantiable = !@hasDecl(T, "instantiable") or T.instantiable;
        /// `T`'s part of the source (its methods' docs and parameter names), for `setu.stub`.
        pub const decl_source = body;
        /// The `///` doc above the struct.
        pub const class_doc = py.docAbove(source, at);

        /// The type object, set by `create`.
        pub var tp: ?*c.TypeObject = null;

        /// What the type stores per instance: `T`, plus the phase of a `__poll__` awaitable.
        const Stored = struct {
            user: T = .{},
            phase: if (poll) Phase else void = if (poll) .fresh else {},
        };

        /// Where `Stored` sits in an instance: `PyObject_GetTypeData`'s offset, which is the
        /// same for every instance (the base's size, aligned), so it is looked up once.
        /// Threads may race to set it, all with the same value (atomic, so no torn reads).
        var offset: usize = 0;

        fn stored(obj: *Object) *Stored {
            var off = @atomicLoad(usize, &offset, .monotonic);
            if (off == 0) {
                off = @intFromPtr(py.typeData(Stored, obj, tp.?)) - @intFromPtr(obj);
                @atomicStore(usize, &offset, off, .monotonic);
            }
            return @ptrFromInt(@intFromPtr(obj) + off);
        }

        /// The instance data of `obj` (an instance of this type or a subclass).
        pub fn data(obj: *Object) *T {
            return &stored(obj).user;
        }

        /// Is `obj` an instance of this type (or a subclass)?
        pub fn check(obj: *Object) bool {
            return py.isInstance(obj, tp.?);
        }

        /// A new instance from Zig, with the bases' fields at their defaults and its own
        /// set to `value`. Works for types Python can not instantiate, too.
        ///
        /// Example
        ///     >>> const obj = try PointType.new(.{ .x = 1, .y = 2 });
        pub fn new(value: T) Error!*Object {
            const obj = c.PyType_GenericAlloc(tp.?, 0) orelse return error.PythonError;
            if (Base != void) Base.initDefaults(obj);
            stored(obj).* = .{ .user = value };
            return obj;
        }

        /// Sets every field of this type and its bases to its default.
        pub fn initDefaults(obj: *Object) void {
            if (Base != void) Base.initDefaults(obj);
            stored(obj).* = .{};
        }

        /// Creates the type object (after the base's), sets the class attributes and, with a
        /// `module`, adds it there.
        pub fn create(module: ?*Object) Error!void {
            if (Base != void) {
                const b = Base.tp orelse return py.raiseRuntimeError("base of `{s}` is not created yet", .{name});
                for (&type_slots) |*s| {
                    if (s.id == c.Py_tp_base) s.value = .{ .ptr = b };
                    if (keep_hash and s.id == c.Py_tp_hash) s.value = .{ .ptr = c.PyType_GetSlot(b, c.Py_tp_hash) };
                }
            }
            const t: *c.TypeObject = @ptrCast(c.PyType_FromSlots(&type_slots) orelse return error.PythonError);
            tp = t; // keeps the reference from `PyType_FromSlots` for the process lifetime
            inline for (info.decl_names) |n| if (comptime isClassAttr(T, n)) {
                const V = @TypeOf(@field(T, n));
                const value = switch (@typeInfo(V)) {
                    .comptime_int => @as(i64, @field(T, n)),
                    .comptime_float => @as(f64, @field(T, n)),
                    else => @field(T, n),
                };
                const v = try py.new(value);
                defer py.decref(v);
                if (c.PyObject_SetAttrString(@ptrCast(t), n, v) < 0) return error.PythonError;
            };
            if (module) |m| if (c.PyModule_AddType(m, t) < 0) return error.PythonError;
        }

        // --- hooks -------------------------------------------------------------------

        /// Calls the hook `f` (`__new__` / `__init__` / `__call__`) with `args` / `kwargs`,
        /// raw (`CallArgs`) or parsed by its parameter names; gives its result.
        fn callHook(
            comptime f: anytype,
            comptime hook: []const u8,
            obj: *Object,
            args: *Object,
            kwargs: ?*Object,
        ) Error!Result(f) {
            const F = @TypeOf(f);
            const params = @typeInfo(F).@"fn".param_types;
            var tuple: std.meta.ArgsTuple(F) = undefined;
            tuple[0] = py.selfArg(This, params[0].?, obj);
            if (params.len == 2 and params[1].? == CallArgs) {
                tuple[1] = .{ .args = args, .kwargs = kwargs };
            } else {
                const fname = comptime shortName(name);
                const plist = comptime py.paramList(f, 1, hook, body);
                const names = comptime py.paramNames(plist);
                const slots = try py.parseArgs(fname, names, 0, comptime py.positionalCount(plist), args, kwargs);
                try py.fillArgs(F, plist, fname, &slots, &tuple);
            }
            defer if (comptime !(params.len == 2 and params[1].? == CallArgs))
                py.releaseArgs(F, py.paramList(f, 1, hook, body), &tuple);
            const result = @call(.auto, f, tuple);
            if (@typeInfo(@TypeOf(result)) == .error_union) return result catch |err| {
                py.setError(err);
                return error.PythonError;
            };
            return result;
        }

        /// The `__new__` hooks of the bases, then this type's.
        pub fn runNew(obj: *Object, args: *Object, kwargs: ?*Object) Error!void {
            if (Base != void) try Base.runNew(obj, args, kwargs);
            if (@hasDecl(T, "__new__")) try callHook(T.__new__, "__new__", obj, args, kwargs);
        }

        /// Visits this type's owned objects, then the bases'.
        pub fn traverseAll(obj: *Object, v: *Visit) Visit.Error!void {
            const d = data(obj);
            inline for (info.field_names, info.field_types) |n, F| switch (comptime owned(F)) {
                .one => try v.add(@field(d, n)),
                .array => for (@field(d, n)) |o| try v.add(o),
                .none => {},
            };
            if (@hasDecl(T, "__traverse__"))
                try T.__traverse__(py.selfArg(This, @typeInfo(@TypeOf(T.__traverse__)).@"fn".param_types[0].?, obj), v);
            if (Base != void) try Base.traverseAll(obj, v);
        }

        /// Drops this type's owned objects (then `__clear__`), then the bases'.
        pub fn clearAll(obj: *Object) void {
            const d = data(obj);
            inline for (info.field_names, info.field_types) |n, F| switch (comptime owned(F)) {
                .one => if (@field(d, n)) |o| {
                    @field(d, n) = null;
                    py.decref(o);
                },
                .array => for (&@field(d, n)) |*slot| if (slot.*) |o| {
                    slot.* = null;
                    py.decref(o);
                },
                .none => {},
            };
            if (@hasDecl(T, "__clear__")) T.__clear__(selfOf(T.__clear__, obj));
            if (Base != void) Base.clearAll(obj);
        }

        /// Does this type or a base have a `__finalize__` hook (so a `tp_finalize`)?
        pub const finalizes = @hasDecl(T, "__finalize__") or (Base != void and Base.finalizes);

        /// This type's `__finalize__`, then the bases'.
        pub fn finalizeAll(obj: *Object) void {
            if (@hasDecl(T, "__finalize__")) T.__finalize__(selfOf(T.__finalize__, obj));
            if (Base != void and Base.finalizes) Base.finalizeAll(obj);
        }

        /// This type's `__del__`, then the bases'.
        pub fn delAll(obj: *Object) void {
            if (@hasDecl(T, "__del__")) T.__del__(selfOf(T.__del__, obj));
            if (Base != void) Base.delAll(obj);
        }

        /// `obj` as the `self` parameter of the hook `f`.
        fn selfOf(comptime f: anytype, obj: *Object) @typeInfo(@TypeOf(f)).@"fn".param_types[0].? {
            return py.selfArg(This, @typeInfo(@TypeOf(f)).@"fn".param_types[0].?, obj);
        }

        // --- slots -------------------------------------------------------------------

        /// `tp_new`: allocates, sets the field defaults, runs the `__new__` hooks.
        fn tpNew(sub: *c.TypeObject, args: *Object, kwargs: ?*Object) callconv(.c) ?*Object {
            const obj = c.PyType_GenericAlloc(sub, 0) orelse return null;
            initDefaults(obj);
            runNew(obj, args, kwargs) catch {
                py.decref(obj);
                return null;
            };
            return obj;
        }

        /// `tp_finalize`: the `__finalize__` hooks, keeping the current exception.
        fn tpFinalize(obj: *Object) callconv(.c) void {
            const raised = c.PyErr_GetRaisedException();
            finalizeAll(obj);
            c.PyErr_SetRaisedException(raised);
        }

        /// `tp_init`: `__init__`.
        fn tpInit(obj: *Object, args: *Object, kwargs: ?*Object) callconv(.c) c_int {
            callHook(T.__init__, "__init__", obj, args, kwargs) catch return -1;
            return 0;
        }

        /// `tp_call`: `__call__`.
        fn tpCall(obj: *Object, args: *Object, kwargs: ?*Object) callconv(.c) ?*Object {
            return py.toPython(callHook(T.__call__, "__call__", obj, args, kwargs));
        }

        /// `tp_traverse`: the owned objects of this type and its bases, then the type.
        fn tpTraverse(obj: *Object, proc: c.VisitProc, arg: ?*anyopaque) callconv(.c) c_int {
            var v: Visit = .{ .proc = proc, .arg = arg };
            traverseAll(obj, &v) catch return v.code;
            // Python subclasses too: their `tp_traverse` leaves a base's managed dict to the base.
            if (dict) {
                const r = c.PyObject_VisitManagedDict(obj, proc, arg);
                if (r != 0) return r;
            }
            return proc(@ptrCast(c.Py_TYPE(obj)), arg);
        }

        /// `tp_clear`.
        fn tpClear(obj: *Object) callconv(.c) c_int {
            if (dict) c.PyObject_ClearManagedDict(obj);
            clearAll(obj);
            return 0;
        }

        /// `tp_dealloc`: untracks, clears weak references and the `__dict__`, clears, runs
        /// the `__del__` hooks, frees the object and drops its reference to the (heap) type.
        fn tpDealloc(obj: *Object) callconv(.c) void {
            // still tracked here, as CPython wants; `< 0`: the finalizer resurrected it
            if (finalizes and c.PyObject_CallFinalizerFromDealloc(obj) < 0) return;
            const t = c.Py_TYPE(obj);
            if (gc) c.PyObject_GC_UnTrack(obj);
            if (weakref) c.PyObject_ClearWeakRefs(obj);
            if (dict) c.PyObject_ClearManagedDict(obj);
            clearAll(obj);
            delAll(obj);
            const free: c.FreeFunc = @ptrCast(@alignCast(c.PyType_GetSlot(t, c.Py_tp_free).?));
            free(obj);
            py.decref(@ptrCast(t));
        }

        /// Calls `f(self)` (always inlined: these slots are hot) and gives its result
        /// without the error union; a raised error is `error.PythonError`.
        fn callSelf(comptime f: anytype, obj: *Object, rest: anytype) Error!Result(f) {
            const result = @call(.always_inline, f, .{selfOf(f, obj)} ++ rest);
            if (@typeInfo(@TypeOf(result)) == .error_union) return result catch |err| {
                py.setError(err);
                return error.PythonError;
            };
            return result;
        }

        /// The return type of `f`, without an error union.
        fn Result(comptime f: anytype) type {
            const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
            return if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
        }

        /// One step of the iterator: `__send__`, or for a `__poll__` awaitable its phases
        /// around `__poll__`.
        inline fn send(obj: *Object, arg: *Object) Error!Send {
            if (!poll) return callSelf(T.__send__, obj, .{arg});
            const s = stored(obj);
            const sent: ?*Object = switch (s.phase) {
                .fresh => null,
                .waiting => arg,
                .done => return py.raiseRuntimeError("cannot reuse an already awaited {s}", .{name}),
            };
            s.phase = .done; // stays done after `.ready` or an error
            switch (try callSelf(T.__poll__, obj, .{sent})) {
                .pending => {
                    s.phase = .waiting;
                    py.incref(obj);
                    return .{ .next = obj };
                },
                .ready => |v| return .{ .done = v },
            }
        }

        /// `am_send`: `__send__`.
        fn amSend(obj: *Object, arg: ?*Object, out: *?*Object) callconv(.c) c_int {
            switch (send(obj, arg orelse py.none()) catch return c.PYGEN_ERROR) {
                .next => |v| {
                    out.* = v;
                    return c.PYGEN_NEXT;
                },
                .done => |v| {
                    out.* = v;
                    return c.PYGEN_RETURN;
                },
            }
        }

        /// `tp_iternext`: `__send__(None)`; the return value becomes `StopIteration`.
        fn tpIternext(obj: *Object) callconv(.c) ?*Object {
            switch (send(obj, py.none()) catch return null) {
                .next => |v| return v,
                .done => |v| {
                    defer py.decref(v);
                    if (v != py.none()) c.PyErr_SetObject(c.PyExc_StopIteration, v);
                    return null;
                },
            }
        }

        /// `tp_iter` of a `__send__` type: the object itself.
        fn tpIterSelf(obj: *Object) callconv(.c) ?*Object {
            py.incref(obj);
            return obj;
        }

        /// `am_await`: `__await__`.
        fn amAwait(obj: *Object) callconv(.c) ?*Object {
            return py.toPython(callSelf(T.__await__, obj, .{}));
        }

        /// `nb_bool`: `__bool__`.
        fn nbBool(obj: *Object) callconv(.c) c_int {
            return @intFromBool(callSelf(T.__bool__, obj, .{}) catch return -1);
        }

        /// `tp_repr`: `__repr__`.
        fn tpRepr(obj: *Object) callconv(.c) ?*Object {
            return py.toPython(callSelf(T.__repr__, obj, .{}));
        }

        /// `mp_subscript`: `__getitem__`, with `key` converted to its parameter type.
        fn mpSubscript(obj: *Object, key: *Object) callconv(.c) ?*Object {
            const K = @typeInfo(@TypeOf(T.__getitem__)).@"fn".param_types[1].?;
            const what = "`" ++ comptime shortName(name) ++ "[key]`";
            const k = if (K == *Object) key else py.fromPythonAs(K, key, what) catch return null;
            return py.toPython(callSelf(T.__getitem__, obj, .{k}));
        }

        /// The type of parameter `i` of the hook `f`.
        fn ParamOf(comptime f: anytype, comptime i: usize) type {
            return @typeInfo(@TypeOf(f)).@"fn".param_types[i].?;
        }

        /// `obj` as the hook parameter type `P`: `*Object` as is, an instance's data for `*T` /
        /// `*const T` (else `TypeError`), `null` for `None` with a `?P`, else `fromPythonAs`.
        fn argAs(comptime P: type, obj: *Object, comptime what: []const u8) Error!P {
            if (P == *Object or P == ?*Object) return obj;
            if (P == *T or P == *const T) {
                if (check(obj)) return data(obj);
                return py.raiseTypeError("{s} must be `{s}`", .{ what, comptime shortName(name) });
            }
            if (@typeInfo(P) == .optional) {
                if (obj == py.none()) return null;
                return try argAs(@typeInfo(P).optional.child, obj, what);
            }
            return py.fromPythonAs(P, obj, what);
        }

        /// `argAs` for the other operand of a comparison / operator: `null` (not handled, so
        /// `NotImplemented`) when it has another type.
        fn otherAs(comptime P: type, obj: *Object, comptime what: []const u8) Error!?P {
            return argAs(P, obj, what) catch |err| {
                if (c.PyErr_ExceptionMatches(c.PyExc_TypeError) == 0) return err;
                c.PyErr_Clear();
                return null;
            };
        }

        /// Calls the binary hook `f(self, other)`: `NotImplemented` when `other` has another
        /// type, else the converted result.
        fn binary(comptime f: anytype, comptime hook: []const u8, obj: *Object, other: *Object) ?*Object {
            const what = "`" ++ comptime shortName(name) ++ "." ++ hook ++ "(other)`";
            const arg = (otherAs(ParamOf(f, 1), other, what) catch return null) orelse return py.newNotImplemented();
            return py.toPython(callSelf(f, obj, .{arg}));
        }

        /// `tp_str`: `__str__`.
        fn tpStr(obj: *Object) callconv(.c) ?*Object {
            return py.toPython(callSelf(T.__str__, obj, .{}));
        }

        /// `tp_richcompare`: the comparison hooks; `!=` is `not ==` without `__ne__`.
        fn tpRichcompare(obj: *Object, other: *Object, op: c_int) callconv(.c) ?*Object {
            switch (op) {
                inline c.Py_LT...c.Py_GE => |o| {
                    const hook = compare_hooks[o];
                    if (@hasDecl(T, hook)) return binary(@field(T, hook), hook, obj, other);
                    if (o == c.Py_NE and @hasDecl(T, "__eq__")) {
                        const eq = binary(T.__eq__, "__eq__", obj, other) orelse return null;
                        if (eq == py.notImplemented()) return eq;
                        defer py.decref(eq);
                        const r = c.PyObject_IsTrue(eq);
                        if (r < 0) return null;
                        return c.PyBool_FromLong(@intFromBool(r == 0));
                    }
                    return py.newNotImplemented();
                },
                else => return py.newNotImplemented(),
            }
        }

        /// `tp_hash`: `__hash__`, cut to `Py_hash_t` (-1 means an error, so it is -2).
        fn tpHash(obj: *Object) callconv(.c) c.ssize {
            const v = callSelf(T.__hash__, obj, .{}) catch return -1;
            if (@typeInfo(@TypeOf(v)) != .int) @compileError(@typeName(T) ++ ".__hash__ must return an int");
            const h: c.ssize = @truncate(@as(i128, v)); // cast: a hash keeps its low bits
            return if (h == -1) -2 else h;
        }

        /// `mp_length`: `__len__`.
        fn mpLength(obj: *Object) callconv(.c) c.ssize {
            const n = callSelf(T.__len__, obj, .{}) catch return -1;
            const N = @TypeOf(n);
            if (@typeInfo(N) != .int or @typeInfo(N).int.signedness != .unsigned)
                @compileError(@typeName(T) ++ ".__len__ must return an unsigned int");
            return std.math.cast(c.ssize, n) orelse {
                py.setString(c.PyExc_OverflowError, "`len()` of a `{s}` is too large", .{comptime shortName(name)});
                return -1;
            };
        }

        /// `sq_contains`: `__contains__`; an `item` of another type is not contained.
        fn sqContains(obj: *Object, item: *Object) callconv(.c) c_int {
            const what = "`" ++ comptime shortName(name) ++ ".__contains__(item)`";
            const arg = (otherAs(ParamOf(T.__contains__, 1), item, what) catch return -1) orelse return 0;
            return @intFromBool(callSelf(T.__contains__, obj, .{arg}) catch return -1);
        }

        /// `mp_ass_subscript`: `__setitem__` (a `value`) or `__delitem__` (none).
        fn mpAssSubscript(obj: *Object, key: *Object, value: ?*Object) callconv(.c) c_int {
            const what = "`" ++ comptime shortName(name) ++ "[key]`";
            if (value) |v| {
                if (!@hasDecl(T, "__setitem__")) {
                    const msg = "`{s}` does not support item assignment";
                    py.setString(c.PyExc_TypeError, msg, .{comptime shortName(name)});
                    return -1;
                }
                const f = T.__setitem__;
                const k = argAs(ParamOf(f, 1), key, what) catch return -1;
                const x = argAs(ParamOf(f, 2), v, "`" ++ comptime shortName(name) ++ "[key] = value`") catch return -1;
                _ = callSelf(f, obj, .{ k, x }) catch return -1;
                return 0;
            }
            if (!@hasDecl(T, "__delitem__")) {
                py.setString(c.PyExc_TypeError, "`{s}` does not support item deletion", .{comptime shortName(name)});
                return -1;
            }
            const k = argAs(ParamOf(T.__delitem__, 1), key, what) catch return -1;
            _ = callSelf(T.__delitem__, obj, .{k}) catch return -1;
            return 0;
        }

        /// `tp_iter`: `__iter__`.
        fn tpIter(obj: *Object) callconv(.c) ?*Object {
            return py.toPython(callSelf(T.__iter__, obj, .{}));
        }

        /// `tp_iternext`: `__next__`; `null` ends the iteration.
        fn tpNext(obj: *Object) callconv(.c) ?*Object {
            const r = callSelf(T.__next__, obj, .{}) catch return null;
            if (@typeInfo(@TypeOf(r)) != .optional) @compileError(@typeName(T) ++ ".__next__ must return `?R`");
            return py.toPython(r orelse return null);
        }

        /// `nb_<op>` for `__<op>__` (instance on the left) / `__r<op>__` (on the right).
        fn Binary(comptime op: []const u8) type {
            const fwd = "__" ++ op ++ "__";
            const rev = "__r" ++ op ++ "__";
            return struct {
                fn call(a: *Object, b: *Object) callconv(.c) ?*Object {
                    if (@hasDecl(T, fwd)) if (check(a)) {
                        const r = binary(@field(T, fwd), fwd, a, b) orelse return null;
                        if (r != py.notImplemented()) return r;
                        py.decref(r);
                    };
                    // As in Python, the reflected one only for operands of different types.
                    if (@hasDecl(T, rev)) if (check(b) and c.Py_TYPE(a) != c.Py_TYPE(b))
                        return binary(@field(T, rev), rev, b, a);
                    return py.newNotImplemented();
                }

                /// `nb_power`: `pow(a, b)`; a modulus raises `TypeError`.
                fn call3(a: *Object, b: *Object, m: *Object) callconv(.c) ?*Object {
                    if (m != py.none()) {
                        const msg = "`{s}` does not support pow() with a modulus";
                        py.setString(c.PyExc_TypeError, msg, .{comptime shortName(name)});
                        return null;
                    }
                    return call(a, b);
                }
            };
        }

        /// `nb_inplace_<op>` for `__i<op>__`; a `void` result returns `self`.
        fn Inplace(comptime op: []const u8) type {
            const hook = "__i" ++ op ++ "__";
            return struct {
                fn call(a: *Object, b: *Object) callconv(.c) ?*Object {
                    const f = @field(T, hook);
                    const what = "`" ++ comptime shortName(name) ++ "." ++ hook ++ "(other)`";
                    const arg = (otherAs(ParamOf(f, 1), b, what) catch return null) orelse
                        return py.newNotImplemented();
                    const r = callSelf(f, a, .{arg}) catch return null;
                    if (@TypeOf(r) == void) {
                        py.incref(a);
                        return a;
                    }
                    return py.toPython(r);
                }

                /// `nb_inplace_power` (`**=` passes no modulus).
                fn call3(a: *Object, b: *Object, _: *Object) callconv(.c) ?*Object {
                    return call(a, b);
                }
            };
        }

        /// `nb_<op>` for a unary hook (`__neg__`, `__int__`, ...).
        fn Unary(comptime hook: []const u8) type {
            return struct {
                fn call(a: *Object) callconv(.c) ?*Object {
                    const r = callSelf(@field(T, hook), a, .{}) catch return null;
                    const R = @TypeOf(r);
                    if ((comptime std.mem.eql(u8, hook, "__int__") or std.mem.eql(u8, hook, "__index__")) and
                        @typeInfo(R) != .int) @compileError(@typeName(T) ++ "." ++ hook ++ " must return an int");
                    if (comptime std.mem.eql(u8, hook, "__float__") and @typeInfo(R) != .float)
                        @compileError(@typeName(T) ++ ".__float__ must return a float");
                    return py.toPython(r);
                }
            };
        }

        /// `tp_getattro`: normal lookup, then `__getattr__` if that raised `AttributeError`.
        fn tpGetattro(obj: *Object, attr: *Object) callconv(.c) ?*Object {
            if (c.PyObject_GenericGetAttr(obj, attr)) |v| return v;
            if (c.PyErr_ExceptionMatches(c.PyExc_AttributeError) == 0) return null;
            c.PyErr_Clear();
            const n = argAs(ParamOf(T.__getattr__, 1), attr, "attribute name") catch return null;
            return py.toPython(callSelf(T.__getattr__, obj, .{n}));
        }

        /// `__getattr__(name)` as a method (`super().__getattr__` in a Python subclass).
        fn getattrMethod(obj: ?*Object, attr: ?*Object) callconv(.c) ?*Object {
            const n = argAs(ParamOf(T.__getattr__, 1), attr.?, "attribute name") catch return null;
            return py.toPython(callSelf(T.__getattr__, obj.?, .{n}));
        }

        /// `tp_setattro`: `__setattr__` / `__delattr__`, or the normal one for the missing hook.
        fn tpSetattro(obj: *Object, attr: *Object, value: ?*Object) callconv(.c) c_int {
            if (value) |v| {
                if (!@hasDecl(T, "__setattr__")) return c.PyObject_GenericSetAttr(obj, attr, v);
                const f = T.__setattr__;
                const n = argAs(ParamOf(f, 1), attr, "attribute name") catch return -1;
                const x = argAs(ParamOf(f, 2), v, "`" ++ comptime shortName(name) ++ ".__setattr__(value)`") catch
                    return -1;
                _ = callSelf(f, obj, .{ n, x }) catch return -1;
                return 0;
            }
            if (!@hasDecl(T, "__delattr__")) return c.PyObject_GenericSetAttr(obj, attr, null);
            const n = argAs(ParamOf(T.__delattr__, 1), attr, "attribute name") catch return -1;
            _ = callSelf(T.__delattr__, obj, .{n}) catch return -1;
            return 0;
        }

        /// `tp_descr_get`: `__get__(instance, owner)`.
        fn tpDescrGet(obj: *Object, instance: ?*Object, owner: ?*Object) callconv(.c) ?*Object {
            if (ParamOf(T.__get__, 1) != ?*Object or ParamOf(T.__get__, 2) != ?*Object)
                @compileError(@typeName(T) ++ ".__get__ takes `instance: ?*Object, owner: ?*Object`");
            return py.toPython(callSelf(T.__get__, obj, .{ instance, owner }));
        }

        /// `tp_descr_set`: `__set__(instance, value)` or `__delete__(instance)`.
        fn tpDescrSet(obj: *Object, instance: *Object, value: ?*Object) callconv(.c) c_int {
            if (value) |v| {
                if (!@hasDecl(T, "__set__")) {
                    py.setString(c.PyExc_AttributeError, "`{s}` is read-only", .{comptime shortName(name)});
                    return -1;
                }
                const x = argAs(ParamOf(T.__set__, 2), v, "`" ++ comptime shortName(name) ++ ".__set__(value)`") catch
                    return -1;
                _ = callSelf(T.__set__, obj, .{ instance, x }) catch return -1;
                return 0;
            }
            if (!@hasDecl(T, "__delete__")) {
                py.setString(c.PyExc_AttributeError, "can not delete a `{s}`", .{comptime shortName(name)});
                return -1;
            }
            _ = callSelf(T.__delete__, obj, .{instance}) catch return -1;
            return 0;
        }

        // --- pickling (`pickle = true`) -----------------------------------------------

        /// How many fields `__getstate__` saves: the bases', then this type's.
        pub const state_len: usize = blk: {
            var n: usize = if (Base != void) Base.state_len else 0;
            for (info.field_names, info.field_types) |f, F| {
                if (!picklable(F)) @compileError(@typeName(T) ++ "." ++ f ++ ": a `" ++ @typeName(F) ++
                    "` can not be pickled; write `__getstate__` / `__setstate__` instead of `pickle = true`");
                n += 1;
            }
            break :blk n;
        };

        /// Puts the fields of the bases and this type into `tuple`, from index `from`.
        pub fn getState(obj: *Object, tuple: *Object, from: usize) Error!void {
            var i = from;
            if (Base != void) {
                try Base.getState(obj, tuple, i);
                i += Base.state_len;
            }
            const d = data(obj);
            inline for (info.field_names) |f| {
                const v = @field(d, f);
                const o = if (@TypeOf(v) == ?*Object) blk: {
                    const x = v orelse py.none();
                    py.incref(x);
                    break :blk x;
                } else try py.new(v);
                _ = c.PyTuple_SetItem(tuple, @intCast(i), o); // steals `o`; cast: an index < `state_len`
                i += 1;
            }
        }

        /// Sets the fields of the bases and this type from `tuple`, from index `from`.
        pub fn setState(obj: *Object, tuple: *Object, from: usize) Error!void {
            var i = from;
            if (Base != void) {
                try Base.setState(obj, tuple, i);
                i += Base.state_len;
            }
            const d = data(obj);
            inline for (info.field_names, info.field_types) |f, F| {
                const item = c.PyTuple_GetItem(tuple, @intCast(i)).?; // cast: an index < `state_len`
                if (F == ?*Object) {
                    const old = @field(d, f);
                    @field(d, f) = if (item == py.none()) null else blk: {
                        py.incref(item);
                        break :blk item;
                    };
                    py.decref(old);
                } else @field(d, f) = try py.fromPythonAs(F, item, "`" ++ shortName(name) ++ "." ++ f ++ "`");
                i += 1;
            }
        }

        /// `__getstate__`: the fields as a tuple.
        fn getstateMethod(obj: ?*Object, _: ?*Object) callconv(.c) ?*Object {
            const t = c.PyTuple_New(state_len) orelse return null;
            getState(obj.?, t, 0) catch {
                py.decref(t);
                return null;
            };
            return t;
        }

        /// `__setstate__(state)`: the fields from `__getstate__`'s tuple.
        fn setstateMethod(obj: ?*Object, state: ?*Object) callconv(.c) ?*Object {
            const s = state.?;
            if (!py.isInstance(s, c.PyTuple_Type) or c.PyTuple_Size(s) != state_len) {
                py.setString(
                    c.PyExc_TypeError,
                    "`{s}.__setstate__` takes a tuple of {d} items",
                    .{ comptime shortName(name), state_len },
                );
                return null;
            }
            setState(obj.?, s, 0) catch return null;
            return py.newNone();
        }

        /// `__class_getitem__(item)`: `Name[item]` as a `types.GenericAlias`.
        fn classGetitem(cls: ?*Object, item: ?*Object) callconv(.c) ?*Object {
            return c.Py_GenericAlias(cls.?, item.?);
        }

        /// The C getter for `get_<name>`.
        fn Getter(comptime g: anytype) type {
            return struct {
                /// Calls the getter and converts its result.
                fn get(obj: *Object, _: ?*anyopaque) callconv(.c) ?*Object {
                    return py.toPython(g(selfOf(g, obj)));
                }
            };
        }

        /// The C setter for `set_<name>`; deleting the attribute raises `AttributeError`.
        fn Setter(comptime s: anytype, comptime prop: []const u8) type {
            const U = @typeInfo(@TypeOf(s)).@"fn".param_types[1].?;
            return struct {
                /// Converts the value and calls the setter.
                fn set(obj: *Object, value: ?*Object, _: ?*anyopaque) callconv(.c) c_int {
                    const v = value orelse {
                        py.setString(c.PyExc_AttributeError, "can not delete `{s}`", .{prop});
                        return -1;
                    };
                    const arg = py.fromPythonAs(U, v, "`" ++ shortName(name) ++ "." ++ prop ++ "`") catch return -1;
                    const result = s(selfOf(s, obj), arg);
                    if (@typeInfo(@TypeOf(result)) == .error_union) result catch return -1;
                    return 0;
                }
            };
        }

        const methods = blk: {
            @setEvalBranchQuota(1_000_000);
            var defs: []const c.MethodDef = &.{};
            for (info.decl_names) |n| if (isMethod(T, n)) {
                const f = @field(T, n);
                defs = defs ++ .{py.kindDef(f, py.methodKind(f, n, body), This, n, body)};
            };
            if (pickle) defs = defs ++ .{
                c.MethodDef{
                    .name = "__getstate__",
                    .meth = @ptrCast(&getstateMethod),
                    .flags = c.METH_NOARGS,
                    .doc = "The fields, for `pickle` / `copy`.",
                },
                c.MethodDef{
                    .name = "__setstate__",
                    .meth = @ptrCast(&setstateMethod),
                    .flags = c.METH_O,
                    .doc = "Sets the fields from `__getstate__`'s tuple.",
                },
            };
            if (@hasDecl(T, "__getattr__")) defs = defs ++ .{c.MethodDef{
                .name = "__getattr__",
                .meth = @ptrCast(&getattrMethod),
                .flags = c.METH_O,
                .doc = "The fallback for attributes normal lookup does not find.",
            }};
            if (@hasDecl(T, "type_params")) defs = defs ++ .{c.MethodDef{
                .name = "__class_getitem__",
                .meth = @ptrCast(&classGetitem),
                .flags = c.METH_O | c.METH_CLASS,
                .doc = "`Name[item]`: a `types.GenericAlias` (PEP 585).",
            }};
            break :blk (defs ++ .{py.method_end})[0 .. defs.len + 1].*;
        };

        const getset = blk: {
            @setEvalBranchQuota(1_000_000);
            var defs: []const c.GetSetDef = &.{};
            for (info.decl_names) |n| if (isGetter(T, n)) {
                const prop = n[4..];
                const doc = py.fnSource(body, n).doc;
                const setter = "set_" ++ prop;
                defs = defs ++ .{c.GetSetDef{
                    .name = (prop ++ "\x00")[0..prop.len :0],
                    .get = &Getter(@field(T, n)).get,
                    .set = if (@hasDecl(T, setter)) &Setter(@field(T, setter), prop).set else null,
                    .doc = if (doc.len > 0) (doc ++ "\x00")[0..doc.len :0] else null,
                    .closure = null,
                }};
            };
            if (@hasDecl(T, "dict") and T.dict) defs = defs ++ .{c.GetSetDef{
                .name = "__dict__",
                .get = &c.PyObject_GenericGetDict,
                .set = &c.PyObject_GenericSetDict,
                .doc = null,
                .closure = null,
            }};
            if (@hasDecl(T, "getset")) defs = defs ++ T.getset;
            break :blk (defs ++ .{py.getset_end})[0 .. defs.len + 1].*;
        };

        /// `Name(signature)\n--\n\n` (see `textSignature`; only when instantiable) plus the `///` doc.
        const type_doc = blk: {
            const doc = py.docAbove(source, at);
            const params = if (instantiable) textSignature(T, body) else null;
            const sig = if (params) |p| shortName(name) ++ p ++ "\n--\n\n" else "";
            const text = sig ++ doc;
            break :blk (text ++ "\x00")[0..text.len :0];
        };

        const flags = c.Py_TPFLAGS_DEFAULT |
            (if (@hasDecl(T, "basetype") and T.basetype) c.Py_TPFLAGS_BASETYPE else 0) |
            (if (gc) c.Py_TPFLAGS_HAVE_GC else 0) |
            (if (instantiable) 0 else c.Py_TPFLAGS_DISALLOW_INSTANTIATION) |
            (if (weakref) c.Py_TPFLAGS_MANAGED_WEAKREF else 0) |
            (if (dict) c.Py_TPFLAGS_MANAGED_DICT else 0);

        var type_slots = blk: {
            var s: []const c.Slot = &.{
                c.Slot.data(c.Py_tp_name, name.ptr),
                c.Slot.uint(c.Py_tp_flags, flags),
                c.Slot.func(c.Py_tp_dealloc, @ptrCast(&tpDealloc)),
            };
            // a subclass with no fields of its own adds no instance data (CPython wants a size > 0)
            if (@sizeOf(Stored) > 0) s = s ++ .{c.Slot.size(c.Py_tp_extra_basicsize, @sizeOf(Stored))};
            if (type_doc.len > 0) s = s ++ .{c.Slot.data(c.Py_tp_doc, type_doc.ptr)};
            if (Base != void) s = s ++ .{c.Slot{ .id = c.Py_tp_base }}; // set in `create`
            if (instantiable) s = s ++ .{c.Slot.func(c.Py_tp_new, @ptrCast(&tpNew))};
            if (@hasDecl(T, "__init__")) s = s ++ .{c.Slot.func(c.Py_tp_init, @ptrCast(&tpInit))};
            if (finalizes) s = s ++ .{c.Slot.func(c.Py_tp_finalize, @ptrCast(&tpFinalize))};
            if (gc) s = s ++ .{
                c.Slot.func(c.Py_tp_traverse, @ptrCast(&tpTraverse)),
                c.Slot.func(c.Py_tp_clear, @ptrCast(&tpClear)),
            };
            if (methods.len > 1) s = s ++ .{c.Slot.static(c.Py_tp_methods, &methods)};
            if (getset.len > 1) s = s ++ .{c.Slot.static(c.Py_tp_getset, &getset)};
            if (sends) s = s ++ .{
                c.Slot.func(c.Py_am_send, @ptrCast(&amSend)),
                c.Slot.func(c.Py_tp_iternext, @ptrCast(&tpIternext)),
                c.Slot.func(c.Py_tp_iter, @ptrCast(&tpIterSelf)),
            };
            if (@hasDecl(T, "__iter__")) {
                s = s ++ .{c.Slot.func(c.Py_tp_iter, @ptrCast(&tpIter))};
            } else if (@hasDecl(T, "__next__")) s = s ++ .{c.Slot.func(c.Py_tp_iter, @ptrCast(&tpIterSelf))};
            if (@hasDecl(T, "__next__")) s = s ++ .{c.Slot.func(c.Py_tp_iternext, @ptrCast(&tpNext))};
            if (@hasDecl(T, "__await__")) {
                s = s ++ .{c.Slot.func(c.Py_am_await, @ptrCast(&amAwait))};
            } else if (poll) s = s ++ .{c.Slot.func(c.Py_am_await, @ptrCast(&tpIterSelf))}; // `self`
            if (@hasDecl(T, "__bool__")) s = s ++ .{c.Slot.func(c.Py_nb_bool, @ptrCast(&nbBool))};
            if (@hasDecl(T, "__repr__")) s = s ++ .{c.Slot.func(c.Py_tp_repr, @ptrCast(&tpRepr))};
            if (@hasDecl(T, "__getitem__")) s = s ++ .{c.Slot.func(c.Py_mp_subscript, @ptrCast(&mpSubscript))};
            if (@hasDecl(T, "__setitem__") or @hasDecl(T, "__delitem__"))
                s = s ++ .{c.Slot.func(c.Py_mp_ass_subscript, @ptrCast(&mpAssSubscript))};
            if (@hasDecl(T, "__len__")) s = s ++ .{c.Slot.func(c.Py_mp_length, @ptrCast(&mpLength))};
            if (@hasDecl(T, "__contains__")) s = s ++ .{c.Slot.func(c.Py_sq_contains, @ptrCast(&sqContains))};
            if (@hasDecl(T, "__str__")) s = s ++ .{c.Slot.func(c.Py_tp_str, @ptrCast(&tpStr))};
            if (has_compare) s = s ++ .{c.Slot.func(c.Py_tp_richcompare, @ptrCast(&tpRichcompare))};
            if (@hasDecl(T, "__hash__")) {
                s = s ++ .{c.Slot.func(c.Py_tp_hash, @ptrCast(&tpHash))};
            } else if (keep_hash) {
                // Only `__eq__` makes a type unhashable, but CPython drops the inherited hash
                // for any `tp_richcompare`: keep the base's (set in `create`) or `object`'s.
                s = s ++ .{if (Base != void) c.Slot{ .id = c.Py_tp_hash } else c.Slot.func(
                    c.Py_tp_hash,
                    @ptrCast(&c.PyObject_GenericHash),
                )};
            }
            if (@hasDecl(T, "__call__")) s = s ++ .{c.Slot.func(c.Py_tp_call, @ptrCast(&tpCall))};
            for (number_ops) |op| {
                const B = Binary(op.name);
                const pow = std.mem.eql(u8, op.name, "pow");
                if (@hasDecl(T, "__" ++ op.name ++ "__") or @hasDecl(T, "__r" ++ op.name ++ "__"))
                    s = s ++ .{c.Slot.func(op.slot, if (pow) @ptrCast(&B.call3) else @ptrCast(&B.call))};
                if (@hasDecl(T, "__i" ++ op.name ++ "__")) {
                    if (op.inplace == 0) @compileError("no in-place `" ++ op.name ++ "`");
                    const I = Inplace(op.name);
                    s = s ++ .{c.Slot.func(op.inplace, if (pow) @ptrCast(&I.call3) else @ptrCast(&I.call))};
                }
            }
            for (unary_ops) |op| if (@hasDecl(T, op[0])) {
                s = s ++ .{c.Slot.func(op[1], @ptrCast(&Unary(op[0]).call))};
            };
            if (@hasDecl(T, "__getattr__")) s = s ++ .{c.Slot.func(c.Py_tp_getattro, @ptrCast(&tpGetattro))};
            if (@hasDecl(T, "__setattr__") or @hasDecl(T, "__delattr__"))
                s = s ++ .{c.Slot.func(c.Py_tp_setattro, @ptrCast(&tpSetattro))};
            if (@hasDecl(T, "__get__")) s = s ++ .{c.Slot.func(c.Py_tp_descr_get, @ptrCast(&tpDescrGet))};
            if (@hasDecl(T, "__set__") or @hasDecl(T, "__delete__"))
                s = s ++ .{c.Slot.func(c.Py_tp_descr_set, @ptrCast(&tpDescrSet))};
            if (@hasDecl(T, "slots")) s = s ++ T.slots;
            s = s ++ .{c.Slot.end};
            break :blk s[0..s.len].*;
        };
    };
}
