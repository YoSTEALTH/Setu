//! Python parameters of a Zig function (`Param`, `paramList`, the `Rest` / `KwOnly`
//! markers) and filling its arguments from a call (`fillArgs`, `parseArgs`, keyword lookup).
//! Re-exported by `py.zig`.

const std = @import("std");
const c = @import("capi.zig");
const py = @import("py.zig");
const convert = @import("convert.zig");
const raiseTypeError = @import("raise.zig").raiseTypeError;
const source_zig = @import("source.zig");

const Object = py.Object;
const Error = py.Error;
const incref = py.incref;
const decref = py.decref;
const none = py.none;
const fromPythonAs = convert.fromPythonAs;
const Bytes = convert.Bytes;
const Path = convert.Path;
const fnSource = source_zig.fnSource;
const structBody = source_zig.structBody;
const fieldDefaults = source_zig.fieldDefaults;
const pyDefault = source_zig.pyDefault;

/// Releases the arguments of `plist[0..count]` in `tuple` that hold a reference (`Path`),
/// after the call or when a later argument failed to convert.
pub fn releaseArgs(comptime F: type, comptime plist: []const Param, tuple: *std.meta.ArgsTuple(F)) void {
    inline for (plist) |p| {
        if (p.T == Path) {
            const v = if (p.field) |field| @field(tuple.*[p.arg], field) else tuple.*[p.arg];
            v.deinit();
        } else if (p.T == ?Path) {
            const v = if (p.field) |field| @field(tuple.*[p.arg], field) else tuple.*[p.arg];
            if (v) |x| x.deinit();
        }
    }
}

/// `*args`: the positional arguments, borrowed for the duration of the call.
pub const Rest = struct {
    items: []const *Object,

    /// A new tuple holding the arguments.
    pub fn tuple(self: Rest) Error!*Object {
        const t = c.PyTuple_New(@intCast(self.items.len)) orelse return error.PythonError; // cast: a slice length
        for (self.items, 0..) |o, i| {
            incref(o);
            _ = c.PyTuple_SetItem(t, @intCast(i), o); // steals the reference; cast: an index
        }
        return t;
    }
};

/// `**kwargs`: a last parameter of this type collects the keyword arguments no other parameter
/// takes (instead of a `TypeError`), as a dict borrowed for the duration of the call.
///
/// Example
///     >>> pub fn to_thread(func: *Object, args: py.Rest, kwargs: py.Kwargs) Error!*Object
///     >>> await to_thread(print, 'a', 'b', sep='-')  # kwargs.dict: {'sep': '-'}
///
/// Note
///     - For functions and methods; not for `__init__` / `__new__` (use `setu.CallArgs` there).
pub const Kwargs = struct {
    /// The extra keyword arguments, or `null` when there are none.
    dict: ?*Object = null,
};

/// `*` in a Python signature: every parameter after a `_: py.KwOnly` parameter can only be
/// given by keyword. The marker itself takes no argument.
///
/// Example
///     >>> pub fn open(path: *Object, flags: ?u64, mode: ?u64, resolve: ?u64, _: py.KwOnly, dir_fd: ?i32)
///     >>> await open('a.txt', O_RDONLY, dir_fd=fd)
///     3
///     >>> await open('a.txt', O_RDONLY, 0, 0, fd)
///     TypeError: open() takes at most 4 positional arguments (5 given)
///
/// Note
///     - Not with a `Rest`: after `*args` every named parameter is keyword-only already.
pub const KwOnly = struct {};

/// Where the `KwOnly` marker is in `plist`: the number of parameters that can be given
/// positionally (all of them without a marker).
pub fn positionalCount(comptime plist: []const Param) usize {
    for (plist, 0..) |p, at| if (p.kind == .kw_only) return at;
    return plist.len;
}

/// The names of `plist` (the `KwOnly` marker's too, which takes no keyword; a positional-only
/// one is `""`, which no keyword matches).
pub fn paramNames(comptime plist: []const Param) []const [:0]const u8 {
    var out: []const [:0]const u8 = &.{};
    for (plist) |p| out = out ++ .{if (p.kind == .positional_only) "" else p.name};
    return out;
}

/// How many parameters of `plist` come before a `py.Rest` (positional-only).
pub fn leadCount(comptime plist: []const Param) usize {
    var n = 0;
    for (plist) |p| n += @intFromBool(p.kind == .positional_only);
    return n;
}

/// One Python parameter: a Zig parameter, or a field of a `struct` parameter (an
/// argument struct, like PyOZ's `Args`). Built at comptime by `paramList`.
///
/// Example
///     >>> pub fn __init__(self: *Statx, a: struct {
///     ...     path: ?*Object = null,
///     ...     flags: u32 = 0,
///     ...     _: py.KwOnly = .{},
///     ...     dir_fd: i32 = kernel.AT_FDCWD,
///     ... }) void
///     >>> inspect.signature(Statx)
///     <Signature (path=None, flags=0, *, dir_fd=AT_FDCWD)>
///
/// Note
///     - A field default shows as written: `null` is `None`, `true` / `false` are `True` /
///       `False`, numbers and `"strings"` as they are, `a.b.NAME` as `NAME` (so the module
///       must export `NAME` for `inspect.signature` to resolve it).
///     - A field without a default is required (even a `?T` one); a plain `?T` parameter
///       defaults to `None`, as before.
///     - `_: py.KwOnly = .{}` (a field or a parameter) starts the keyword-only ones.
pub const Param = struct {
    /// The Python name (the Zig parameter or field name).
    name: [:0]const u8,
    /// The Zig type the argument converts to.
    T: type,
    /// Its Zig parameter (index into the arguments tuple).
    arg: usize,
    /// The field it fills, when its Zig parameter is an argument struct.
    field: ?[:0]const u8 = null,
    /// `.kw_only`: the `KwOnly` marker (takes no argument); `.positional_only`: a parameter
    /// before a `py.Rest` (`f(func, /, *args)`).
    kind: enum { value, kw_only, positional_only } = .value,
    /// The default as Python source (`None`, `0`, `AT_FDCWD`); `null`: required.
    default: ?[]const u8 = null,
    /// A field's default value (a `*const T`).
    value: ?*const anyopaque = null,
};

/// The Python parameters of `f` from its Zig parameter `first` on (after `self` and a
/// `Rest`), with names and defaults from the `pub fn fname` in `source`; see `Param`.
pub fn paramList(
    comptime f: anytype,
    comptime first: usize,
    comptime fname: []const u8,
    comptime source: []const u8,
) []const Param {
    @setEvalBranchQuota(1_000_000);
    const types = @typeInfo(@TypeOf(f)).@"fn".param_types;
    const info = fnSource(source, fname);
    var out: []const Param = &.{};
    for (types[first..], first..) |P, i| {
        const T = P orelse @compileError(fname ++ ": `anytype` parameters are not supported");
        const name = info.params[i];
        if (T == Rest) { // the parameters before it are positional-only (`f(func, /, *args)`)
            for (out) |*p| {
                if (p.field != null or p.default != null or p.kind != .value)
                    @compileError(fname ++ ": only plain required parameters can come before `py.Rest`");
            }
            var lead: []const Param = &.{};
            for (out) |p| {
                var q = p;
                q.kind = .positional_only;
                lead = lead ++ .{q};
            }
            out = lead;
            continue;
        }
        if (T == Kwargs) {
            if (i != types.len - 1) @compileError(fname ++ ": `py.Kwargs` must be the last parameter");
            continue; // filled by the trampoline
        }
        if (T == KwOnly) {
            out = out ++ .{Param{ .name = name, .T = T, .arg = i, .kind = .kw_only }};
        } else if (isArgStruct(T)) {
            const s = @typeInfo(T).@"struct";
            const defaults = fieldDefaults(structBody(source, info.types[i], fname));
            for (s.field_names, s.field_types, s.field_attrs) |field, F, attrs| {
                if (F == KwOnly) {
                    out = out ++ .{Param{ .name = field, .T = F, .arg = i, .field = field, .kind = .kw_only }};
                    continue;
                }
                const text: ?[]const u8 = if (attrs.default_value_ptr == null) null else for (defaults) |d| {
                    if (std.mem.eql(u8, d[0], field)) break pyDefault(d[1], fname ++ "(" ++ field ++ ")");
                } else @compileError(fname ++ ": no default for `" ++ field ++ "` in the source");
                out = out ++ .{Param{
                    .name = field,
                    .T = F,
                    .arg = i,
                    .field = field,
                    .default = text,
                    .value = attrs.default_value_ptr,
                }};
            }
        } else {
            const default: ?[]const u8 = if (@typeInfo(T) == .optional) "None" else null;
            out = out ++ .{Param{ .name = name, .T = T, .arg = i, .default = default }};
        }
    }
    var markers = 0;
    for (out) |p| markers += @intFromBool(p.kind == .kw_only);
    if (markers > 1) @compileError(fname ++ ": more than one `py.KwOnly`");
    return out;
}

/// Is the parameter type `T` an argument struct (a `struct`, but not a tuple or a Setu
/// value type like `Bytes` / `Path`)?
fn isArgStruct(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or @typeInfo(T).@"struct".is_tuple) return false;
    return T != Bytes and T != Path and T != Rest and T != KwOnly and T != Kwargs;
}

/// `self` as the type `P` of a method's first parameter: `*Object` as is, the type object
/// (`*c.TypeObject`, a class method's `cls`), or the instance data (`*T` / `*const T`) of the
/// class `Owner` (a `setu.Class`).
pub fn selfArg(comptime Owner: type, comptime P: type, obj: *Object) P {
    if (P == *Object) return obj;
    if (P == *c.TypeObject) return @ptrCast(obj);
    if (Owner == void) @compileError("`self` must be `*Object` outside a `setu.Class`");
    return Owner.data(obj);
}

/// Converts `slots` (one per `Param` of `plist`; `null`: not given) into `tuple`. A missing
/// argument gets its default (`null` for a plain `?T`); a missing required one raises
/// `TypeError` (`f() missing required argument 'x'`).
pub fn fillArgs(
    comptime F: type,
    comptime plist: []const Param,
    comptime fname: []const u8,
    slots: []const ?*Object,
    tuple: *std.meta.ArgsTuple(F),
) Error!void {
    inline for (plist, 0..) |p, at| {
        const v: p.T = fillOne(p, fname, slots[at]) catch |err| {
            releaseArgs(F, plist[0..at], tuple);
            return err;
        };
        if (p.field) |field| {
            @field(tuple.*[p.arg], field) = v;
        } else tuple.*[p.arg] = v;
    }
}

/// The value of the parameter `p` of `fname` from its argument `slot` (`null`: not given).
inline fn fillOne(comptime p: Param, comptime fname: []const u8, slot: ?*Object) Error!p.T {
    if (p.kind == .kw_only) return .{};
    if (slot) |o| {
        const what = "`" ++ fname ++ "(" ++ p.name ++ ")`";
        const v = if (@typeInfo(p.T) == .optional) optionalArg(p.T, o, what) else fromPythonAs(p.T, o, what);
        return v catch |err| {
            const T = if (@typeInfo(p.T) == .optional) @typeInfo(p.T).optional.child else p.T;
            const want: ?[]const u8 = if (T == []const u8 or T == [:0]const u8)
                "str"
            else if (T == Bytes)
                "bytes"
            else
                null;
            if (want) |w| if (c.PyErr_ExceptionMatches(c.PyExc_TypeError) != 0) {
                c.PyErr_Clear();
                return raiseTypeError("{s}() argument '{s}' must be `{s}`", .{ fname, p.name, w });
            };
            return err;
        };
    }
    if (p.value) |d| return @as(*const p.T, @ptrCast(@alignCast(d))).*;
    if (p.field == null and @typeInfo(p.T) == .optional) return null;
    return raiseTypeError("{s}() missing required argument '{s}'", .{ fname, p.name });
}

/// Keyword lookup for the parameter `names`: the index of a keyword, or `null` if no
/// parameter takes it. `skip` is the `KwOnly` marker's index (no keyword), or `names.len`.
///
/// Example
///     >>> KwNames(&.{ "path", "mode" }, 2).find(key)  // key: the str 'mode'
///     1
///
/// Note
///     - Each name is interned once (kept for the process lifetime), so a keyword is
///       usually found by pointer: CPython interns the keyword names written in code.
///       Others (built at run time, `**dict` keys) fall back to comparing the text.
pub fn KwNames(comptime names: []const [:0]const u8, comptime skip: usize) type {
    return struct {
        var interned: [names.len]?*Object = @splat(null);

        /// The index of the keyword `key` in `names`, or `null`.
        pub fn find(key: *Object) ?usize {
            inline for (0..names.len) |i| {
                if (i != skip and (load(i) orelse intern(i)) == key) return i;
            }
            inline for (names, 0..) |n, i| {
                if (i != skip and c.PyUnicode_EqualToUTF8(key, n) != 0) return i;
            }
            return null;
        }

        /// The interned name `i`, if made already.
        inline fn load(comptime i: usize) ?*Object {
            return @atomicLoad(?*Object, &interned[i], .acquire);
        }

        /// Interns name `i` (a racing thread's result wins; a failure only skips the fast path).
        fn intern(comptime i: usize) ?*Object {
            const s = c.PyUnicode_InternFromString(names[i]) orelse {
                c.PyErr_Clear();
                return null;
            };
            if (@cmpxchgStrong(?*Object, &interned[i], null, s, .acq_rel, .acquire)) |won| {
                decref(s);
                return won;
            }
            return s;
        }
    };
}

/// Positional + keyword arguments of a `tp_init` / `tp_new` call, by name.
/// The first `required` names must be given; the rest may be missing (`null`). Only the
/// first `max_positional` may be positional (`positionalCount`; `names[max_positional]` is
/// then the `KwOnly` marker, which takes no keyword either).
/// Items are borrowed from `args` / `kwargs` for the duration of the call.
pub fn parseArgs(
    comptime fname: []const u8,
    comptime names: []const [:0]const u8,
    comptime required: usize,
    comptime max_positional: usize,
    args: *Object,
    kwargs: ?*Object,
) Error![names.len]?*Object {
    var out: [names.len]?*Object = @splat(null);
    const nargs: usize = @intCast(c.PyTuple_Size(args)); // cast: a size, never < 0
    if (nargs > max_positional) return raiseTypeError(
        "{s}() takes at most {d} positional arguments ({d} given)",
        .{ fname, max_positional, nargs },
    );
    if (comptime names.len == 0) { // no parameters: only an empty call is fine
        if (kwargs) |kw| if (c.PyDict_Size(kw) > 0) return raiseTypeError("{s}() takes no keyword arguments", .{fname});
        return out;
    }
    for (0..nargs) |i| out[i] = c.PyTuple_GetItem(args, @intCast(i)); // cast: an index < `nargs`
    if (kwargs) |kw| {
        var pos: c.ssize = 0;
        var key: ?*Object = null;
        var value: ?*Object = null;
        while (c.PyDict_Next(kw, &pos, &key, &value) != 0) {
            const at = KwNames(names, max_positional).find(key.?) orelse
                return raiseTypeError("{s}() got an unexpected keyword argument", .{fname});
            if (out[at] != null) return raiseTypeError(
                "{s}() got multiple values for argument '{s}'",
                .{ fname, names[at] },
            );
            out[at] = value;
        }
    }
    inline for (0..required) |i| {
        if (out[i] == null) return raiseTypeError(
            "{s}() missing required argument '{s}'",
            .{ fname, names[i] },
        );
    }
    return out;
}

/// `?T`: `None` gives `null`, except for raw `?*Object`, where `None` is a value
/// like any other (only a missing argument is `null`).
/// `what` names it in an `OverflowError` (`fromPythonAs`).
fn optionalArg(comptime T: type, obj: *Object, comptime what: []const u8) Error!T {
    if (T == ?*Object) return obj;
    if (obj == none()) return null;
    return try fromPythonAs(@typeInfo(T).optional.child, obj, what);
}
