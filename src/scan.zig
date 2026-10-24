//! The `Module.from` scan: which `pub` declarations of the namespaces an extension lists become its
//! Python functions, classes, exceptions, constants and `IntEnum`s. All comptime: `py.exportModule`
//! generates the method table and `Py_mod_exec` from it, `setu.stub.module` the `.pyi`.
//!
//! One `pub` declaration `name` of an entry's `ns` becomes:
//!
//!     pub fn snake_name(...)              a function (lowercase name, see `py.isExported`); needs the
//!                                         entry's `source`, skipped with `.functions = false`
//!     pub const XType = setu.Class(X, s)  a class (Python name: the struct's); created bases first,
//!                                         added to the module unless `X.hidden`
//!     pub const Name = setu.Exception(.)  an exception class named `Name`
//!     pub const E = enum { ... }          its UPPER_CASE fields as int constants (`.enums =
//!                                         .constants`), or the `IntEnum` `E` (`.enums = .int_enum`)
//!     pub const NAME = 1 / 1.5 / true / "x"
//!                                         a constant (UPPER_CASE; int, float, `bool` or string)
//!
//! Skipped: names starting with `_`, camelCase `pub fn`s (Zig helpers), plain structs and other
//! types, lowercase values and `pub var`s. Filters (`only`, `exclude`, `prefixes`) take Python names.
//! A Python name found twice (in two entries, or twice in one) is a compile error naming both.

const std = @import("std");
const export_zig = @import("export.zig");
const class_zig = @import("class.zig");

const Constant = export_zig.Constant;

/// What a `setu.Class` / `setu.Exception` type is to the scan (its `setu_kind` declaration).
pub const Kind = enum { class, exception };

/// One namespace for `Module.from`: its `pub` declarations become the module's functions, classes,
/// exceptions, constants and `IntEnum`s (see the top of this file).
///
/// Example
///     >>> .from = &.{
///     >>>     .{ .ns = @import("ring.zig") }, // classes only: no `source` needed
///     >>>     .{ .ns = @import("prep.zig"), .source = @embedFile("prep.zig") },
///     >>>     .{ .ns = @import("sqe.zig"), .functions = false }, // lowercase Zig helpers there
///     >>>     .{ .ns = kernel, .prefixes = &.{ "IOSQE_", "IORING_OP_" } },
///     >>>     .{ .ns = @import("enum.zig"), .enums = .int_enum },
///     >>> },
///     >>> liburing.io_uring_prep_nop, liburing.IOSQE_IO_LINK, liburing.io_uring_op.IORING_OP_NOP
///     (<built-in function io_uring_prep_nop>, 4, <io_uring_op.IORING_OP_NOP: 0>)
pub const From = struct {
    /// The namespace: a file (`@import("x.zig")`) or any `struct` type.
    ns: type,
    /// `@embedFile` of the file that defines `ns`: parameter names, defaults and `///` docs of its
    /// functions, the module's default doc (`//!`). Only functions need it (a `setu.Class` carries its
    /// own source): a function in an entry without it is a compile error.
    source: ?[]const u8 = null,
    /// Only these Python names (each must match one; an enum's name stands for its constants); not
    /// together with `exclude`.
    only: ?[]const []const u8 = null,
    /// Not these Python names (each must match one; an enum's name stands for its constants).
    exclude: ?[]const []const u8 = null,
    /// Only names starting with one of these (`&.{ "IOSQE_", "O_" }`).
    prefixes: ?[]const []const u8 = null,
    /// `false`: no function, for a file whose lowercase `pub fn`s are Zig helpers.
    functions: bool = true,
    /// What a `pub const E = enum` becomes.
    enums: Enums = .constants,

    /// What `enums` can be.
    pub const Enums = enum {
        /// Its UPPER_CASE fields, as int constants of the module.
        constants,
        /// `IntEnum("E", [(field, value), ...], module=<module>)`, every field a member.
        int_enum,
    };
};

/// What one found declaration is to Python.
pub const ItemKind = enum { function, class, exception, constant, int_enum };

/// One declaration the scan found (see `Scan`).
pub const Item = struct {
    kind: ItemKind,
    /// The Python name (an enum field's for an enum's constants).
    name: [:0]const u8,
    /// The index of its entry in `Module.from`.
    entry: usize,
    /// The declaration in the entry's `ns`.
    decl: [:0]const u8,
    /// A constant's value.
    value: ?Constant.Value = null,
    /// A hidden class (`hidden = true`): created, not added to the module, not in the stub.
    hidden: bool = false,
};

/// What `entries` (a `Module.from`) declare, by kind, each in entry and source order; classes bases
/// first. `skip` are Python names taken elsewhere (`Module.methods`): a function of that name is
/// left out.
///
/// Example
///     >>> const S = Scan(&.{.{ .ns = @import("math.zig"), .source = @embedFile("math.zig") }}, &.{});
///     >>> S.functions[0].name
///     "add"
pub fn Scan(comptime entries: []const From, comptime skip: []const []const u8) type {
    @setEvalBranchQuota(100_000_000);
    var all: []const Item = &.{};
    for (entries, 0..) |e, i| all = all ++ entryItems(i, e);
    var kept: []const Item = &.{};
    for (all) |it| {
        if (it.kind == .function and contains(skip, it.name)) continue;
        kept = kept ++ .{it};
    }
    checkUnique(entries, kept);
    const final = kept;
    return struct {
        pub const functions = only(final, .function);
        pub const classes = basesFirst(entries, only(final, .class));
        pub const exceptions = only(final, .exception);
        pub const constants = only(final, .constant);
        pub const int_enums = only(final, .int_enum);

        /// The declaration `it` stands for.
        pub fn decl(comptime it: Item) @TypeOf(@field(entries[it.entry].ns, it.decl)) {
            return @field(entries[it.entry].ns, it.decl);
        }

        /// The `source` of `it`'s entry (a function's: always set).
        pub fn source(comptime it: Item) []const u8 {
            return entries[it.entry].source.?;
        }

        /// The `///` doc above `pub const <decl> =` in `it`'s entry's `source` (empty without one).
        pub fn declDoc(comptime it: Item) []const u8 {
            @setEvalBranchQuota(100_000_000); // `find` over the whole file
            const text = entries[it.entry].source orelse return "";
            const at = std.mem.find(u8, text, "pub const " ++ it.decl ++ " =") orelse return "";
            return @import("source.zig").docAbove(text, at);
        }
    };
}

/// The items of `entry` (number `i`), filtered (see `From`).
fn entryItems(comptime i: usize, comptime e: From) []const Item {
    const M = e.ns;
    const where = @typeName(M);
    if (e.only != null and e.exclude != null) @compileError(where ++ ": `.only` and `.exclude` together");
    var found: []const Item = &.{};
    for (@typeInfo(M).@"struct".decl_names) |name| {
        if (name[0] == '_') continue;
        const V = @TypeOf(@field(M, name));
        if (V == type) {
            const T = @field(M, name);
            switch (@typeInfo(T)) {
                .@"struct" => if (@hasDecl(T, "setu_kind") and @TypeOf(T.setu_kind) == Kind) {
                    found = found ++ .{switch (T.setu_kind) {
                        .class => Item{
                            .kind = .class,
                            .name = shortNameZ(T.name),
                            .entry = i,
                            .decl = name,
                            .hidden = T.hidden,
                        },
                        .exception => Item{ .kind = .exception, .name = name, .entry = i, .decl = name },
                    }};
                },
                .@"enum" => switch (e.enums) {
                    .int_enum => found = found ++ .{Item{ .kind = .int_enum, .name = name, .entry = i, .decl = name }},
                    .constants => for (export_zig.enumConstants(T)) |k| {
                        found = found ++ .{Item{
                            .kind = .constant,
                            .name = k.name,
                            .entry = i,
                            .decl = name,
                            .value = k.value,
                        }};
                    },
                },
                else => {},
            }
        } else if (@typeInfo(V) == .@"fn") {
            if (export_zig.isExported(M, name))
                found = found ++ .{Item{ .kind = .function, .name = name, .entry = i, .decl = name }};
        } else if (export_zig.constantValue(M, name)) |v| {
            found = found ++ .{Item{ .kind = .constant, .name = name, .entry = i, .decl = name, .value = v }};
        }
    }
    for (e.only orelse &.{}) |n| if (!has(found, n))
        @compileError(where ++ ": `.only` names `" ++ n ++ "`, which it does not declare");
    for (e.exclude orelse &.{}) |n| if (!has(found, n))
        @compileError(where ++ ": `.exclude` names `" ++ n ++ "`, which it does not declare");
    var out: []const Item = &.{};
    for (found) |it| {
        if (e.only) |ns| if (!matchesAny(it, ns)) continue;
        if (e.exclude) |ns| if (matchesAny(it, ns)) continue;
        if (e.prefixes) |ps| if (!startsWithAny(it.name, ps)) continue;
        if (it.kind == .function) {
            if (!e.functions) continue;
            if (e.source == null) @compileError(where ++ ": `pub fn " ++ it.name ++ "` needs the entry's " ++
                "`.source = @embedFile(...)` (or `.functions = false` for Zig helpers, `.exclude` for one)");
        }
        out = out ++ .{it};
    }
    return out;
}

/// A compile error for a Python name taken twice, or one `setu.Class` / `setu.Exception` type under two
/// names (two `setu.Exception`s with the same options are one type).
fn checkUnique(comptime entries: []const From, comptime items: []const Item) void {
    for (items, 0..) |a, i| for (items[i + 1 ..]) |b| {
        const same_type = (a.kind == .class or a.kind == .exception) and a.kind == b.kind and
            @field(entries[a.entry].ns, a.decl) == @field(entries[b.entry].ns, b.decl);
        if (same_type) @compileError("`" ++ origin(entries, a) ++ "` and `" ++ origin(entries, b) ++
            "` are the same type" ++ (if (a.kind == .exception) ": give each `setu.Exception` its own `.doc`" else ""));
        if (a.hidden or b.hidden or !std.mem.eql(u8, a.name, b.name)) continue;
        @compileError("`" ++ a.name ++ "` is in the module twice: `" ++ origin(entries, a) ++ "` and `" ++
            origin(entries, b) ++ "`");
    };
}

/// `<namespace>.<decl>`, for an error message.
fn origin(comptime entries: []const From, comptime it: Item) []const u8 {
    return @typeName(entries[it.entry].ns) ++ "." ++ it.decl;
}

/// The `classes` ordered so each comes after its `base` (otherwise in their order); a base that is in
/// no entry is a compile error.
fn basesFirst(comptime entries: []const From, comptime classes: []const Item) []const Item {
    @setEvalBranchQuota(100_000_000); // `Scan`'s quota does not reach its decls (evaluated on first use)
    var out: []const Item = &.{};
    for (classes) |it| out = withBases(entries, classes, out, it);
    return out;
}

/// `out` plus `it`, after its bases (those not in `out` yet).
fn withBases(
    comptime entries: []const From,
    comptime classes: []const Item,
    comptime out: []const Item,
    comptime it: Item,
) []const Item {
    const C = @field(entries[it.entry].ns, it.decl);
    for (out) |o| if (@field(entries[o.entry].ns, o.decl) == C) return out;
    if (C.Base == void) return out ++ .{it};
    const base = for (classes) |b| {
        if (@field(entries[b.entry].ns, b.decl) == C.Base) break b;
    } else @compileError("`" ++ origin(entries, it) ++ "`: its base `" ++ C.Base.name ++
        "` is in no `Module.from` entry");
    return withBases(entries, classes, out, base) ++ .{it};
}

/// The items of `kind`.
fn only(comptime items: []const Item, comptime kind: ItemKind) []const Item {
    @setEvalBranchQuota(100_000_000); // see `basesFirst`
    var out: []const Item = &.{};
    for (items) |it| if (it.kind == kind) {
        out = out ++ .{it};
    };
    return out;
}

/// Does an item match `name` (see `matches`)?
fn has(comptime items: []const Item, comptime name: []const u8) bool {
    for (items) |it| if (matches(it, name)) return true;
    return false;
}

/// Does `it` match one of `names` (see `matches`)?
fn matchesAny(comptime it: Item, comptime names: []const []const u8) bool {
    for (names) |n| if (matches(it, n)) return true;
    return false;
}

/// Is `name` the Python name of `it`, or the enum whose field it is (so `.exclude = &.{"Mode"}` drops
/// every constant of `Mode`)?
fn matches(comptime it: Item, comptime name: []const u8) bool {
    if (std.mem.eql(u8, it.name, name)) return true;
    return it.kind == .constant and !std.mem.eql(u8, it.decl, it.name) and std.mem.eql(u8, it.decl, name);
}

/// Is `name` one of `names`?
fn contains(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Does `name` start with one of `prefixes`?
fn startsWithAny(comptime name: []const u8, comptime prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

/// The last dotted part of `name`, 0-terminated.
fn shortNameZ(comptime name: [:0]const u8) [:0]const u8 {
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return name;
    return name[dot + 1 ..];
}

const testing = @import("testing.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

/// The Python names of `items`.
fn pyNames(comptime items: []const Item) []const []const u8 {
    var out: []const []const u8 = &.{};
    for (items) |it| out = out ++ .{it.name};
    return out;
}

const ScanBase = struct {
    pub const name = "pkg.ScanBase";
    pub const basetype = true;
};
const ScanDerived = struct {
    pub const name = "pkg.ScanDerived";
    pub const base = scan_sample.ScanBaseType;
};
const ScanHidden = struct {
    pub const name = "pkg.ScanHidden";
    pub const hidden = true;
};

/// A namespace with one declaration of each kind the scan knows (and some it skips).
const scan_sample = struct {
    pub const ScanDerivedType = class_zig.Class(ScanDerived, @embedFile("scan.zig")); // before its base
    pub const ScanBaseType = class_zig.Class(ScanBase, @embedFile("scan.zig"));
    pub const ScanHiddenType = class_zig.Class(ScanHidden, @embedFile("scan.zig"));
    pub const ScanError = @import("exception.zig").Exception(.{ .doc = "A sample." });
    pub const LIMIT = 3;
    pub const RATIO = 0.5;
    pub const Mode = enum(u8) { FAST = 1, SLOW, other };
    pub const Plain = struct { x: u8 };
    pub const lower = 4;
    pub var COUNT: u8 = 0;
    pub const _SKIPPED = 1;
    pub fn scan_add(a: i64) i64 {
        return a;
    }
    pub fn scanHelper() void {}
    pub fn _scan_private() void {}
};

const scan_kernel = struct {
    pub const K_ONE = 1;
    pub const K_TWO = 2;
    pub const OTHER = 3;
};

const scan_modes = struct {
    pub const Op = enum(u8) { nop, read };
};

test "Scan: kinds, bases first, `_` names, prefixes, int enums" {
    comptime {
        const S = Scan(&.{
            .{ .ns = scan_sample, .source = @embedFile("scan.zig") },
            .{ .ns = scan_kernel, .prefixes = &.{"K_"} },
            .{ .ns = scan_modes, .enums = .int_enum },
        }, &.{});
        testing.expectTexts(pyNames(S.functions), &.{"scan_add"});
        testing.expectTexts(pyNames(S.classes), &.{ "ScanBase", "ScanDerived", "ScanHidden" });
        testing.expect(!S.classes[0].hidden and S.classes[2].hidden, "`ScanHidden` hidden");
        testing.expectTexts(pyNames(S.exceptions), &.{"ScanError"});
        testing.expectTexts(pyNames(S.constants), &.{ "LIMIT", "RATIO", "FAST", "SLOW", "K_ONE", "K_TWO" });
        testing.expect(S.constants[1].value.?.float == 0.5 and S.constants[3].value.?.int == 2, "values");
        testing.expectTexts(pyNames(S.int_enums), &.{"Op"});
        testing.expect(S.decl(S.int_enums[0]) == scan_modes.Op, "`decl` gives the declaration");
        testing.expect(S.int_enums[0].entry == 2, "the entry's index");
    }
}

test "Scan: `only`, `exclude`, `functions = false`, names taken by `Module.methods`" {
    comptime {
        const only_ = Scan(&.{.{ .ns = scan_sample, .only = &.{ "LIMIT", "ScanError" } }}, &.{});
        testing.expectTexts(pyNames(only_.constants), &.{"LIMIT"});
        testing.expectTexts(pyNames(only_.exceptions), &.{"ScanError"});
        testing.expect(only_.functions.len == 0 and only_.classes.len == 0, "nothing else");
        const S = Scan(&.{.{ .ns = scan_sample, .exclude = &.{ "FAST", "ScanHidden" }, .functions = false }}, &.{});
        testing.expect(S.functions.len == 0, "no functions, so no `source` needed");
        testing.expectTexts(pyNames(S.constants), &.{ "LIMIT", "RATIO", "SLOW" });
        const no_mode = Scan(&.{.{ .ns = scan_sample, .only = &.{ "Mode", "LIMIT" } }}, &.{});
        testing.expectTexts(pyNames(no_mode.constants), &.{ "LIMIT", "FAST", "SLOW" }); // `Mode`: its fields
        testing.expectTexts(pyNames(S.classes), &.{ "ScanBase", "ScanDerived" });
        const skipped = Scan(&.{.{ .ns = scan_sample, .source = @embedFile("scan.zig") }}, &.{"scan_add"});
        testing.expect(skipped.functions.len == 0, "`scan_add` taken by `Module.methods`");
    }
}

/// Link `i` of a chain of classes, each the base of the next (`scan_chain`).
fn ChainLink(comptime i: usize) type {
    return struct {
        pub const name = std.fmt.comptimePrint("pkg.Link{d}", .{i});
        pub const basetype = true;
        pub const base = if (i == 0) void else ChainType(i - 1);
    };
}

/// The `setu.Class` of `ChainLink(i)`, with a source that declares it.
fn ChainType(comptime i: usize) type {
    const L = ChainLink(i);
    return class_zig.Class(L, "const " ++ class_zig.shortName(@typeName(L)) ++ " = struct {};");
}

/// 40 classes, each derived from the one after it: as many as Liburing has (36), listed derived first.
const scan_chain = struct {
    pub const L39 = ChainType(39);
    pub const L38 = ChainType(38);
    pub const L37 = ChainType(37);
    pub const L36 = ChainType(36);
    pub const L35 = ChainType(35);
    pub const L34 = ChainType(34);
    pub const L33 = ChainType(33);
    pub const L32 = ChainType(32);
    pub const L31 = ChainType(31);
    pub const L30 = ChainType(30);
    pub const L29 = ChainType(29);
    pub const L28 = ChainType(28);
    pub const L27 = ChainType(27);
    pub const L26 = ChainType(26);
    pub const L25 = ChainType(25);
    pub const L24 = ChainType(24);
    pub const L23 = ChainType(23);
    pub const L22 = ChainType(22);
    pub const L21 = ChainType(21);
    pub const L20 = ChainType(20);
    pub const L19 = ChainType(19);
    pub const L18 = ChainType(18);
    pub const L17 = ChainType(17);
    pub const L16 = ChainType(16);
    pub const L15 = ChainType(15);
    pub const L14 = ChainType(14);
    pub const L13 = ChainType(13);
    pub const L12 = ChainType(12);
    pub const L11 = ChainType(11);
    pub const L10 = ChainType(10);
    pub const L9 = ChainType(9);
    pub const L8 = ChainType(8);
    pub const L7 = ChainType(7);
    pub const L6 = ChainType(6);
    pub const L5 = ChainType(5);
    pub const L4 = ChainType(4);
    pub const L3 = ChainType(3);
    pub const L2 = ChainType(2);
    pub const L1 = ChainType(1);
    pub const L0 = ChainType(0);
};

test "Scan: bases first for 40 classes, with the default branch quota here" {
    comptime {
        const S = Scan(&.{.{ .ns = scan_chain }}, &.{});
        testing.expect(S.classes.len == 40, "40 classes");
        for (S.classes, 0..) |it, i| testing.expectText(it.decl, std.fmt.comptimePrint("L{d}", .{i}));
    }
}

// Compile errors (Zig can not test a `@compileError`; each was checked by hand): a function in an
// entry without `source`; `only` with `exclude`; an `only` / `exclude` name the entry does not declare;
// a Python name in two entries (or twice in one); one `setu.Class` / `setu.Exception` type under two
// names; a base class in no entry.
