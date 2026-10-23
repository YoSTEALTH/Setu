//! Type stubs: `.pyi` text for the functions and classes Setu exports, built at comptime
//! from the same `pub fn`s, `///` docs and parameter names as the bindings.
//!
//! Types come from the doc's `Type` section (`name: type  # note` or `name: type - note`;
//! `return: type` for the result), else from the Zig type: `bool`, ints -> `int`, floats ->
//! `float`, `[]const u8` -> `str`, `py.Bytes` -> `bytes`, `py.Path` -> `str | bytes | os.PathLike`,
//! `py.Buffer` / `py.WritableBuffer` / `py.OwnedBuffer` / `py.OwnedWritableBuffer` -> `Buffer`, `py.Sequence(T)` ->
//! `Sequence[T]` (both `collections.abc`), slices -> `list[T]`, tuples -> `tuple[T, U]`, `void` -> `None`,
//! `?T` -> `T | None = None`, `py.Rest` -> `*name` (parameters before it: positional-only, then `/`), `py.KwOnly` -> `*`, `py.Kwargs` ->
//! `**name`, an argument struct's field with a default -> `= ...` (`= None` for `null`), `*T` / `*const T` (a
//! `setu.Class` instance) -> the class name, `*Object` and anything else -> `Any`. Bare generics in a `Type`
//! section get their arguments (`os.PathLike` -> `os.PathLike[str] | os.PathLike[bytes]`, `list` -> `list[Any]`,
//! ...).
//! Classes without `basetype` are `@final`, the others with instance data
//! `@disjoint_base` (PEP 800); `type_params` makes them generic (`class Name[T]:`, PEP 695).
//! Protocol hooks (`__eq__`, `__add__`, `__len__`, ...) become positional-only `def`s, typed like
//! methods (`*T` / `*const T` -> the class); class methods get `@classmethod`, static ones
//! `@staticmethod`, class attributes `NAME: ClassVar[int]`. The text needs `Any`, `ClassVar`,
//! `Generator`, `Self`, `disjoint_base` and `final` imported (`Buffer` / `Sequence` too, for those parameters),
//! plus whatever names the `Type` sections use.
//!
//! Example
//!     const text = setu.stub.constants(math) ++ setu.stub.functions(math, @embedFile("math.zig")) ++
//!         setu.stub.class(PointType);

const std = @import("std");
const py = @import("py.zig");
const class_zig = @import("class.zig");

const shortName = class_zig.shortName;

/// `def name(...) -> R:` with its docstring, for every exported `pub fn` of `M`.
pub fn functions(comptime M: type, comptime source: []const u8) []const u8 {
    @setEvalBranchQuota(10_000_000);
    var out: []const u8 = "";
    for (@typeInfo(M).@"struct".decl_names) |name| {
        if (py.isExported(M, name)) out = out ++ "\n" ++ function(@field(M, name), null, name, source, "");
    }
    return out;
}

/// `NAME: int` for every module constant of `M` (`py.constants`: UPPER_CASE `pub const` ints and
/// enum fields).
pub fn constants(comptime M: type) []const u8 {
    var out: []const u8 = "";
    for (py.constants(M)) |k| out = out ++ k.name ++ ": int\n";
    return out;
}

/// `class Name(Base):` with its docstring, `__init__`, properties, methods and protocol
/// hooks, for the `setu.Class` type `C`.
pub fn class(comptime C: type) []const u8 {
    @setEvalBranchQuota(10_000_000);
    const T = C.Data;
    const body = C.decl_source;
    const base = if (C.Base == void) "" else "(" ++ shortName(C.Base.name) ++ ")";
    // No Python subclasses without `basetype`; else an instance layout of its own (PEP 800).
    const subclassable = @hasDecl(T, "basetype") and T.basetype;
    const deco = if (!subclassable) "@final\n" else if (@sizeOf(T) > 0) "@disjoint_base\n" else "";
    const params = if (@hasDecl(T, "type_params")) "[" ++ T.type_params ++ "]" else "";
    var out: []const u8 = "\n" ++ deco ++ "class " ++ shortName(C.name) ++ params ++ base ++ ":\n" ++
        docstring(C.class_doc, "    ");
    for (@typeInfo(T).@"struct".decl_names) |n| {
        if (!class_zig.isClassAttr(T, n)) continue;
        const V = @TypeOf(@field(T, n));
        const ty = if (@typeInfo(V) == .pointer) "str" else pyType(V);
        out = out ++ "    " ++ n ++ ": ClassVar[" ++ ty ++ "]\n";
    }
    if (C.instantiable) out = out ++ init(C);
    for (@typeInfo(T).@"struct".decl_names) |n| {
        if (!class_zig.isGetter(T, n)) continue;
        const prop = n[4..];
        const g = @field(T, n);
        const doc = py.fnSource(body, n).doc;
        const R = docType(doc, "return") orelse pyType(@typeInfo(@TypeOf(g)).@"fn".return_type.?);
        out = out ++ "\n    @property\n    def " ++ prop ++ "(self) -> " ++ R ++ ":\n" ++ docstring(doc, "        ");
        if (@hasDecl(T, "set_" ++ prop)) {
            const U = @typeInfo(@TypeOf(@field(T, "set_" ++ prop))).@"fn".param_types[1].?;
            out = out ++ "\n    @" ++ prop ++ ".setter\n    def " ++ prop ++ "(self, value: " ++ pyType(U) ++
                ") -> None: ...\n";
        }
    }
    if (@hasDecl(T, "stub")) out = out ++ T.stub;
    for (@typeInfo(T).@"struct".decl_names) |n| {
        if (!class_zig.isMethod(T, n)) continue;
        const f = @field(T, n);
        out = out ++ "\n" ++ switch (py.methodKind(f, n, body)) {
            .static => "    @staticmethod\n" ++ function(f, null, n, body, "    "),
            .class => "    @classmethod\n" ++ function(f, "cls", n, body, "    "),
            else => function(f, "self", n, body, "    "),
        };
    }
    if (@hasDecl(T, "pickle") and T.pickle) out = out ++
        "\n    def __getstate__(self) -> tuple[Any, ...]: ...\n" ++
        "\n    def __setstate__(self, state: tuple[Any, ...], /) -> None: ...\n";
    out = out ++ hooks(C);
    return out;
}

/// The `def`s for the protocol hooks of the `setu.Class` `C` (see `class.zig`).
fn hooks(comptime C: type) []const u8 {
    const T = C.Data;
    const body = C.decl_source;
    var out: []const u8 = "";
    // A `__poll__` awaitable gets `__await__` and `__send__` from Setu; `await` gives its
    // `Type` doc's `return:` type.
    const poll = @hasDecl(T, "__poll__");
    if (@hasDecl(T, "__await__") or poll) {
        const R = docType(py.fnSource(body, if (poll) "__poll__" else "__await__").doc, "return") orelse "Any";
        out = out ++ "\n    def __await__(self) -> Generator[Any, Any, " ++ R ++ "]: ...\n";
    }
    // `__send__` is `am_send`, not a Python `send()` method.
    if (@hasDecl(T, "__send__") or poll) out = out ++
        "\n    def __iter__(self) -> Self: ...\n" ++
        "\n    def __next__(self) -> Any: ...\n";
    if (@hasDecl(T, "__bool__")) out = out ++ "\n    def __bool__(self) -> bool: ...\n";
    if (@hasDecl(T, "__repr__")) out = out ++ "\n    def __repr__(self) -> str: ...\n";
    if (@hasDecl(T, "__str__")) out = out ++ "\n    def __str__(self) -> str: ...\n";
    if (@hasDecl(T, "__getitem__")) out = out ++ hookDef(C, "__getitem__", .{});
    out = out ++ pair(C, "__setitem__", "__delitem__", .{ .ret = "None" }, 2, 1);
    if (@hasDecl(T, "__len__")) out = out ++ "\n    def __len__(self) -> int: ...\n";
    if (@hasDecl(T, "__contains__")) out = out ++ hookDef(C, "__contains__", .{ .ret = "bool" });
    for (.{ "__eq__", "__ne__" }) |n| if (@hasDecl(T, n)) {
        out = out ++ hookDef(C, n, .{ .types = &.{"object"} });
    };
    // `tp_richcompare` gives all four orderings: a missing one is its mirror (`a > b` is
    // `b < a`), or else unsupported.
    const has_compare = for (.{ "__eq__", "__ne__", "__lt__", "__le__", "__gt__", "__ge__" }) |n| {
        if (@hasDecl(T, n)) break true;
    } else false;
    for (.{ .{ "__lt__", "__gt__" }, .{ "__le__", "__ge__" }, .{ "__gt__", "__lt__" }, .{ "__ge__", "__le__" } }) |m| {
        if (@hasDecl(T, m[0])) {
            out = out ++ hookDef(C, m[0], .{});
        } else if (@hasDecl(T, m[1])) {
            out = out ++ hookDef(C, m[1], .{ .name = m[0] });
        } else if (has_compare) out = out ++ never(m[0], 1, &.{});
    }
    if (@hasDecl(T, "__hash__")) {
        out = out ++ "\n    def __hash__(self) -> int: ...\n";
    } else if (@hasDecl(T, "__eq__")) out = out ++ "    __hash__: ClassVar[None]  # type: ignore[assignment]\n";
    if (@hasDecl(T, "__call__")) out = out ++ "\n" ++ function(T.__call__, "self", "__call__", body, "    ");
    if (@hasDecl(T, "__iter__")) {
        out = out ++ hookDef(C, "__iter__", .{});
    } else if (@hasDecl(T, "__next__")) out = out ++ "\n    def __iter__(self) -> Self: ...\n";
    if (@hasDecl(T, "__next__")) {
        const Next = resultOf(T.__next__);
        out = out ++ hookDef(C, "__next__", .{ .ret = pyType(@typeInfo(Next).optional.child) });
    }
    // One `nb_<op>` slot gives `__<op>__` and `__r<op>__`; a missing half is unsupported.
    for (class_zig.number_ops) |op| {
        const fwd = "__" ++ op.name ++ "__";
        const rev = "__r" ++ op.name ++ "__";
        const inplace = "__i" ++ op.name ++ "__";
        const pow = std.mem.eql(u8, op.name, "pow");
        const extra: []const []const u8 = if (pow) &.{"mod: None = None"} else &.{};
        out = out ++ pair(C, fwd, rev, .{ .extra = extra }, 1, 1);
        if (@hasDecl(T, inplace))
            out = out ++ hookDef(C, inplace, .{
                .ret = if (resultOf(@field(T, inplace)) == void) "Self" else null,
                // mypy wants `__pow__`'s `mod` here too, which `**=` never passes
                .ignore = if (pow and (@hasDecl(T, fwd) or @hasDecl(T, rev))) "misc" else null,
            });
    }
    for (class_zig.unary_ops) |op| if (@hasDecl(T, op[0])) {
        out = out ++ hookDef(C, op[0], .{});
    };
    if (@hasDecl(T, "__getattr__")) out = out ++ hookDef(C, "__getattr__", .{ .types = &.{"str"} });
    if (@hasDecl(T, "__setattr__")) out = out ++ hookDef(C, "__setattr__", .{ .types = &.{"str"}, .ret = "None" });
    if (@hasDecl(T, "__delattr__")) out = out ++ hookDef(C, "__delattr__", .{ .types = &.{"str"}, .ret = "None" });
    if (@hasDecl(T, "__get__")) out = out ++ hookDef(C, "__get__", .{ .types = &.{ "Any", "Any | None = None" } });
    out = out ++ pair(C, "__set__", "__delete__", .{ .types = &.{"Any"}, .ret = "None" }, 2, 1);
    if (@hasDecl(T, "type_params")) out = out ++
        "\n    @classmethod\n    def __class_getitem__(cls, item: Any, /) -> GenericAlias: ...\n";
    return out;
}

/// What `hookDef` writes instead of the Zig types: the first `types` of the parameters (after
/// `self`), the return type `ret`, `extra` parameters at the end, another `name`.
const Override = struct {
    types: []const []const u8 = &.{},
    ret: ?[]const u8 = null,
    extra: []const []const u8 = &.{},
    name: ?[]const u8 = null,
    /// A mypy error code to ignore on the line.
    ignore: ?[]const u8 = null,
};

/// The two hooks `a` / `b` that share one slot (taking `na` / `nb` arguments): each declared one,
/// and the other as unsupported (`never`) when only one is.
fn pair(
    comptime C: type,
    comptime a: []const u8,
    comptime b: []const u8,
    comptime over: Override,
    comptime na: usize,
    comptime nb: usize,
) []const u8 {
    const T = C.Data;
    if (!@hasDecl(T, a) and !@hasDecl(T, b)) return "";
    const first = if (@hasDecl(T, a)) hookDef(C, a, over) else never(a, na, over.extra);
    var b_over = over;
    b_over.types = over.types[0..@min(over.types.len, nb)];
    return first ++ if (@hasDecl(T, b)) hookDef(C, b, b_over) else never(b, nb, over.extra);
}

/// `def name(self, other: Never, ...) -> NoReturn: ...`: a hook that exists at runtime (its slot
/// does) but supports no argument, so type checkers reject every use (`extra`: more parameters).
fn never(comptime name: []const u8, comptime n: usize, comptime extra: []const []const u8) []const u8 {
    var params: []const []const u8 = &.{"self"};
    for (0..n) |i| params = params ++ .{(if (i == 0) "other" else "value") ++ ": Never"};
    return "\n" ++ defLine("    ", name, params ++ extra ++ .{"/"}, "NoReturn") ++ " ...\n";
}

/// `def name(self, a: A, /) -> R: ...` for the protocol hook `name` of `C`: types from its doc's
/// `Type` section, else `over`, else the Zig types (see `pyType`).
fn hookDef(comptime C: type, comptime name: []const u8, comptime over: Override) []const u8 {
    const f = @field(C.Data, name);
    const src = py.fnSource(C.decl_source, name);
    const types = @typeInfo(@TypeOf(f)).@"fn".param_types;
    var params: []const []const u8 = &.{"self"};
    for (types[1..], 1..) |P, i| {
        const p = src.params[i];
        const ty = docType(src.doc, p) orelse if (i - 1 < over.types.len) over.types[i - 1] else pyType(P.?);
        params = params ++ .{p ++ ": " ++ ty};
    }
    params = params ++ over.extra;
    if (params.len > 1) params = params ++ .{"/"};
    const R = docType(src.doc, "return") orelse (over.ret orelse pyType(resultOf(f)));
    const ignore = if (over.ignore) |code| "  # type: ignore[" ++ code ++ "]" else "";
    return "\n" ++ defLine("    ", over.name orelse name, params, R) ++ " ..." ++ ignore ++ "\n";
}

/// The result type of `f`, without an error union.
fn resultOf(comptime f: anytype) type {
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    return if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
}

/// `__init__` from the parameters of the `__init__` hook, else `__new__` (`def __new__(cls, ...) -> Self`)
/// from those of the `__new__` hook: where Python passes the arguments. Types come from the class
/// doc's `Type` section, else from the Zig types.
fn init(comptime C: type) []const u8 {
    const T = C.Data;
    const hook: []const u8 = if (@hasDecl(T, "__init__")) "__init__" else if (@hasDecl(T, "__new__")) "__new__" else "";
    if (hook.len == 0) return "";
    const f = @field(T, hook);
    const new = std.mem.eql(u8, hook, "__new__");
    const first = if (new) "cls" else "self";
    const R = if (new) "Self" else "None";
    if (takesCallArgs(f)) return "\n    def " ++ hook ++ "(" ++ first ++ ", *args: Any, **kwargs: Any) -> " ++ R ++
        ": ...\n";
    return "\n" ++ signature(f, first, hook, hook, C.decl_source, C.class_doc, R, "    ") ++ " ...\n";
}

/// Does the hook `f` take the raw arguments (`self, setu.CallArgs`)?
fn takesCallArgs(comptime f: anytype) bool {
    const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
    return params.len == 2 and params[1].? == class_zig.CallArgs;
}

/// One `def`, with its docstring (`bound`: the name written for the skipped first parameter,
/// `self` / `cls`; `null` for a function or static method).
fn function(
    comptime f: anytype,
    comptime bound: ?[]const u8,
    comptime name: []const u8,
    comptime source: []const u8,
    comptime indent: []const u8,
) []const u8 {
    const doc = py.fnSource(source, name).doc;
    const R = docType(doc, "return") orelse pyType(@typeInfo(@TypeOf(f)).@"fn".return_type.?);
    const def = signature(f, bound, name, name, source, doc, R, indent);
    return if (doc.len == 0) def ++ " ...\n" else def ++ "\n" ++ docstring(doc, indent ++ "    ");
}

/// `def name(params) -> R:` for the `pub fn zig_name`; parameter types from `doc`'s `Type`
/// section, else from Zig.
fn signature(
    comptime f: anytype,
    comptime self_name: ?[]const u8,
    comptime name: []const u8,
    comptime zig_name: []const u8,
    comptime source: []const u8,
    comptime doc: []const u8,
    comptime R: []const u8,
    comptime indent: []const u8,
) []const u8 {
    const bound = self_name != null;
    var params: []const []const u8 = if (self_name) |n| &.{n} else &.{};
    var first: usize = @intFromBool(bound);
    if (py.hasRest(f, bound)) {
        const p = py.fnSource(source, zig_name).params[first];
        params = params ++ .{"*" ++ p ++ ": " ++ (docType(doc, p) orelse "Any")};
        first += 1;
    }
    const plist = py.paramList(f, first, zig_name, source);
    const lead = py.leadCount(plist);
    for (plist, 0..) |p, i| {
        if (p.kind == .kw_only) {
            params = params ++ .{"*"};
            continue;
        }
        const ty = docType(doc, p.name) orelse pyType(p.T);
        const none = p.default != null and std.mem.eql(u8, p.default.?, "None");
        const add_none = none and std.mem.find(u8, ty, "None") == null;
        const default = if (p.default == null) "" else if (none) " = None" else " = ...";
        params = params ++ .{p.name ++ ": " ++ ty ++ (if (add_none) " | None" else "") ++ default};
        if (lead > 0 and i + 1 == lead) { // positional-only, then `*args`
            const r = py.fnSource(source, zig_name).params[py.restIndex(f).?];
            params = params ++ .{ "/", "*" ++ r ++ ": " ++ (docType(doc, r) orelse "Any") };
        }
    }
    if (py.hasKwargs(f)) {
        const info = py.fnSource(source, zig_name);
        const k = info.params[info.params.len - 1];
        params = params ++ .{"**" ++ k ++ ": " ++ (docType(doc, k) orelse "Any")};
    }
    return defLine(indent, name, params, R);
}

/// `def name(a, b) -> R:`, one parameter per line (as `ruff format` would) when it is
/// longer than 120 characters.
pub fn defLine(
    comptime indent: []const u8,
    comptime name: []const u8,
    comptime params: []const []const u8,
    comptime R: []const u8,
) []const u8 {
    var one: []const u8 = "";
    for (params, 0..) |p, k| one = one ++ (if (k == 0) "" else ", ") ++ p;
    const line = indent ++ "def " ++ name ++ "(" ++ one ++ ") -> " ++ R ++ ":";
    if (line.len <= 120) return line;
    var out: []const u8 = indent ++ "def " ++ name ++ "(\n";
    for (params) |p| out = out ++ indent ++ "    " ++ p ++ ",\n";
    return out ++ indent ++ ") -> " ++ R ++ ":";
}

/// The type of `name` in the `Type` section of `doc`, if it has one.
pub fn docType(comptime doc: []const u8, comptime name: []const u8) ?[]const u8 {
    var in_type = false;
    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, " "), "Type")) {
            in_type = true;
            continue;
        }
        if (!in_type) continue;
        if (!std.mem.startsWith(u8, line, "    ")) {
            in_type = false;
            continue;
        }
        const item: []const u8 = std.mem.trim(u8, line, " ");
        const colon = std.mem.findScalar(u8, item, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, item[0..colon], " "), name)) continue;
        var ty: []const u8 = item[colon + 1 ..];
        if (std.mem.findScalar(u8, ty, '#')) |hash| ty = ty[0..hash];
        if (std.mem.find(u8, ty, " - ")) |dash| ty = ty[0..dash];
        return withArgs(std.mem.trim(u8, ty, " "));
    }
    return null;
}

/// Bare generics a `Type` section may use, and what they mean in the stub.
const generics = [_]struct { []const u8, []const u8 }{
    .{ "os.PathLike", "os.PathLike[str] | os.PathLike[bytes]" },
    .{ "Coroutine", "Coroutine[Any, Any, Any]" },
    .{ "list", "list[Any]" },
    .{ "tuple", "tuple[Any, ...]" },
    .{ "dict", "dict[Any, Any]" },
};

/// `ty` (`a | b | ...`) with type arguments added to the bare `generics`, so the docs can
/// say `os.PathLike` and the stub still type-checks with `--strict`.
fn withArgs(comptime ty: []const u8) []const u8 {
    var out: []const u8 = "";
    var it = std.mem.splitSequence(u8, ty, " | ");
    while (it.next()) |part| {
        const full = for (generics) |g| {
            if (std.mem.eql(u8, part, g[0])) break g[1];
        } else part;
        out = out ++ (if (out.len == 0) "" else " | ") ++ full;
    }
    return out;
}

/// The Python type for a Zig parameter or result type (`Any` when Zig can't tell).
pub fn pyType(comptime T: type) []const u8 {
    if (T == py.Bytes) return "bytes";
    if (T == py.Path) return "str | bytes | os.PathLike[str] | os.PathLike[bytes]";
    if (comptime py.isBuffer(T)) return "Buffer";
    if (comptime py.isSequence(T)) return "Sequence[" ++ pyType(T.Item) ++ "]";
    if (comptime class_zig.isInstancePtr(T)) return shortName(class_zig.Instance(@typeInfo(T).pointer.child).name);
    return switch (@typeInfo(T)) {
        .bool => "bool",
        .int, .comptime_int => "int",
        .float, .comptime_float => "float",
        .void => "None",
        .pointer => |p| if (T == []const u8 or T == [:0]const u8)
            "str"
        else if (p.size == .slice)
            "list[" ++ pyType(p.child) ++ "]"
        else
            "Any",
        .@"struct" => |s| if (s.is_tuple) blk: {
            var out: []const u8 = "tuple[";
            for (s.field_types, 0..) |F, i| out = out ++ (if (i == 0) "" else ", ") ++ pyType(F);
            break :blk out ++ "]";
        } else "Any",
        .optional => |o| pyType(o.child) ++ " | None",
        .error_union => |e| pyType(e.payload),
        else => "Any",
    };
}

/// `doc` as a `'''docstring'''` indented by `indent` (or `...` when there is none).
fn docstring(comptime doc: []const u8, comptime indent: []const u8) []const u8 {
    if (doc.len == 0) return indent ++ "...\n";
    var out: []const u8 = indent ++ "'''";
    for (doc, 0..) |ch, i| out = out ++ @as([]const u8, switch (ch) {
        '\\' => "\\\\",
        '\n' => if (i + 1 < doc.len and doc[i + 1] != '\n') "\n" ++ indent else "\n",
        // A quote that could end the docstring: part of `'''`, or last on a one-line doc.
        '\'' => if ((i + 1 == doc.len and std.mem.findScalar(u8, doc, '\n') == null) or
            std.mem.startsWith(u8, doc[i..], "'''")) "\\'" else "'",
        else => &.{ch},
    });
    return out ++ (if (std.mem.findScalar(u8, doc, '\n') != null) "\n" ++ indent else "") ++ "'''\n";
}

/// `text` laid out the way `ruff format` lays out a `.pyi`: no blank line between a class
/// member that is a one-line `def ...: ...` and the next member.
pub fn format(comptime text: []const u8) []const u8 {
    @setEvalBranchQuota(100_000_000);
    var out: []const u8 = "";
    var prev: []const u8 = "";
    var it = std.mem.splitScalar(u8, text, '\n');
    var pending_blank = false;
    while (it.next()) |line| {
        if (line.len == 0) {
            pending_blank = true;
            continue;
        }
        const member = std.mem.startsWith(u8, line, "    ");
        if (pending_blank and !(member and std.mem.endsWith(u8, prev, ": ..."))) out = out ++ "\n";
        pending_blank = false;
        out = out ++ line ++ "\n";
        prev = line;
    }
    return out;
}

const testing = @import("testing.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

/// The module functions and constants for the `functions` / `constants` test.
const sample = struct {
    /// What `stub_sample_mode` takes.
    pub const Mode = enum(u8) { FAST = 1, SLOW = 2 };
    pub const LIMIT = 3;
    pub const lower = 4;

    /// Adds `b` (default 0) to `a`.
    ///
    /// Type
    ///     a: int  # a note
    pub fn stub_sample_add(a: i64, b: ?i64) i64 {
        return a + (b orelse 0);
    }

    pub fn stub_sample_bufs(data: py.Buffer, all: py.Sequence(u8), out: ?py.OwnedWritableBuffer) void {
        _ = .{ data, all, out };
    }

    /// Zig-only (camelCase): not exported.
    pub fn sampleHelper() void {}
};

test "pyType: Zig parameter and result types as Python types" {
    comptime {
        testing.expectText(pyType(bool), "bool");
        testing.expectText(pyType(u8), "int");
        testing.expectText(pyType(f32), "float");
        testing.expectText(pyType(void), "None");
        testing.expectText(pyType([]const u8), "str");
        testing.expectText(pyType([:0]const u8), "str");
        testing.expectText(pyType([]const u32), "list[int]");
        testing.expectText(pyType(struct { i64, bool }), "tuple[int, bool]");
        testing.expectText(pyType(?u8), "int | None");
        testing.expectText(pyType(py.Error!u8), "int");
        testing.expectText(pyType(py.Bytes), "bytes");
        testing.expectText(pyType(py.Path), "str | bytes | os.PathLike[str] | os.PathLike[bytes]");
        testing.expectText(pyType(py.Buffer), "Buffer");
        testing.expectText(pyType(py.WritableBuffer), "Buffer");
        testing.expectText(pyType(py.OwnedBuffer), "Buffer");
        testing.expectText(pyType(py.OwnedWritableBuffer), "Buffer");
        testing.expectText(pyType(py.Sequence(py.Bytes)), "Sequence[bytes]");
        testing.expectText(pyType(*py.Object), "Any");
    }
}

test "docType: a `Type` section entry, generics completed" {
    const doc =
        \\Opens it.
        \\
        \\Type
        \\    path: str | os.PathLike  # a note
        \\    flags: int - a note
        \\    return: list
        \\
        \\Note
        \\    other: str
    ;
    comptime {
        @setEvalBranchQuota(100_000); // `function` / `class` set their own when they call it
        testing.expectText(docType(doc, "path").?, "str | os.PathLike[str] | os.PathLike[bytes]");
        testing.expectText(docType(doc, "flags").?, "int");
        testing.expectText(docType(doc, "return").?, "list[Any]");
        testing.expect(docType(doc, "other") == null, "no `Type` entry for `other` (in `Note`)");
        testing.expect(docType("", "path") == null, "no `Type` entry without a doc");
    }
}

test "defLine: one line up to 120 characters, else one parameter per line" {
    comptime {
        testing.expectText(defLine("", "f", &.{ "a: int", "b: int" }, "None"), "def f(a: int, b: int) -> None:");
        const long = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; // 50
        testing.expectText(
            defLine("    ", "g", &.{ long ++ ": int", long ++ "y: int" }, "int"),
            "    def g(\n        " ++ long ++ ": int,\n        " ++ long ++ "y: int,\n    ) -> int:",
        );
    }
}

test "format: no blank line after a one-line class member" {
    comptime testing.expectText(
        format("class A:\n    def f(self) -> None: ...\n\n    def g(self) -> None: ...\n\n\nx: int\n"),
        "class A:\n    def f(self) -> None: ...\n    def g(self) -> None: ...\n\nx: int\n",
    );
}

test "functions / constants: a namespace's exported functions and module constants" {
    comptime {
        testing.expectText(constants(sample), "FAST: int\nSLOW: int\nLIMIT: int\n");
        testing.expectText(functions(sample, @embedFile("stub.zig")),
            \\
            \\def stub_sample_add(a: int, b: int | None = None) -> int:
            \\    '''Adds `b` (default 0) to `a`.
            \\
            \\    Type
            \\        a: int  # a note
            \\    '''
            \\
            \\def stub_sample_bufs(data: Buffer, all: Sequence[int], out: Buffer | None = None) -> None: ...
            \\
        );
    }
}
