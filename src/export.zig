//! PyOZ-style export: the C-ABI trampolines and method table entries for `pub fn`s
//! (`exportFns`, `methodDef`, `getter`), with `__text_signature__` docstrings, a file's
//! constants (`constants`, `addConstants`), and the module (`Module`, `exportModule`): with
//! `Module.from` (see `scan.zig`), the method table and `Py_mod_exec` are generated from the listed
//! namespaces. Re-exported by `py.zig`.
//!
//! Example
//!     // the extension's root file: the one declaration Setu reads (the stub generator too)
//!     pub const module: setu.Module = .{
//!         .name = "point",
//!         .from = &.{.{ .ns = @import("point.zig"), .source = @embedFile("point.zig") }},
//!     };
//!     comptime {
//!         setu.py.exportModule(module);
//!     }

const std = @import("std");
const c = @import("capi.zig");
const py = @import("py.zig");
const toPython = @import("convert.zig").toPython;
const setString = @import("raise.zig").setString;
const args_zig = @import("args.zig");
const source_zig = @import("source.zig");
const class_zig = @import("class.zig");
const scan_zig = @import("scan.zig");

const Object = py.Object;
const Param = args_zig.Param;
const Rest = args_zig.Rest;
const Kwargs = args_zig.Kwargs;
const KwNames = args_zig.KwNames;
const paramList = args_zig.paramList;
const paramNames = args_zig.paramNames;
const leadCount = args_zig.leadCount;
const positionalCount = args_zig.positionalCount;
const selfArg = args_zig.selfArg;
const fillArgs = args_zig.fillArgs;
const releaseArgs = args_zig.releaseArgs;
const fnSource = source_zig.fnSource;

pub const method_end: c.MethodDef = .{ .name = null, .meth = null, .flags = 0, .doc = null };
pub const getset_end: c.GetSetDef = .{ .name = null, .get = null, .set = null, .doc = null, .closure = null };

/// A `METH_FASTCALL | METH_KEYWORDS` method table entry for `call`.
fn defKw(comptime name: [:0]const u8, comptime call: c.FastCallKw, comptime doc: ?[:0]const u8) c.MethodDef {
    return .{
        .name = name.ptr,
        .meth = @ptrCast(call),
        .flags = c.METH_FASTCALL | c.METH_KEYWORDS,
        .doc = if (doc) |d| d.ptr else null,
    };
}

/// Generates the C function Python calls for `f`: maps positional and keyword
/// arguments onto `f`'s parameters by `names`, gives missing `?T` parameters `null`,
/// collects `*args` into a leading `Rest`, converts the arguments and the result, and
/// turns a Zig error into the Python exception. For an exported
/// `pub fn open(path: *Object, flags: ?u64, mode: ?u64, resolve: ?u64, dir_fd: ?i32)`:
///
/// Example
///     >>> await open('a.txt', O_CREAT | O_WRONLY, mode=0o600)  # resolve, dir_fd: None
///     3
///     >>> await open('a.txt', bogus=1)
///     TypeError: open() got an unexpected keyword argument 'bogus'
///
/// Note
///     - `Owner` is the `setu.Class` whose instance data a `self: *T` receives
///       (`void` outside a class, where `self` is `*Object`).
fn KwTrampoline(
    comptime f: anytype,
    comptime bound: bool,
    comptime Owner: type,
    comptime fname: [:0]const u8,
    comptime plist: []const Param,
) type {
    const F = @TypeOf(f);
    const fparams = @typeInfo(F).@"fn".param_types;
    const rest_at = comptime restIndex(f);
    const has_rest = rest_at != null;
    const has_kwargs = comptime hasKwargs(f);
    const names = paramNames(plist);
    const count = plist.len;
    const lead = leadCount(plist); // positional-only parameters before `*args`
    const max_positional = positionalCount(plist);
    if (has_rest and max_positional != count) @compileError(fname ++ ": `py.KwOnly` after `py.Rest` is redundant");

    return struct {
        /// The C-ABI function Python calls: checks and converts the arguments, calls `f`,
        /// converts its result (or error) back.
        fn call(self: ?*Object, args: ?[*]const *Object, n: c.ssize, kwnames: ?*Object) callconv(.c) ?*Object {
            // `METH_FASTCALL` passes the plain count: no `PY_VECTORCALL_ARGUMENTS_OFFSET` flag, which only a
            // `vectorcallfunc` gets.
            const nargs: usize = @intCast(n); // cast: a count, never < 0
            const argv: [*]const *Object = args orelse undefined;
            var slots: [count]?*Object = @splat(null);
            const positional = if (has_rest) @min(nargs, lead) else nargs;
            if (positional > max_positional) {
                setString(
                    c.PyExc_TypeError,
                    "{s}() takes at most {d} positional arguments ({d} given)",
                    .{ fname, max_positional, nargs },
                );
                return null;
            }
            inline for (0..count) |i| { // unrolled: a loop here is a `memcpy` call for a few pointers
                if (i < positional) slots[i] = argv[i];
            }
            var extra: ?*Object = null; // `**kwargs`: the keywords no parameter takes
            defer if (extra) |d| py.decref(d);
            if (comptime count == 0 and !has_kwargs) {
                if (kwnames) |kw| if (c.PyTuple_Size(kw) > 0) {
                    setString(c.PyExc_TypeError, "{s}() takes no keyword arguments", .{fname});
                    return null;
                };
            } else if (kwnames) |kw| {
                const nkw: usize = @intCast(c.PyTuple_Size(kw)); // cast: a size, never < 0
                for (0..nkw) |j| {
                    const key = c.PyTuple_GetItem(kw, @intCast(j)).?; // cast: an index < `nkw`
                    const at = KwNames(names, max_positional).find(key) orelse {
                        if (has_kwargs) {
                            if (extra == null) extra = c.PyDict_New() orelse return null;
                            if (c.PyDict_SetItem(extra.?, key, argv[nargs + j]) < 0) return null;
                            continue;
                        }
                        args_zig.setUnexpectedKeyword(fname, key);
                        return null;
                    };
                    if (slots[at] != null) {
                        setString(
                            c.PyExc_TypeError,
                            "{s}() got multiple values for argument '{s}'",
                            .{ fname, names[at] },
                        );
                        return null;
                    }
                    slots[at] = argv[nargs + j];
                }
            }
            var tuple: std.meta.ArgsTuple(F) = undefined;
            if (bound) tuple[0] = selfArg(Owner, fparams[0].?, self.?);
            if (rest_at) |at| tuple[at] = .{ .items = if (nargs > lead) argv[lead..nargs] else &.{} };
            if (has_kwargs) tuple[fparams.len - 1] = .{ .dict = extra };
            fillArgs(F, plist, fname, &slots, &tuple) catch return null;
            defer releaseArgs(F, plist, &tuple);
            return toPython(@call(.auto, f, tuple));
        }
    };
}

/// Every exported `pub fn` (see `isExported`) of the namespace `M` as a Python function of the same name,
/// taking positional or keyword arguments named as in the Zig source, with the
/// `///` comment above it as its docstring. `source` is `@embedFile` of the
/// file that defines `M`. No terminator; append `method_end` at the end.
///
/// Example
///     >>> const math = @import("math.zig");
///     >>> const methods = py.exportFns(math, @embedFile("math.zig")) ++ [_]c.MethodDef{py.method_end};
pub fn exportFns(comptime M: type, comptime source: []const u8) [countFns(M)]c.MethodDef {
    @setEvalBranchQuota(1_000_000);
    var defs: [countFns(M)]c.MethodDef = undefined;
    var i: usize = 0;
    for (@typeInfo(M).@"struct".decl_names) |name| {
        if (!isExported(M, name)) continue;
        defs[i] = methodDef(@field(M, name), false, void, name, source);
        i += 1;
    }
    return defs;
}

/// Exported: a `pub fn` whose name has no uppercase letter (`prep_read`, `run`).
/// camelCase `pub fn`s (`initModule`) are Zig-side helpers and stay hidden.
pub fn isExported(comptime M: type, comptime name: []const u8) bool {
    if (@typeInfo(@TypeOf(@field(M, name))) != .@"fn") return false;
    for (name) |ch| if (std.ascii.isUpper(ch)) return false;
    return true;
}

/// A module constant: an UPPER_CASE `pub const` int, float, `bool` or string (what a class takes as
/// a class attribute, `class.isClassAttr`), or an UPPER_CASE field of a `pub` enum (an int).
pub const Constant = struct {
    name: [:0]const u8,
    value: Value,

    /// The constant's value, by Python type.
    pub const Value = union(enum) {
        int: i128,
        float: f64,
        bool: bool,
        str: [:0]const u8,
    };

    /// The Python type name of the value (`int`, `float`, `bool`, `str`), for the stub.
    pub fn pyType(comptime k: Constant) []const u8 {
        return @tagName(k.value);
    }
};

/// The constant value of the declaration `name` of `M`, if it is one (see `Constant`): an UPPER_CASE
/// `pub const` (not a `pub var`) of a class-attribute type.
pub fn constantValue(comptime M: type, comptime name: []const u8) ?Constant.Value {
    if (!class_zig.isClassAttr(M, name)) return null;
    if (!@typeInfo(@TypeOf(&@field(M, name))).pointer.attrs.@"const") return null; // a `pub var`
    const v = @field(M, name);
    return switch (@typeInfo(@TypeOf(v))) {
        .int, .comptime_int => .{ .int = v },
        .float, .comptime_float => .{ .float = v },
        .bool => .{ .bool = v },
        else => .{ .str = (v ++ "\x00")[0..v.len :0] },
    };
}

/// The constants of the enum `E` (see `Constant`): its UPPER_CASE fields, in order.
pub fn enumConstants(comptime E: type) []const Constant {
    var out: []const Constant = &.{};
    for (@typeInfo(E).@"enum".field_names) |f| {
        if (isUpperName(f)) out = out ++ .{Constant{ .name = f, .value = .{ .int = @backingInt(@field(E, f)) } }};
    }
    return out;
}

/// The module constants of the namespace `M` (see `Constant`), in source order: what
/// `addConstants` adds and `setu.stub.constants` declares.
///
/// Example
///     >>> pub const IOSQE_IO_LINK = 1 << 2;
///     >>> pub const NAME = "ring";
///     >>> pub const io_uring_op = enum(u8) { IORING_OP_NOP, IORING_OP_READV };
///     >>> constants(@This())
///     .{ .{ "IOSQE_IO_LINK", 4 }, .{ "NAME", "ring" }, .{ "IORING_OP_NOP", 0 }, .{ "IORING_OP_READV", 1 } }
pub fn constants(comptime M: type) []const Constant {
    @setEvalBranchQuota(1_000_000);
    var out: []const Constant = &.{};
    for (@typeInfo(M).@"struct".decl_names) |name| {
        if (@TypeOf(@field(M, name)) == type) {
            const E = @field(M, name);
            if (@typeInfo(E) == .@"enum") out = out ++ enumConstants(E);
        } else if (constantValue(M, name)) |v| {
            out = out ++ .{Constant{ .name = name, .value = v }};
        }
    }
    return out;
}

/// An extension module: `exportModule` makes the binary's entry points from it, `setu.stub.module`
/// its `.pyi`. Declared once, as `pub const module: setu.Module` in the root file (its `name` is also
/// every class's and exception's `__module__`).
///
/// Example
///     >>> pub const module: setu.Module = .{
///     >>>     .name = "point",
///     >>>     .version = "1.0",
///     >>>     .from = &.{.{ .ns = @import("point.zig"), .source = @embedFile("point.zig") }},
///     >>>     .init = init,
///     >>> };
///     >>> comptime {
///     >>>     py.exportModule(module);
///     >>> }
///     >>> import point
///     >>> point.__version__, point.Point(1, 2).norm2()
///     ('1.0', 5)
pub const Module = struct {
    /// The module name: the extension file's name without its suffix (`setu_classes`).
    name: [:0]const u8,
    /// The docstring; `null`: the `//!` doc of the first `from` entry with a `source` (if any).
    doc: ?[:0]const u8 = null,
    /// `__version__`, when set (`build_options.version`).
    version: ?[:0]const u8 = null,
    /// The namespaces whose functions, classes, exceptions, constants and enums the module gets (see
    /// `setu.From`), created in this order: classes (bases first), exceptions, constants, `IntEnum`s.
    from: []const scan_zig.From = &.{},
    /// Runs at the end of `Py_mod_exec`, after everything from `from` and `__version__` is added
    /// (classes exist, constants are set): the project's own setup. A function (`.init = init`).
    init: ?fn (module: *Object) py.Error!void = null,
    /// Lines `setu.stub.module` writes after the imports, for what the module gets by hand (in
    /// `init` or `methods`). It must not import the names Setu imports itself.
    stub_extra: []const u8 = "",
    /// Functions of the module's own (`methods` entries; a terminating `method_end` is optional with
    /// `from`): one with the name of a function in `from` replaces it (its stub stays). Without
    /// `from`, the whole table, ending with `method_end` (`exportFns(...) ++ .{method_end}`).
    methods: []const c.MethodDef = &.{method_end},
    /// `Py_mod_exec` of a module without `from` / `version` / `init`: fills the module, `0` or `-1`
    /// with an exception set. With them, it runs last (after `init`).
    exec: ?c.ModExec = null,
    /// `false` (`Py_MOD_GIL_NOT_USED`): safe without the GIL. `true` (`Py_MOD_GIL_USED`): the
    /// free-threaded CPython enables the GIL on import, for state that is not thread-safe.
    gil: bool = false,
    /// Can be imported in subinterpreters? Setu keeps state in globals, so the default is no.
    multiple_interpreters: bool = false,

    /// Does Setu generate the method table and `Py_mod_exec` (`from`, `version` or `init` set)?
    pub fn generated(comptime m: Module) bool {
        return m.from.len > 0 or m.version != null or m.init != null;
    }

    /// The names of `methods` (explicit functions).
    pub fn methodNames(comptime m: Module) []const []const u8 {
        var out: []const []const u8 = &.{};
        for (m.methods) |d| if (d.name) |n| {
            out = out ++ .{std.mem.span(n)};
        };
        return out;
    }

    /// The scan of `from` (see `scan.Scan`), without the functions `methods` replaces.
    pub fn Scanned(comptime m: Module) type {
        return scan_zig.Scan(m.from, m.methodNames());
    }

    /// `doc`, else the `//!` doc of the first `from` entry with a `source`.
    pub fn docString(comptime m: Module) ?[:0]const u8 {
        if (m.doc) |d| return d;
        for (m.from) |e| if (e.source) |text| {
            const d = source_zig.moduleDoc(text);
            if (d.len == 0) return null;
            return (d ++ "\x00")[0..d.len :0];
        };
        return null;
    }
};

/// Exports both entry points of the module, so one binary loads on CPython 3.14, 3.14t, 3.15,
/// 3.15t and later: `PyModExport_<name>` (PEP 793, with a stable free-threading-agnostic
/// `Py_mod_abi`), which 3.15+ prefers, and `PyInit_<name>`, which 3.14 calls. Call it in a
/// `comptime` block of the extension's root file. With `from` (or `version` / `init`), the method
/// table and `Py_mod_exec` are generated: the functions of `from` after `methods`; classes, exceptions,
/// constants, `IntEnum`s, `__version__`, then `init`, then `exec`.
///
/// Example
///     >>> comptime {
///     >>>     py.exportModule(module); // `pub const module: setu.Module = .{ .name = "point", ... }`
///     >>> }
///     >>> import point
///     >>> point.__name__
///     'point'
///
/// Note
///     - On 3.14 the module comes from a static `PyModuleDef`, whose object header differs
///       between 3.14 and 3.14t: both are built, `PyInit_<name>` picks one by `sys.abiflags`.
///     - Does nothing in Setu's stub generator (`stubgen`), which has no libpython.
pub fn exportModule(comptime m: Module) void {
    if (stubgen) return;
    if (!m.generated() and (m.methods.len == 0 or m.methods[m.methods.len - 1].name != null))
        @compileError("`Module.methods` must end with `py.method_end` (or set `from`, `version` or `init`)");
    const G = Generated(m);
    const methods: []const c.MethodDef = if (comptime m.generated()) &G.methods else m.methods;
    const exec: ?c.ModExec = if (comptime m.generated()) &G.exec else m.exec;
    const doc = comptime m.docString();
    const E = struct {
        const abi_info: c.ABIInfo = .{
            .flags = c.PyABIInfo_STABLE | c.PyABIInfo_GIL | c.PyABIInfo_FREETHREADED,
            .build_version = c.version_3_15,
            .abi_version = c.version_3_15,
        };
        const gil: u64 = if (m.gil) c.Py_MOD_GIL_USED else c.Py_MOD_GIL_NOT_USED;
        const interpreters = c.Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED;
        const slots = blk: {
            var s: []const c.Slot = &.{
                c.Slot.data(c.Py_mod_abi, &abi_info),
                c.Slot.data(c.Py_mod_name, m.name.ptr),
                c.Slot.static(c.Py_mod_methods, methods.ptr),
            };
            if (doc) |d| s = s ++ .{c.Slot.data(c.Py_mod_doc, d.ptr)};
            if (exec) |f| s = s ++ .{c.Slot.func(c.Py_mod_exec, f)};
            s = s ++ .{c.Slot.uint(c.Py_mod_gil, gil)};
            if (!m.multiple_interpreters) s = s ++ .{c.Slot.uint(c.Py_mod_multiple_interpreters, interpreters)};
            break :blk (s ++ .{c.Slot.end})[0 .. s.len + 1].*;
        };
        var def_slots = blk: {
            var s: []const c.ModuleDefSlot = &.{};
            if (exec) |f| s = s ++ .{c.ModuleDefSlot{ .slot = c.Py_mod_exec_old, .value = f }};
            s = s ++ .{c.ModuleDefSlot{ .slot = c.Py_mod_gil_old, .value = @ptrFromInt(gil) }};
            if (!m.multiple_interpreters) s = s ++ .{c.ModuleDefSlot{
                .slot = c.Py_mod_multiple_interpreters_old,
                .value = @ptrFromInt(interpreters),
            }};
            break :blk (s ++ .{c.ModuleDefSlot.end})[0 .. s.len + 1].*;
        };
        var def_gil: c.ModuleDef(c.ObjectHeadGil) = .{
            .m_name = m.name.ptr,
            .m_doc = if (doc) |d| d.ptr else null,
            .m_methods = @constCast(methods.ptr),
            .m_slots = &def_slots,
        };
        var def_ft: c.ModuleDef(c.ObjectHeadFt) = .{
            .m_name = m.name.ptr,
            .m_doc = if (doc) |d| d.ptr else null,
            .m_methods = @constCast(methods.ptr),
            .m_slots = &def_slots,
        };

        fn modExport() callconv(.c) [*]const c.Slot {
            return &slots;
        }
        fn init() callconv(.c) ?*Object {
            return c.PyModuleDef_Init(if (freeThreaded()) @ptrCast(&def_ft) else @ptrCast(&def_gil));
        }
    };
    @export(&E.modExport, .{ .name = "PyModExport_" ++ m.name });
    @export(&E.init, .{ .name = "PyInit_" ++ m.name });
}

/// Is this Setu's stub generator (`addStubs`)? It imports the extension's root file for its `module` but
/// has no libpython, so `exportModule` exports nothing there; the root file declares `setu_stubgen`. Code
/// that comptime data points to is dropped there unless reached (see `addStubs`), so a root file rarely
/// needs to ask.
pub const stubgen = @hasDecl(@import("root"), "setu_stubgen");

/// The method table and `Py_mod_exec` Setu generates for a `Module` with `from` / `version` / `init`.
fn Generated(comptime m: Module) type {
    const S = m.Scanned();
    return struct {
        /// `m.methods` (without its terminator), then the scanned functions, then `method_end`.
        const methods = blk: {
            @setEvalBranchQuota(100_000_000);
            var defs: []const c.MethodDef = &.{};
            for (m.methods) |d| if (d.name != null) {
                defs = defs ++ .{d};
            };
            for (S.functions) |it| defs = defs ++ .{methodDef(S.decl(it), false, void, it.name, S.source(it))};
            defs = defs ++ .{method_end};
            break :blk defs[0..defs.len].*;
        };

        /// `Py_mod_exec`: `fill`, then the module's own `exec`.
        fn exec(module: *Object) callconv(.c) c_int {
            fill(module) catch return -1;
            if (m.exec) |f| return f(module);
            return 0;
        }

        /// Creates the classes (bases first; hidden ones not added), the exceptions, the constants and
        /// the `IntEnum`s of `from`, adds `__version__`, then runs `init`.
        fn fill(module: *Object) py.Error!void {
            inline for (S.classes) |it| try S.decl(it).create(if (it.hidden) null else module);
            inline for (S.exceptions) |it| try S.decl(it).create(it.name, module);
            inline for (S.constants) |it| try addConstant(module, .{ .name = it.name, .value = it.value.? });
            if (S.int_enums.len > 0) {
                const enum_mod = c.PyImport_ImportModule("enum") orelse return error.PythonError;
                defer py.decref(enum_mod);
                const int_enum = c.PyObject_GetAttrString(enum_mod, "IntEnum") orelse return error.PythonError;
                defer py.decref(int_enum);
                inline for (S.int_enums) |it| try addIntEnum(module, int_enum, it.name, S.decl(it), S.declDoc(it));
            }
            if (m.version) |v| {
                if (c.PyModule_AddStringConstant(module, "__version__", v.ptr) < 0) return error.PythonError;
            }
            if (m.init) |f| try f(module);
        }

        /// Adds `IntEnum(name, [(field, value), ...], module=<m.name>)` for the enum `E` to `module`, with
        /// `doc` as its `__doc__` (when not empty).
        fn addIntEnum(
            module: *Object,
            int_enum: *Object,
            comptime name: [:0]const u8,
            comptime E: type,
            comptime doc: []const u8,
        ) py.Error!void {
            const info = @typeInfo(E).@"enum";
            const Member = struct { [:0]const u8, info.tag_type };
            const members = comptime blk: {
                var out: [info.field_names.len]Member = undefined;
                for (info.field_names, 0..) |f, i| out[i] = .{ f, @backingInt(@field(E, f)) };
                break :blk out;
            };
            const args = try py.new(.{ name, @as([]const Member, &members) });
            defer py.decref(args);
            const kwargs = c.PyDict_New() orelse return error.PythonError;
            defer py.decref(kwargs);
            const mod_name = try py.new(m.name);
            defer py.decref(mod_name);
            const key = try py.new("module");
            defer py.decref(key);
            if (c.PyDict_SetItem(kwargs, key, mod_name) < 0) return error.PythonError;
            const cls = c.PyObject_Call(int_enum, args, kwargs) orelse return error.PythonError;
            defer py.decref(cls);
            if (doc.len > 0) {
                const d = try py.new(doc);
                defer py.decref(d);
                if (c.PyObject_SetAttrString(cls, "__doc__", d) < 0) return error.PythonError;
            }
            if (c.PyModule_AddObjectRef(module, name, cls) < 0) return error.PythonError;
        }
    };
}

/// Is this the free-threaded CPython? `t` in `sys.abiflags`.
fn freeThreaded() bool {
    const flags = c.PySys_GetObject("abiflags") orelse return false; // borrowed
    const text = c.PyUnicode_AsUTF8AndSize(flags, null) orelse {
        // coverage-off: `sys.abiflags` is a `str`
        c.PyErr_Clear();
        return false;
        // coverage-on
    };
    return std.mem.findScalar(u8, std.mem.span(text), 't') != null;
}

/// Adds the constants of `M` (see `constants`) to `module` by name: ints, floats, `bool`s and
/// `str`s. For the module's `Py_mod_exec`.
///
/// Example
///     >>> py.addConstants(module, @import("const.zig")) catch return -1;
///     >>> liburing.IOSQE_IO_LINK
///     4
pub fn addConstants(module: *Object, comptime M: type) py.Error!void {
    inline for (comptime constants(M)) |k| try addConstant(module, k);
}

/// Adds the constant `k` to `module` (see `addConstants`).
pub fn addConstant(module: *Object, comptime k: Constant) py.Error!void {
    const v = try switch (k.value) {
        .int => |i| py.new(if (i < 0) @as(i64, i) else @as(u64, i)),
        .float => |f| py.new(f),
        .bool => |b| py.new(b),
        .str => |t| py.new(t),
    };
    defer py.decref(v);
    if (c.PyModule_AddObjectRef(module, k.name, v) < 0) return error.PythonError;
}

/// Is `name` UPPER_CASE: a letter, and no lowercase ones (`IOSQE_IO_LINK`, `O_RDONLY`)?
pub fn isUpperName(comptime name: []const u8) bool {
    var letter = false;
    for (name) |ch| {
        if (std.ascii.isLower(ch)) return false;
        if (std.ascii.isUpper(ch)) letter = true;
    }
    return letter;
}

/// How many exported `pub fn`s `M` has (sizes the method table at comptime).
fn countFns(comptime M: type) usize {
    @setEvalBranchQuota(100_000);
    var n: usize = 0;
    for (@typeInfo(M).@"struct".decl_names) |name| {
        if (isExported(M, name)) n += 1;
    }
    return n;
}

/// The keyword-capable method table entry for the `pub fn name` `f` found in `source`:
/// parameter names, `///` doc and `__text_signature__` come from there. `Owner`: see
/// `KwTrampoline`.
pub fn methodDef(
    comptime f: anytype,
    comptime bound: bool,
    comptime Owner: type,
    comptime name: [:0]const u8,
    comptime source: []const u8,
) c.MethodDef {
    return kindDef(f, if (bound) .instance else .function, Owner, name, source);
}

/// What a `pub fn` in a class is to Python (`methodKind`), or a module function.
pub const MethodKind = enum {
    /// A module function (`$module`).
    function,
    /// The first parameter is `self`: the instance.
    instance,
    /// The first parameter is `cls` (`*c.TypeObject`): the class (`METH_CLASS`).
    class,
    /// No `self` / `cls` parameter (`METH_STATIC`).
    static,

    /// Does the Zig function take the instance / class as its first parameter?
    // comptime: method tables are built at comptime
    pub fn bound(kind: MethodKind) bool {
        return kind == .instance or kind == .class;
    }
};

/// The kind of the class's `pub fn name` in `source` (its file), by its first parameter's
/// name: `self` (an instance method), `cls` (a class method), else a static method.
pub fn methodKind(comptime f: anytype, comptime name: []const u8, comptime source: []const u8) MethodKind {
    const params = fnSource(source, name).params;
    if (params.len == 0) return .static;
    if (std.mem.eql(u8, params[0], "self")) return .instance;
    if (std.mem.eql(u8, params[0], "cls")) {
        if (@typeInfo(@TypeOf(f)).@"fn".param_types[0].? != *c.TypeObject)
            @compileError(name ++ ": `cls` must be `*c.TypeObject`");
        return .class;
    }
    return .static;
}

/// `methodDef` for a `kind` of function (see `MethodKind`).
pub fn kindDef(
    comptime f: anytype,
    comptime kind: MethodKind,
    comptime Owner: type,
    comptime name: [:0]const u8,
    comptime source: []const u8,
) c.MethodDef {
    const bound = kind.bound();
    const first = @as(usize, @intFromBool(bound)) + @intFromBool(hasRest(f, bound));
    const plist = paramList(f, first, name, source);
    var def = defKw(name, &KwTrampoline(f, bound, Owner, name, plist).call, docString(f, kind, name, source));
    def.flags |= switch (kind) {
        .class => c.METH_CLASS,
        .static => c.METH_STATIC,
        else => 0,
    };
    return def;
}

/// Does `f` take `**kwargs` (a `Kwargs` last)?
pub fn hasKwargs(comptime f: anytype) bool {
    const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
    return params.len > 0 and params[params.len - 1].? == Kwargs;
}

/// Does `f` take `*args` right after `self` (or first), so no parameter comes before it?
pub fn hasRest(comptime f: anytype, comptime bound: bool) bool {
    const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
    const skip: usize = @intFromBool(bound);
    return params.len > skip and params[skip].? == Rest;
}

/// The index of `f`'s `py.Rest` parameter (`*args`), if it has one.
pub fn restIndex(comptime f: anytype) ?usize {
    for (@typeInfo(@TypeOf(f)).@"fn".param_types, 0..) |P, i| if (P == Rest) return i;
    return null;
}

/// `name($module, a, b=None, *args)\n--\n\n<doc>` (`$self` / `$cls` / nothing for a method, by
/// `kind`): CPython reads the first part
/// as `__text_signature__`, so `inspect.signature` / `help()` show the parameters.
fn docString(
    comptime f: anytype,
    comptime kind: MethodKind,
    comptime name: []const u8,
    comptime source: []const u8,
) [:0]const u8 {
    const plist = paramText(f, kind.bound(), name, source);
    const first: []const u8 = switch (kind) {
        .function => "$module",
        .instance => "$self",
        .class => "$cls",
        .static => "",
    };
    const sig = first ++ (if (plist.len > 0 and first.len > 0) ", " else "") ++ plist;
    const text = name ++ "(" ++ sig ++ ")\n--\n\n" ++ fnSource(source, name).doc;
    return (text ++ "\x00")[0..text.len :0];
}

/// The parameters of the `pub fn fname` `f` in `source` (`self` skipped when `bound`) as in
/// a `__text_signature__`: `*name` for a `py.Rest`, `*` for `py.KwOnly`, `**name` for a
/// `py.Kwargs`, defaults per `Param`.
///
/// Example
///     >>> paramText(Statx.__init__, true, "__init__", source)
///     "path=None, flags=0, mask=0, *, dir_fd=AT_FDCWD"
pub fn paramText(
    comptime f: anytype,
    comptime bound: bool,
    comptime fname: []const u8,
    comptime source: []const u8,
) []const u8 {
    const first = @as(usize, @intFromBool(bound)) + @intFromBool(hasRest(f, bound));
    var out: []const u8 = if (hasRest(f, bound)) "*" ++ fnSource(source, fname).params[first - 1] else "";
    const plist = paramList(f, first, fname, source);
    const lead = leadCount(plist);
    for (plist, 0..) |p, i| {
        const item = if (p.kind == .kw_only) "*" else p.name ++ (if (p.default) |d| "=" ++ d else "");
        out = out ++ (if (out.len == 0) "" else ", ") ++ item;
        if (lead > 0 and i + 1 == lead) out = out ++ ", /, *" ++ fnSource(source, fname).params[restIndex(f).?];
    }
    if (hasKwargs(f)) {
        const info = fnSource(source, fname);
        out = out ++ (if (out.len == 0) "" else ", ") ++ "**" ++ info.params[info.params.len - 1];
    }
    return out;
}

/// Read-only property; `f` is `fn (self: *Object) T`.
pub fn getter(comptime name: [:0]const u8, comptime f: anytype, comptime doc: ?[:0]const u8) c.GetSetDef {
    const G = struct {
        /// The generated C getter: calls `f(self)` and converts the result.
        fn get(self: *Object, _: ?*anyopaque) callconv(.c) ?*Object {
            return toPython(f(self));
        }
    };
    return .{ .name = name.ptr, .get = &G.get, .set = null, .doc = if (doc) |d| d.ptr else null, .closure = null };
}

const testing = @import("testing.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

test "isExported / constants: lowercase functions, UPPER_CASE values and enum fields" {
    const M = struct {
        pub const IOSQE_IO_LINK = 1 << 2;
        pub const op = enum(u8) { IORING_OP_NOP, IORING_OP_READV, lower };
        pub const Small: u8 = 7;
        pub const B2 = -1;
        pub const PI = 3.25;
        pub const HALF: f32 = 0.5;
        pub const FLAG = true;
        pub const NAME = "ring";
        pub const EMPTY = "";
        pub var COUNTER: u32 = 0;
        pub const lower = 4;
        pub fn prep_nop() void {}
        pub fn prepHelper() void {}
    };
    comptime {
        testing.expect(isExported(M, "prep_nop"), "`prep_nop` exported");
        testing.expect(!isExported(M, "prepHelper"), "camelCase `prepHelper` not exported");
        testing.expect(!isExported(M, "IOSQE_IO_LINK"), "a constant is no function");
        const k = constants(M);
        var names: []const []const u8 = &.{};
        for (k) |x| names = names ++ .{x.name};
        testing.expectTexts(
            names,
            &.{ "IOSQE_IO_LINK", "IORING_OP_NOP", "IORING_OP_READV", "B2", "PI", "HALF", "FLAG", "NAME", "EMPTY" },
        );
        testing.expect(k[0].value.int == 4 and k[2].value.int == 1 and k[3].value.int == -1, "the ints");
        testing.expect(k[4].value.float == 3.25 and k[5].value.float == 0.5, "the floats");
        testing.expect(k[6].value.bool, "the bool");
        testing.expectTexts(&.{ k[7].value.str, k[8].value.str }, &.{ "ring", "" });
        testing.expectTexts(&.{ k[0].pyType(), k[4].pyType(), k[6].pyType(), k[8].pyType() }, &.{
            "int", "float", "bool", "str",
        });
        testing.expect(isUpperName("AT_FDCWD") and isUpperName("B2"), "UPPER_CASE names");
        testing.expect(!isUpperName("Small") and !isUpperName("_1"), "not UPPER_CASE");
    }
}
