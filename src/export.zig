//! PyOZ-style export: the C-ABI trampolines and method table entries for `pub fn`s
//! (`exportFns`, `methodDef`, `getter`), with `__text_signature__` docstrings, and a file's
//! constants (`addConstants`), and the module's entry points (`exportModule`). Re-exported by `py.zig`.

const std = @import("std");
const c = @import("capi.zig");
const py = @import("py.zig");
const toPython = @import("convert.zig").toPython;
const setString = @import("raise.zig").setString;
const args_zig = @import("args.zig");
const fnSource = @import("source.zig").fnSource;

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
///     TypeError: open() got an unexpected keyword argument
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
        fn call(self: ?*Object, args: ?[*]const *Object, nargsf: c.ssize, kwnames: ?*Object) callconv(.c) ?*Object {
            // cast: >= 0 once PY_VECTORCALL_ARGUMENTS_OFFSET is dropped
            const nargs: usize = @intCast(nargsf & ~@as(c.ssize, 1 << 62));
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
                        setString(c.PyExc_TypeError, "{s}() got an unexpected keyword argument", .{fname});
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

/// A module constant: an UPPER_CASE `pub const` int, or an UPPER_CASE field of a `pub` enum.
pub const Constant = struct {
    name: [:0]const u8,
    value: i128,
};

/// The module constants of the namespace `M` (see `Constant`), in source order: what
/// `addConstants` adds and `setu.stub.constants` declares.
///
/// Example
///     >>> pub const IOSQE_IO_LINK = 1 << 2;
///     >>> pub const io_uring_op = enum(u8) { IORING_OP_NOP, IORING_OP_READV };
///     >>> constants(@This())
///     .{ .{ "IOSQE_IO_LINK", 4 }, .{ "IORING_OP_NOP", 0 }, .{ "IORING_OP_READV", 1 } }
pub fn constants(comptime M: type) []const Constant {
    @setEvalBranchQuota(1_000_000);
    var out: []const Constant = &.{};
    for (@typeInfo(M).@"struct".decl_names) |name| {
        const V = @TypeOf(@field(M, name));
        if (V == type) {
            const E = @field(M, name);
            if (@typeInfo(E) != .@"enum") continue;
            for (@typeInfo(E).@"enum".field_names) |f| {
                if (isUpperName(f)) out = out ++ .{Constant{ .name = f, .value = @backingInt(@field(E, f)) }};
            }
        } else if ((@typeInfo(V) == .int or @typeInfo(V) == .comptime_int) and isUpperName(name)) {
            out = out ++ .{Constant{ .name = name, .value = @field(M, name) }};
        }
    }
    return out;
}

/// An extension module, for `exportModule`.
pub const Module = struct {
    /// The module name: the extension file's name without its suffix (`setu_classes`).
    name: [:0]const u8,
    doc: ?[:0]const u8 = null,
    /// The module functions, ending with `method_end` (`exportFns(...) ++ .{method_end}`).
    methods: []const c.MethodDef = &.{method_end},
    /// `Py_mod_exec`: fills the module (classes, constants), `0` or `-1` with an exception set.
    exec: ?c.ModExec = null,
    /// `false` (`Py_MOD_GIL_NOT_USED`): safe without the GIL. `true` (`Py_MOD_GIL_USED`): the
    /// free-threaded CPython enables the GIL on import, for state that is not thread-safe.
    gil: bool = false,
    /// Can be imported in subinterpreters? Setu keeps state in globals, so the default is no.
    multiple_interpreters: bool = false,
};

/// Exports both entry points of the module, so one binary loads on CPython 3.14, 3.14t, 3.15,
/// 3.15t and later: `PyModExport_<name>` (PEP 793, with a stable free-threading-agnostic
/// `Py_mod_abi`), which 3.15+ prefers, and `PyInit_<name>`, which 3.14 calls. Call it in a
/// `comptime` block of the extension's root file.
///
/// Example
///     >>> comptime {
///     >>>     py.exportModule(.{ .name = "point", .methods = &methods, .exec = &exec });
///     >>> }
///     >>> import point
///     >>> point.__name__
///     'point'
///
/// Note
///     - On 3.14 the module comes from a static `PyModuleDef`, whose object header differs
///       between 3.14 and 3.14t: both are built, `PyInit_<name>` picks one by `sys.abiflags`.
pub fn exportModule(comptime m: Module) void {
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
                c.Slot.static(c.Py_mod_methods, m.methods.ptr),
            };
            if (m.doc) |d| s = s ++ .{c.Slot.data(c.Py_mod_doc, d.ptr)};
            if (m.exec) |f| s = s ++ .{c.Slot.func(c.Py_mod_exec, f)};
            s = s ++ .{c.Slot.uint(c.Py_mod_gil, gil)};
            if (!m.multiple_interpreters) s = s ++ .{c.Slot.uint(c.Py_mod_multiple_interpreters, interpreters)};
            break :blk (s ++ .{c.Slot.end})[0 .. s.len + 1].*;
        };
        var def_slots = blk: {
            var s: []const c.ModuleDefSlot = &.{};
            if (m.exec) |f| s = s ++ .{c.ModuleDefSlot{ .slot = c.Py_mod_exec_old, .value = f }};
            s = s ++ .{c.ModuleDefSlot{ .slot = c.Py_mod_gil_old, .value = @ptrFromInt(gil) }};
            if (!m.multiple_interpreters) s = s ++ .{c.ModuleDefSlot{
                .slot = c.Py_mod_multiple_interpreters_old,
                .value = @ptrFromInt(interpreters),
            }};
            break :blk (s ++ .{c.ModuleDefSlot.end})[0 .. s.len + 1].*;
        };
        var def_gil: c.ModuleDef(c.ObjectHeadGil) = .{
            .m_name = m.name.ptr,
            .m_doc = if (m.doc) |d| d.ptr else null,
            .m_methods = @constCast(m.methods.ptr),
            .m_slots = &def_slots,
        };
        var def_ft: c.ModuleDef(c.ObjectHeadFt) = .{
            .m_name = m.name.ptr,
            .m_doc = if (m.doc) |d| d.ptr else null,
            .m_methods = @constCast(m.methods.ptr),
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

/// Is this the free-threaded CPython? `t` in `sys.abiflags`.
fn freeThreaded() bool {
    const flags = c.PySys_GetObject("abiflags") orelse return false; // borrowed
    const text = c.PyUnicode_AsUTF8AndSize(flags, null) orelse {
        c.PyErr_Clear();
        return false;
    };
    return std.mem.findScalar(u8, std.mem.span(text), 't') != null;
}

/// Adds the constants of `M` (see `constants`) to `module` as ints, by name. For the module's
/// `Py_mod_exec`.
///
/// Example
///     >>> py.addConstants(module, @import("const.zig")) catch return -1;
///     >>> liburing.IOSQE_IO_LINK
///     4
pub fn addConstants(module: *Object, comptime M: type) py.Error!void {
    inline for (comptime constants(M)) |k| {
        const v = try py.new(if (k.value < 0) @as(i64, k.value) else @as(u64, k.value));
        defer py.decref(v);
        if (c.PyModule_AddObjectRef(module, k.name, v) < 0) return error.PythonError;
    }
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

test "isExported / constants: lowercase functions, UPPER_CASE ints and enum fields" {
    const M = struct {
        pub const IOSQE_IO_LINK = 1 << 2;
        pub const op = enum(u8) { IORING_OP_NOP, IORING_OP_READV, lower };
        pub const Small: u8 = 7;
        pub const B2 = -1;
        pub fn prep_nop() void {}
        pub fn prepHelper() void {}
    };
    comptime {
        testing.expect(isExported(M, "prep_nop"), "`prep_nop` exported");
        testing.expect(!isExported(M, "prepHelper"), "camelCase `prepHelper` not exported");
        testing.expect(!isExported(M, "IOSQE_IO_LINK"), "a constant is no function");
        const k = constants(M);
        testing.expectTexts(
            &.{ k[0].name, k[1].name, k[2].name, k[3].name },
            &.{ "IOSQE_IO_LINK", "IORING_OP_NOP", "IORING_OP_READV", "B2" },
        );
        testing.expect(k.len == 4, "4 constants");
        testing.expect(k[0].value == 4 and k[2].value == 1 and k[3].value == -1, "their values");
        testing.expect(isUpperName("AT_FDCWD") and isUpperName("B2"), "UPPER_CASE names");
        testing.expect(!isUpperName("Small") and !isUpperName("_1"), "not UPPER_CASE");
    }
}
