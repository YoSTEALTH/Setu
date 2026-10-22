//! Reading the Zig source at comptime (`@embedFile` of the binding's file): parameter names
//! and types as written, `///` docs, and argument-struct defaults as Python source text.
//! Re-exported by `py.zig` (`fnSource`, `docAbove`, `FnSource`).

const std = @import("std");

/// The field list of an argument struct whose type is written `type_text` in `source`:
/// `struct { ... }` itself, or the name of a `const Name = struct {` in `source`.
pub fn structBody(
    comptime source: []const u8,
    comptime type_text: []const u8,
    comptime fname: []const u8,
) []const []const u8 {
    if (std.mem.startsWith(u8, type_text, "struct")) {
        const brace = std.mem.indexOfScalar(u8, type_text, '{') orelse @compileError("bad struct in " ++ fname);
        return listParts(type_text, brace + 1);
    }
    const head = "const " ++ type_text ++ " = struct {";
    const at = std.mem.indexOf(u8, source, head) orelse
        @compileError(fname ++ ": the argument struct `" ++ type_text ++ "` must be declared in the same file");
    return listParts(source, at + head.len);
}

/// `{ name, default }` (the source text after `=`) for each field in `fields` that has one.
pub fn fieldDefaults(comptime fields: []const []const u8) []const struct { []const u8, []const u8 } {
    var out: []const struct { []const u8, []const u8 } = &.{};
    for (fields) |part| {
        if (std.mem.startsWith(u8, part, "pub ") or std.mem.startsWith(u8, part, "const ")) continue;
        const colon = std.mem.indexOfScalar(u8, part, ':') orelse continue;
        const eq = std.mem.indexOfScalarPos(u8, part, colon, '=') orelse continue;
        out = out ++ .{.{ unquoteName(std.mem.trim(u8, part[0..colon], " \t\r\n")), part[eq + 1 ..] }};
    }
    return out;
}

/// `name` without `@"..."` quoting.
pub fn unquoteName(comptime name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "@\"")) name[2 .. name.len - 1] else name;
}

/// The Zig default `expr` as Python source (see `Param`); `what` names it in errors.
pub fn pyDefault(comptime expr: []const u8, comptime what: []const u8) []const u8 {
    const e = std.mem.trim(u8, expr, " \t\r\n");
    if (std.mem.eql(u8, e, "null")) return "None";
    if (std.mem.eql(u8, e, "true")) return "True";
    if (std.mem.eql(u8, e, "false")) return "False";
    if (e.len >= 2 and e[0] == '"' and e[e.len - 1] == '"' and
        std.mem.indexOfAny(u8, e[1 .. e.len - 1], "\\'\"") == null) return "'" ++ e[1 .. e.len - 1] ++ "'";
    const digits = if (e.len > 0 and e[0] == '-') e[1..] else e;
    const word = for (e) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.') break false;
    } else e.len > 0;
    if (digits.len > 0 and std.ascii.isDigit(digits[0])) {
        if (std.mem.indexOfScalar(u8, digits, '-') == null and (word or e[0] == '-')) return e;
    } else if (word) {
        const dot = std.mem.lastIndexOfScalar(u8, e, '.');
        return if (dot) |d| e[d + 1 ..] else e;
    }
    @compileError(what ++ ": can't show the default `" ++ e ++ "` in Python; use a literal, `null` or a constant");
}

/// The top-level comma-separated parts (trimmed, `//` comments dropped) of the bracketed list
/// whose items start at `text[start]`, up to its closing bracket. Strings and character
/// literals are skipped, so their `,` / brackets don't count.
pub fn listParts(comptime text: []const u8, comptime start: usize) []const []const u8 {
    @setEvalBranchQuota(10_000_000);
    var parts: []const []const u8 = &.{};
    var begin = start;
    var cur: []const u8 = "";
    var depth: usize = 0;
    var j = start;
    while (j < text.len) : (j += 1) {
        const ch = text[j];
        if (std.mem.startsWith(u8, text[j..], "//")) {
            cur = cur ++ text[begin..j] ++ " ";
            j = std.mem.indexOfScalarPos(u8, text, j, '\n') orelse text.len;
            begin = j;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            var k = j + 1;
            while (k < text.len and text[k] != ch) : (k += 1) {
                if (text[k] == '\\') k += 1;
            }
            j = k;
            continue;
        }
        if (ch == '(' or ch == '[' or ch == '{') depth += 1;
        const close = ch == ')' or ch == ']' or ch == '}';
        if ((close or ch == ',') and depth == 0) {
            const part = std.mem.trim(u8, cur ++ text[begin..j], " \t\r\n");
            if (part.len > 0) parts = parts ++ .{part};
            if (close) return parts;
            cur = "";
            begin = j + 1;
        } else if (close) depth -= 1;
    }
    @compileError("unterminated list");
}

pub const FnSource = struct {
    doc: []const u8,
    /// The parameter names.
    params: []const [:0]const u8,
    /// Their types, as written (`?u32`, `struct { ... }`).
    types: []const []const u8,
};

/// `///` lines above `pub fn name(` and its parameter names and types, from `source`.
/// `//` comments in the parameter list (`flags: ?u8, // note`) are skipped.
pub fn fnSource(comptime source: []const u8, comptime name: []const u8) FnSource {
    @setEvalBranchQuota(1_000_000);
    const needle = "pub fn " ++ name ++ "(";
    const at = std.mem.indexOf(u8, source, needle) orelse @compileError("no `" ++ needle ++ "` in source");
    var names: []const [:0]const u8 = &.{};
    var types: []const []const u8 = &.{};
    for (listParts(source, at + needle.len)) |part| {
        const colon = std.mem.indexOfScalar(u8, part, ':') orelse @compileError("bad parameter in " ++ name);
        const pname = unquoteName(std.mem.trim(u8, part[0..colon], " \t\r\n"));
        names = names ++ .{(pname ++ "\x00")[0..pname.len :0]};
        types = types ++ .{std.mem.trim(u8, part[colon + 1 ..], " \t\r\n")};
    }
    return .{ .doc = docAbove(source, at), .params = names, .types = types };
}

/// The `///` doc comment (contiguous lines, `/// ` stripped) right above the line
/// containing `source[at]`.
pub fn docAbove(comptime source: []const u8, comptime at: usize) []const u8 {
    @setEvalBranchQuota(1_000_000);
    var start = std.mem.lastIndexOfScalar(u8, source[0..at], '\n') orelse 0;
    var doc: []const u8 = "";
    while (start > 0) {
        const prev = std.mem.lastIndexOfScalar(u8, source[0..start], '\n') orelse 0;
        const line: []const u8 = std.mem.trim(u8, source[if (prev == 0) 0 else prev + 1..start], " \t\r");
        if (!std.mem.startsWith(u8, line, "///")) break;
        var text: []const u8 = line[3..];
        if (text.len > 0 and text[0] == ' ') text = text[1..];
        doc = text ++ (if (doc.len == 0) "" else "\n" ++ doc);
        start = prev;
    }
    return doc;
}

const testing = @import("testing.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

test "listParts: top-level parts, with strings, characters and comments skipped" {
    comptime testing.expectTexts(
        listParts("(a, f(b, c), \"x,)\", ',', // d, e\n [g, h]) tail", 1),
        &.{ "a", "f(b, c)", "\"x,)\"", "','", "[g, h]" },
    );
}

test "fnSource: doc, parameter names (unquoted) and types, comments skipped" {
    const source =
        \\const before = 1;
        \\/// Adds.
        \\///
        \\/// Example
        \\///     >>> add(1)
        \\///     1
        \\pub fn add(a: i64, b: ?i64, // a note, with a comma
        \\    @"type": struct { x: u8 = 1, y: bool }) i64 {}
    ;
    comptime {
        const f = fnSource(source, "add");
        testing.expectText(f.doc, "Adds.\n\nExample\n    >>> add(1)\n    1");
        testing.expectTexts(&.{ f.params[0], f.params[1], f.params[2] }, &.{ "a", "b", "type" });
        testing.expect(f.params.len == 3, "3 parameters");
        testing.expectTexts(f.types, &.{ "i64", "?i64", "struct { x: u8 = 1, y: bool }" });
        testing.expectText(docAbove(source, 0), "");
    }
}

test "structBody / fieldDefaults: an argument struct's fields and their defaults" {
    const source =
        \\const Opts = struct {
        \\    mode: u8 = 2,
        \\    @"async": bool = false, // quoted
        \\    path: ?[]const u8,
        \\    pub const K = 1;
        \\};
    ;
    comptime {
        testing.expectTexts(structBody("", "struct { x: u8 = 1, y: bool }", "f"), &.{ "x: u8 = 1", "y: bool" });
        const defaults = fieldDefaults(structBody(source, "Opts", "f"));
        testing.expect(defaults.len == 2, "2 defaults");
        testing.expectTexts(&.{ defaults[0][0], defaults[0][1] }, &.{ "mode", " 2" });
        testing.expectTexts(&.{ defaults[1][0], defaults[1][1] }, &.{ "async", " false" });
    }
}

test "pyDefault: a Zig default as Python source" {
    comptime {
        testing.expectText(pyDefault("null", "f"), "None");
        testing.expectText(pyDefault(" true", "f"), "True");
        testing.expectText(pyDefault("false ", "f"), "False");
        testing.expectText(pyDefault("\"ab\"", "f"), "'ab'");
        testing.expectText(pyDefault("-3", "f"), "-3");
        testing.expectText(pyDefault("0x10", "f"), "0x10");
        testing.expectText(pyDefault("1.5", "f"), "1.5");
        testing.expectText(pyDefault("MAX", "f"), "MAX");
        testing.expectText(pyDefault("linux.AT.FDCWD", "f"), "FDCWD");
        testing.expectText(pyDefault(".fast", "f"), "fast");
        testing.expectText(unquoteName("@\"type\""), "type");
        testing.expectText(unquoteName("plain"), "plain");
    }
}
