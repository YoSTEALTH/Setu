//! The docs site's logic, compiled to WebAssembly (`zig build docs-web` -> `docs.wasm` in the site): API
//! search, the Run transcript, the docs server check, and the Coverage page's source viewer (a file's source as
//! HTML lines, Zig highlighted with the code blocks' classes, each line marked covered or missed; from
//! Liburing's `source_web.zig`). `app.js` (written by `tools/setu_docs.py`) is only
//! the binding: it copies strings into this module's memory (`alloc`), calls an export, reads `outPtr()` /
//! `outLen()`, and does what Wasm can not (DOM, `fetch`). Every HTML string this module returns is escaped
//! here. Setu builds it for a project through `addSetuDocsSteps` (Setu's `build.zig`); nothing is copied.

const std = @import("std");
const builtin = @import("builtin");

const gpa = if (builtin.target.cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.page_allocator;

/// One search entry of `search.json` (`tools/setu_docs.py` writes it).
pub const Entry = struct {
    /// Name: `read`, `File.read`, `O_CREAT`.
    n: []const u8,
    /// Link: `io.html#read`.
    h: []const u8,
    /// Page title: `File descriptors`.
    p: []const u8,
    /// First line of the docstring (or a constant's value).
    s: []const u8,
};

/// One `>>>` statement of a Run result (`tools/setu_docs.py run --json <name>`).
pub const Step = struct {
    source: []const u8 = "",
    expected: []const u8 = "",
    got: []const u8 = "",
    /// `ok`, `fail`, `loose` (output not compared) or `skip`.
    status: []const u8 = "",
};

/// A Run result: a docstring example has `steps`, a script `output` and `returncode`, a refused
/// request only `error`.
pub const RunResult = struct {
    ok: bool = false,
    @"error": ?[]const u8 = null,
    steps: ?[]const Step = null,
    output: ?[]const u8 = null,
    returncode: i64 = 0,
};

/// What `renderRun` found (its return value, and `runStatus`'s argument).
pub const RunKind = enum(u32) { ok = 0, differs = 1, failed = 2 };

/// A ranked search hit: an index into the loaded entries.
pub const Hit = struct { rank: u8, index: u32 };

/// Most hits `search` shows.
pub const max_hits = 30;

/// How a line ran: not code (`none`), at least once (`hit`), never (`miss`).
pub const Mark = enum(u8) { none, hit, miss };

/// Zig's keywords (`.kw`).
const keywords = [_][]const u8{
    "addrspace",   "align",    "allowzero", "and",         "anyframe",    "anytype",  "asm",
    "break",       "callconv", "catch",     "comptime",    "const",       "continue", "defer",
    "else",        "enum",     "errdefer",  "error",       "export",      "extern",   "fn",
    "for",         "if",       "inline",    "linksection", "noalias",     "noinline", "nosuspend",
    "opaque",      "or",       "orelse",    "packed",      "pub",         "resume",   "return",
    "struct",      "suspend",  "switch",    "test",        "threadlocal", "try",      "union",
    "unreachable", "var",      "volatile",  "while",
};

/// Zig's constant values (`.con`).
const constants = [_][]const u8{ "true", "false", "null", "undefined" };

/// Zig's primitive type names (`.ty`), besides `i<N>` / `u<N>` and capitalized names.
const types = [_][]const u8{
    "usize",     "isize",        "bool",           "void",        "type",         "noreturn", "anyerror",
    "anyopaque", "comptime_int", "comptime_float", "f16",         "f32",          "f64",      "f80",
    "f128",      "c_char",       "c_uchar",        "c_short",     "c_ushort",     "c_int",    "c_uint",
    "c_long",    "c_ulong",      "c_longlong",     "c_ulonglong", "c_longdouble",
};

/// The line above a source changed since the coverage run (`render`'s `stale`).
pub const stale_notice = "<span class=\"stale\">Changed since `zig build coverage`: the marks can be off by the " ++
    "lines moved.\n</span>";

var out: std.ArrayList(u8) = .empty;
var index_arena = std.heap.ArenaAllocator.init(gpa);
var entries: []const Entry = &.{};
var hits_buf: [max_hits]u32 = undefined;
var hits: []const u32 = &.{};
var selected: i32 = -1;
var last_error: std.ArrayList(u8) = .empty;

// --- pure helpers (unit tested) -------------------------------------------------------------------

/// Append `text` to `list`, HTML-escaped.
///
/// Example
///     >>> var list: std.ArrayList(u8) = .empty;
///     >>> try escape(&list, std.testing.allocator, "<a href=\"x\">&</a>");
///     >>> list.items
///     "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;"
pub fn escape(list: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '<' => try list.appendSlice(a, "&lt;"),
        '>' => try list.appendSlice(a, "&gt;"),
        '&' => try list.appendSlice(a, "&amp;"),
        '"' => try list.appendSlice(a, "&quot;"),
        '\'' => try list.appendSlice(a, "&#39;"),
        else => try list.append(a, ch),
    };
}

/// How well `e` matches `term` (lower is better), or null when it does not.
///
/// Example
///     >>> rank(.{ .n = "read", .h = "", .p = "", .s = "Read up to..." }, "read")
///     0
///     >>> rank(.{ .n = "readall", .h = "", .p = "", .s = "" }, "READ")
///     1
///     >>> rank(.{ .n = "prep_read", .h = "", .p = "", .s = "" }, "read")
///     2
///     >>> rank(.{ .n = "close", .h = "", .p = "", .s = "Read nothing" }, "read")
///     3
///     >>> rank(.{ .n = "close", .h = "", .p = "", .s = "" }, "read")
///     null
///
/// Note
///     - Case is ignored: exact name 0, name prefix 1, inside the name 2, inside the summary 3.
pub fn rank(e: Entry, term: []const u8) ?u8 {
    if (std.ascii.eqlIgnoreCase(e.n, term)) return 0;
    if (std.ascii.startsWithIgnoreCase(e.n, term)) return 1;
    if (std.ascii.findIgnoreCase(e.n, term) != null) return 2;
    if (std.ascii.findIgnoreCase(e.s, term) != null) return 3;
    return null;
}

/// The best `buf.len` matches of `term` in `list`, by rank, then shorter name, then list order.
///
/// Example
///     >>> var buf: [30]u32 = undefined;
///     >>> try best(gpa, &.{ entry("prep_read", ""), entry("read", ""), entry("close", "") }, "read", &buf)
///     { 1, 0 }
pub fn best(a: std.mem.Allocator, list: []const Entry, term: []const u8, buf: []u32) ![]const u32 {
    const trimmed = std.mem.trim(u8, term, " \t\r\n");
    if (trimmed.len == 0) return buf[0..0];
    var found: std.ArrayList(Hit) = .empty;
    defer found.deinit(a);
    for (list, 0..) |e, i| {
        // cast: the index has at most a few thousand entries
        if (rank(e, trimmed)) |r| try found.append(a, .{ .rank = r, .index = @intCast(i) });
    }
    std.mem.sort(Hit, found.items, list, struct {
        /// Best rank first; then the shorter name; then the index order.
        fn lessThan(l: []const Entry, x: Hit, y: Hit) bool {
            if (x.rank != y.rank) return x.rank < y.rank;
            const xl, const yl = .{ l[x.index].n.len, l[y.index].n.len };
            return if (xl != yl) xl < yl else x.index < y.index;
        }
    }.lessThan);
    const n = @min(buf.len, found.items.len);
    for (found.items[0..n], buf[0..n]) |h, *slot| slot.* = h.index;
    return buf[0..n];
}

/// Append the search results as HTML links (`<a href>name<small>page — summary</small></a>`).
pub fn hitsHtml(list: *std.ArrayList(u8), a: std.mem.Allocator, all: []const Entry, found: []const u32) !void {
    for (found) |i| {
        const e = all[i];
        try list.appendSlice(a, "<a href=\"");
        try escape(list, a, e.h);
        try list.appendSlice(a, "\">");
        try escape(list, a, e.n);
        try list.appendSlice(a, "<small>");
        try escape(list, a, e.p);
        if (e.s.len > 0) {
            try list.appendSlice(a, " — ");
            try escape(list, a, e.s);
        }
        try list.appendSlice(a, "</small></a>");
    }
}

/// Appends `text` wrapped in `<span class="class">`, both HTML-escaped.
fn span(list: *std.ArrayList(u8), a: std.mem.Allocator, class: []const u8, text: []const u8) !void {
    try list.appendSlice(a, "<span class=\"");
    try escape(list, a, class);
    try list.appendSlice(a, "\">");
    try escape(list, a, text);
    try list.appendSlice(a, "</span>");
}

/// Append a Run result as the transcript HTML shown under the button.
///
/// Example
///     >>> const step: Step = .{ .source = "1 + 1", .got = "2", .status = "ok" };
///     >>> try transcript(&list, gpa, .{ .ok = true, .steps = &.{step} });
///     >>> list.items
///     "<span class=\"st-ok\">&gt;&gt;&gt; 1 + 1\n</span><span class=\"out\">2\n</span>"
///
/// Note
///     - A failed step adds `# docs say: <expected>`; a loose one `# output differs per run; not compared`.
///     - A script shows its output, then `# exit code N` (red when not 0).
pub fn transcript(list: *std.ArrayList(u8), a: std.mem.Allocator, r: RunResult) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    if (r.steps) |steps| {
        for (steps) |s| {
            const class = try a.print("st-{s}", .{s.status});
            defer a.free(class);
            var it = std.mem.splitScalar(u8, s.source, '\n');
            var first = true;
            while (it.next()) |src| : (first = false) {
                line.clearRetainingCapacity();
                try line.print(a, "{s}{s}\n", .{ if (first) ">>> " else "... ", src });
                try span(list, a, class, line.items);
            }
            const fail = std.mem.eql(u8, s.status, "fail");
            if (s.got.len > 0) {
                line.clearRetainingCapacity();
                try line.print(a, "{s}\n", .{s.got});
                try span(list, a, if (fail) "st-fail" else "out", line.items);
            }
            if (fail) {
                line.clearRetainingCapacity();
                try line.print(a, "# docs say: {s}\n", .{if (s.expected.len > 0) s.expected else "(nothing)"});
                try span(list, a, "exp", line.items);
            } else if (std.mem.eql(u8, s.status, "loose")) {
                try span(list, a, "st-loose", "# output differs per run; not compared\n");
            }
        }
        return;
    }
    const output = r.output orelse "";
    try escape(list, a, if (output.len > 0) output else "(no output)\n");
    line.clearRetainingCapacity();
    try line.print(a, "\n# exit code {d}\n", .{r.returncode});
    try span(list, a, if (r.returncode != 0) "st-fail" else "out", line.items);
}

/// What a Run result means for the status line.
pub fn kindOf(r: RunResult) RunKind {
    if (r.@"error" != null) return .failed;
    return if (r.ok) .ok else .differs;
}

/// Append the status line: `ok · 0.05 s`, `differs from the docs · 1.20 s`, or the error.
///
/// Example
///     >>> try status(&list, gpa, .ok, 1234, "")
///     >>> list.items
///     "ok · 1.23 s"
pub fn status(list: *std.ArrayList(u8), a: std.mem.Allocator, kind: RunKind, millis: u32, err: []const u8) !void {
    switch (kind) {
        .failed => try list.appendSlice(a, err),
        .ok, .differs => try list.print(a, "{s} · {d}.{d:0>2} s", .{
            if (kind == .ok) "ok" else "differs from the docs",
            millis / 1000,
            millis % 1000 / 10,
        }),
    }
}

/// Set `mark` on the lines of `ranges` (`"3-5, 9"`, 1-based, as Setu's `line_ranges` writes them) in `marks`
/// (one per line). Lines past the end and parts that are not numbers are skipped.
///
/// Example
///     >>> var marks: [6]Mark = @splat(.none);
///     >>> markLines(&marks, "2-3, 5", .miss);
///     >>> marks
///     { .none, .miss, .miss, .none, .miss, .none }
pub fn markLines(marks: []Mark, ranges: []const u8, mark: Mark) void {
    var parts = std.mem.splitScalar(u8, ranges, ',');
    while (parts.next()) |part| {
        const text = std.mem.trim(u8, part, " ");
        const dash = std.mem.findScalar(u8, text, '-');
        const first = std.fmt.parseInt(usize, text[0 .. dash orelse text.len], 10) catch continue;
        const last = if (dash) |d| std.fmt.parseInt(usize, text[d + 1 ..], 10) catch continue else first;
        if (first == 0) continue;
        var n = first;
        while (n <= @min(last, marks.len)) : (n += 1) marks[n - 1] = mark;
    }
}

/// Whether `word` is one of `list`.
fn among(list: []const []const u8, word: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, word)) return true;
    }
    return false;
}

/// Whether `ch` can start a Zig name.
fn nameStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

/// Whether `ch` can continue a Zig name.
fn nameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// The end of the name starting at `i`.
fn nameEnd(line: []const u8, i: usize) usize {
    var j = i;
    while (j < line.len and nameChar(line[j])) j += 1;
    return j;
}

/// The end of the `"..."` or `'...'` literal starting at `i` (backslash escapes skipped), or null when the line
/// does not close it.
fn quotedEnd(line: []const u8, i: usize) ?usize {
    var j = i + 1;
    while (j < line.len) : (j += 1) {
        if (line[j] == '\\') {
            j += 1;
        } else if (line[j] == line[i]) {
            return j + 1;
        }
    }
    return null;
}

/// The end of the run of characters from `i` that pass `ok` or are `_`.
fn digitsEnd(line: []const u8, i: usize, ok: *const fn (u8) bool) usize {
    var j = i;
    while (j < line.len and (ok(line[j]) or line[j] == '_')) j += 1;
    return j;
}

/// Whether `ch` is an octal digit.
fn isOctal(ch: u8) bool {
    return ch >= '0' and ch <= '7';
}

/// Whether `ch` is a binary digit.
fn isBinary(ch: u8) bool {
    return ch == '0' or ch == '1';
}

/// The end of the number starting at the digit `i` (`0x1f`, `0o17`, `0b101`, `1_000`, `2.5e-3`).
fn numberEnd(line: []const u8, i: usize) usize {
    if (line[i] == '0' and i + 2 < line.len) {
        const ok: ?*const fn (u8) bool = switch (line[i + 1]) {
            'x' => &std.ascii.isHex,
            'o' => &isOctal,
            'b' => &isBinary,
            else => null,
        };
        if (ok) |digit| {
            if (digit(line[i + 2])) return digitsEnd(line, i + 2, digit);
        }
    }
    var j = digitsEnd(line, i, &std.ascii.isDigit);
    if (j + 1 < line.len and line[j] == '.' and std.ascii.isDigit(line[j + 1])) {
        j = digitsEnd(line, j + 1, &std.ascii.isDigit);
    }
    if (j < line.len and (line[j] == 'e' or line[j] == 'E')) {
        var k = j + 1;
        if (k < line.len and (line[k] == '+' or line[k] == '-')) k += 1;
        if (k < line.len and std.ascii.isDigit(line[k])) {
            j = k;
            while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
        }
    }
    return j;
}

/// Whether every character of `text` is a digit.
fn allDigits(text: []const u8) bool {
    for (text) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

/// The class of the name `line[start..end]`: keyword, constant, `self` / `_`, type, function (after `fn` or
/// before `(`), field (after `.`), or "" (plain).
fn nameClass(line: []const u8, start: usize, end: usize) []const u8 {
    const name = line[start..end];
    if (among(&keywords, name)) return "kw";
    if (among(&constants, name)) return "con";
    if (std.mem.eql(u8, name, "self") or std.mem.eql(u8, name, "_")) return "slf";
    const int = (name[0] == 'i' or name[0] == 'u') and name.len > 1 and allDigits(name[1..]);
    if (int or among(&types, name) or std.ascii.isUpper(name[0])) return "ty";
    const before = std.mem.trimEnd(u8, line[0..start], " \t");
    const after = std.mem.trimStart(u8, line[end..], " \t");
    if (std.mem.endsWith(u8, before, "fn") or std.mem.startsWith(u8, after, "(")) return "fn";
    if (start > 0 and line[start - 1] == '.') return "attr";
    return "";
}

/// Append a line of Zig as HTML, each token in a `<span class>` of Setu's code blocks: `com` (comment), `str`
/// (string, character, `\\` line), `bi` (`@builtin`), `num`, and a name's `nameClass`. A line at a time: no
/// Zig token spans lines.
///
/// Example
///     >>> try highlight(&list, gpa, "const x = @max(a, 1); // <");
///     >>> list.items
///     "<span class=\"kw\">const</span> x = <span class=\"bi\">@max</span>(a, <span class=\"num\">1</span>); " ++
///         "<span class=\"com\">// &lt;</span>"
pub fn highlight(list: *std.ArrayList(u8), a: std.mem.Allocator, line: []const u8) !void {
    var plain: usize = 0; // start of the text not written yet
    var i: usize = 0;
    while (i < line.len) {
        const start = i;
        const ch = line[i];
        const next = if (i + 1 < line.len) line[i + 1] else 0;
        var class: []const u8 = "";
        if ((ch == '/' and next == '/') or (ch == '\\' and next == '\\')) {
            i = line.len;
            class = if (ch == '/') "com" else "str";
        } else if (ch == '"' or ch == '\'') {
            i = quotedEnd(line, i) orelse i + 1;
            if (i > start + 1) class = "str";
        } else if (ch == '@' and nameStart(next)) {
            i = nameEnd(line, i + 1);
            class = "bi";
        } else if (std.ascii.isDigit(ch)) {
            i = numberEnd(line, i);
            if (i < line.len and nameChar(line[i])) i = nameEnd(line, i) else class = "num";
        } else if (nameStart(ch)) {
            i = nameEnd(line, i);
            class = nameClass(line, start, i);
        } else {
            i += 1;
        }
        if (class.len == 0) continue;
        try escape(list, a, line[plain..start]);
        try list.print(a, "<span class=\"{s}\">", .{class});
        try escape(list, a, line[start..i]);
        try list.appendSlice(a, "</span>");
        plain = i;
    }
    try escape(list, a, line[plain..]);
}

/// Append `source` as one `<span data-n="N">` per line (`class="hit"` / `"miss"` from `hit` / `miss`, ranges as
/// in `markLines`), each highlighted and ending in a newline. Returns the first missed line, or 0.
///
/// Example
///     >>> _ = try sourceHtml(&list, gpa, "a\nb\n", "1", "2")
///     2
///     >>> list.items
///     "<span class=\"hit\" data-n=\"1\">a\n</span><span class=\"miss\" data-n=\"2\">b\n</span>"
pub fn sourceHtml(
    list: *std.ArrayList(u8),
    a: std.mem.Allocator,
    source: []const u8,
    hit: []const u8,
    miss: []const u8,
) !usize {
    if (source.len == 0) return 0;
    const text = if (std.mem.endsWith(u8, source, "\n")) source[0 .. source.len - 1] else source;
    const marks = try a.alloc(Mark, std.mem.countScalar(u8, text, '\n') + 1);
    defer a.free(marks);
    @memset(marks, .none);
    markLines(marks, hit, .hit);
    markLines(marks, miss, .miss);
    var first: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 1;
    while (lines.next()) |line| : (n += 1) {
        const mark = marks[n - 1];
        if (mark == .miss and first == 0) first = n;
        try list.appendSlice(a, "<span");
        if (mark != .none) try list.print(a, " class=\"{t}\"", .{mark});
        try list.print(a, " data-n=\"{d}\">", .{n});
        try highlight(list, a, std.mem.trimEnd(u8, line, "\r"));
        try list.appendSlice(a, "\n</span>");
    }
    return first;
}

/// One line's cost for the Profile page (`renderProfile`): the line, the instructions per call as written, and
/// as a number.
pub const Cost = struct { n: usize, text: []const u8, value: f64 };

/// The `line:cost` pairs of `costs` (`"88:9.0,106:17.0"`, as `tools/setu_docs.py` writes them) in `buf` (room
/// for one more than the commas); parts that are not such a pair are skipped.
///
/// Example
///     >>> parseCosts("88:9.0, x, 106:17", &buf)
///     { .{ .n = 88, .text = "9.0", .value = 9 }, .{ .n = 106, .text = "17", .value = 17 } }
pub fn parseCosts(costs: []const u8, buf: []Cost) []Cost {
    var k: usize = 0;
    var parts = std.mem.splitScalar(u8, costs, ',');
    while (parts.next()) |part| {
        const text = std.mem.trim(u8, part, " ");
        const colon = std.mem.findScalar(u8, text, ':') orelse continue;
        const n = std.fmt.parseInt(usize, text[0..colon], 10) catch continue;
        const value = std.fmt.parseFloat(f64, text[colon + 1 ..]) catch continue;
        buf[k] = .{ .n = n, .text = text[colon + 1 ..], .value = value };
        k += 1;
    }
    return buf[0..k];
}

/// The cost of line `n` in `costs`, or null.
fn costOf(costs: []const Cost, n: usize) ?Cost {
    for (costs) |c| {
        if (c.n == n) return c;
    }
    return null;
}

/// Append one line of `profileHtml`: `<span data-n="N">` with the cost in a `<b class="pc">` (empty when none) and
/// the text, Zig highlighted (`code`) or escaped; a costly line is shaded relative to `top`.
fn costLine(
    list: *std.ArrayList(u8),
    a: std.mem.Allocator,
    n: usize,
    cost: ?Cost,
    top: f64,
    text: []const u8,
    code: bool,
) !void {
    try list.print(a, "<span data-n=\"{d}\"", .{n});
    if (cost) |c| {
        const shade = 10 + 55 * (if (top > 0) @min(1, @max(0, c.value / top)) else 1);
        try list.print(a, " class=\"hot\" style=\"background:color-mix(in srgb, var(--bad) {d:.0}%, transparent)\"", .{
            shade,
        });
    }
    try list.appendSlice(a, "><b class=\"pc\">");
    if (cost) |c| try escape(list, a, c.text);
    try list.appendSlice(a, "</b>");
    if (code) try highlight(list, a, text) else try escape(list, a, text);
    try list.appendSlice(a, "\n</span>");
}

/// The line 0 of a profile: code the compiler added, with no source line.
pub const no_line = "(code the compiler added: no source line)";

/// Append `source` for the Profile page: one line per `<span data-n="N">` (Zig highlighted), each costly line of
/// `costs` (`parseCosts`) with its instructions per call and shaded by them; a line 0 cost first (`no_line`). With
/// no `source` (not found), only the costly lines. Returns the costliest line (where the view scrolls to), or 0.
///
/// Example
///     >>> _ = try profileHtml(&list, gpa, "a\nb\n", "2:4.0")
///     2
///     >>> list.items
///     "<span data-n=\"1\"><b class=\"pc\"></b>a\n</span><span data-n=\"2\" class=\"hot\" style=...>" ++
///         "<b class=\"pc\">4.0</b>b\n</span>"
pub fn profileHtml(list: *std.ArrayList(u8), a: std.mem.Allocator, source: []const u8, costs: []const u8) !usize {
    const buf = try a.alloc(Cost, std.mem.countScalar(u8, costs, ',') + 1);
    defer a.free(buf);
    const found = parseCosts(costs, buf);
    var top: f64 = 0;
    var top_line: usize = 0;
    for (found) |c| {
        if (c.value > top) top = c.value;
        if (c.n > 0 and (top_line == 0 or c.value > costOf(found, top_line).?.value)) top_line = c.n;
    }
    if (costOf(found, 0)) |c| try costLine(list, a, 0, c, top, no_line, false);
    if (source.len == 0) {
        for (found) |c| {
            if (c.n > 0) try costLine(list, a, c.n, c, top, "", false);
        }
        return top_line;
    }
    const text = if (std.mem.endsWith(u8, source, "\n")) source[0 .. source.len - 1] else source;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 1;
    while (lines.next()) |line| : (n += 1) {
        try costLine(list, a, n, costOf(found, n), top, std.mem.trimEnd(u8, line, "\r"), true);
    }
    return top_line;
}

// --- exports: the binding `app.js` calls ----------------------------------------------------------

/// The `len` bytes `app.js` wrote at `ptr` in Wasm memory, as a slice.
fn input(ptr: [*]const u8, len: usize) []const u8 {
    return ptr[0..len];
}

/// Memory for an argument string `app.js` writes in (null when out of memory).
export fn alloc(len: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, len) catch return null;
    return buf.ptr;
}

/// Give back what `alloc` returned.
export fn free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

/// Start of the last result string (HTML or text).
export fn outPtr() [*]const u8 {
    return out.items.ptr;
}

/// Length of the last result string.
export fn outLen() usize {
    return out.items.len;
}

/// Load `search.json` (an array of `Entry`); false when it does not parse. The strings are copied: `app.js`
/// frees the input right after.
export fn loadIndex(ptr: [*]const u8, len: usize) bool {
    _ = index_arena.reset(.free_all);
    entries = std.json.parseFromSliceLeaky([]const Entry, index_arena.allocator(), input(ptr, len), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        entries = &.{};
        return false;
    };
    return true;
}

/// Search for the term; the hits' HTML goes to the output. Returns the number of hits.
export fn search(ptr: [*]const u8, len: usize) u32 {
    out.clearRetainingCapacity();
    selected = -1;
    hits = best(gpa, entries, input(ptr, len), &hits_buf) catch &.{};
    hitsHtml(&out, gpa, entries, hits) catch {
        // coverage-off: out of memory only
        out.clearRetainingCapacity();
        hits = &.{};
        // coverage-on
    };
    // cast: at most `max_hits`
    return @intCast(hits.len);
}

/// Move the keyboard selection by `delta` (clamped to the hits); returns the selected hit, or -1.
export fn move(delta: i32) i32 {
    if (hits.len == 0) return -1;
    // cast: at most `max_hits`
    const last: i32 = @intCast(hits.len - 1);
    selected = std.math.clamp(selected + delta, 0, last);
    return selected;
}

/// The link of the selected hit (the first when none is selected) to the output; false with no hits.
export fn chosen() bool {
    out.clearRetainingCapacity();
    if (hits.len == 0) return false;
    // cast: `selected` is -1 or a valid hit index
    const i: usize = if (selected < 0) 0 else @intCast(selected);
    out.appendSlice(gpa, entries[hits[i]].h) catch return false;
    return true;
}

/// Check the `/api/ping` answer (`{"module": ..., "python": ...}`); true when it is the docs server, with
/// the badge text in the output.
export fn ping(ptr: [*]const u8, len: usize) bool {
    out.clearRetainingCapacity();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // The `/api/ping` answer's fields that matter (the rest is ignored).
    const Ping = struct { module: ?[]const u8 = null, python: []const u8 = "" };
    const p = std.json.parseFromSliceLeaky(Ping, arena.allocator(), input(ptr, len), .{
        .ignore_unknown_fields = true,
    }) catch return false;
    if (p.module == null) return false;
    out.print(gpa, "live · {s}", .{p.python}) catch return false;
    return true;
}

/// Render a `/api/run` answer: the transcript HTML goes to the output. Returns a `RunKind`; for
/// `.failed` the message is kept for `runStatus`.
export fn renderRun(ptr: [*]const u8, len: usize) u32 {
    out.clearRetainingCapacity();
    last_error.clearRetainingCapacity();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = std.json.parseFromSliceLeaky(RunResult, arena.allocator(), input(ptr, len), .{
        .ignore_unknown_fields = true,
    }) catch {
        last_error.appendSlice(gpa, "unreadable answer from the server") catch {};
        return @backingInt(RunKind.failed);
    };
    const kind = kindOf(r);
    if (kind == .failed) {
        last_error.appendSlice(gpa, r.@"error".?) catch {};
        return @backingInt(kind);
    }
    transcript(&out, gpa, r) catch {
        // coverage-off: out of memory only
        out.clearRetainingCapacity();
        last_error.appendSlice(gpa, "out of memory") catch {};
        return @backingInt(RunKind.failed);
        // coverage-on
    };
    return @backingInt(kind);
}

/// The status line for `kind` (from `renderRun`) after `millis` to the output.
export fn runStatus(kind: u32, millis: u32) void {
    out.clearRetainingCapacity();
    const k = std.enums.fromInt(RunKind, kind) orelse .failed;
    status(&out, gpa, k, millis, last_error.items) catch out.clearRetainingCapacity();
}

/// The Coverage page's viewer: a source file with its covered (`hit`) and missed line ranges as HTML to the
/// output, after `stale_notice` when the file is `stale` (changed since the coverage run). Returns the first
/// missed line (where the viewer scrolls to), or 0.
export fn renderSource(
    src_ptr: [*]const u8,
    src_len: usize,
    hit_ptr: [*]const u8,
    hit_len: usize,
    miss_ptr: [*]const u8,
    miss_len: usize,
    stale: bool,
) usize {
    out.clearRetainingCapacity();
    if (stale) out.appendSlice(gpa, stale_notice) catch return 0;
    return sourceHtml(&out, gpa, input(src_ptr, src_len), input(hit_ptr, hit_len), input(miss_ptr, miss_len)) catch {
        // coverage-off: out of memory only
        out.clearRetainingCapacity();
        return 0;
        // coverage-on
    };
}

/// The Profile page's view of one file: `source` (empty when not found) with its `costs` (`line:cost` pairs) as
/// HTML to the output. Returns the costliest line (where the view scrolls to), or 0.
export fn renderProfile(src_ptr: [*]const u8, src_len: usize, costs_ptr: [*]const u8, costs_len: usize) usize {
    out.clearRetainingCapacity();
    return profileHtml(&out, gpa, input(src_ptr, src_len), input(costs_ptr, costs_len)) catch {
        // coverage-off: out of memory only
        out.clearRetainingCapacity();
        return 0;
        // coverage-on
    };
}

// --- tests ----------------------------------------------------------------------------------------

const t = std.testing;

/// A test search entry named `n` with summary `s`.
fn entry(n: []const u8, s: []const u8) Entry {
    return .{ .n = n, .h = "p.html#x", .p = "Page", .s = s };
}

/// Whether `line` highlights to `expected`.
fn expectHighlight(expected: []const u8, line: []const u8) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(t.allocator);
    try highlight(&list, t.allocator, line);
    try t.expectEqualStrings(expected, list.items);
}

test escape {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(t.allocator);
    try escape(&list, t.allocator, "<a href=\"x\">&'</a>");
    try t.expectEqualStrings("&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;", list.items);
}

test rank {
    try t.expectEqual(@as(?u8, 0), rank(entry("read", ""), "READ"));
    try t.expectEqual(@as(?u8, 1), rank(entry("readall", ""), "read"));
    try t.expectEqual(@as(?u8, 2), rank(entry("prep_read", ""), "read"));
    try t.expectEqual(@as(?u8, 3), rank(entry("close", "Read nothing"), "read"));
    try t.expectEqual(@as(?u8, null), rank(entry("close", ""), "read"));
}

test best {
    const list = [_]Entry{
        entry("prep_read", ""),
        entry("readall", ""),
        entry("read", ""),
        entry("close", "can read"),
        entry("x", ""),
    };
    var buf: [3]u32 = undefined;
    try t.expectEqualSlices(u32, &.{ 2, 1, 0 }, try best(t.allocator, &list, " read ", &buf));
    try t.expectEqual(0, (try best(t.allocator, &list, "  ", &buf)).len);
    var one: [1]u32 = undefined;
    try t.expectEqualSlices(u32, &.{3}, try best(t.allocator, &list, "can", &one));
    // the same rank (a name prefix): the shorter name first, then the list order
    const ties = [_]Entry{ entry("read_all", ""), entry("readv", ""), entry("reads", "") };
    var all: [3]u32 = undefined;
    try t.expectEqualSlices(u32, &.{ 1, 2, 0 }, try best(t.allocator, &ties, "read", &all));
}

test hitsHtml {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(t.allocator);
    try hitsHtml(&list, t.allocator, &.{ entry("<b>", "a & b"), entry("y", "") }, &.{ 0, 1 });
    try t.expectEqualStrings(
        "<a href=\"p.html#x\">&lt;b&gt;<small>Page — a &amp; b</small></a>" ++
            "<a href=\"p.html#x\">y<small>Page</small></a>",
        list.items,
    );
}

test transcript {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(t.allocator);
    try transcript(&list, t.allocator, .{ .steps = &.{
        .{ .source = "async with x:\n    y", .status = "ok" },
        .{ .source = "f()", .expected = "1", .got = "<2>", .status = "fail" },
        .{ .source = "g()", .got = "3", .status = "loose" },
    } });
    try t.expectEqualStrings(
        "<span class=\"st-ok\">&gt;&gt;&gt; async with x:\n</span><span class=\"st-ok\">...     y\n</span>" ++
            "<span class=\"st-fail\">&gt;&gt;&gt; f()\n</span><span class=\"st-fail\">&lt;2&gt;\n</span>" ++
            "<span class=\"exp\"># docs say: 1\n</span>" ++
            "<span class=\"st-loose\">&gt;&gt;&gt; g()\n</span><span class=\"out\">3\n</span>" ++
            "<span class=\"st-loose\"># output differs per run; not compared\n</span>",
        list.items,
    );
    list.clearRetainingCapacity();
    try transcript(&list, t.allocator, .{ .output = "hi\n", .returncode = 1 });
    try t.expectEqualStrings("hi\n<span class=\"st-fail\">\n# exit code 1\n</span>", list.items);
}

test status {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(t.allocator);
    try status(&list, t.allocator, .ok, 1234, "");
    try t.expectEqualStrings("ok · 1.23 s", list.items);
    list.clearRetainingCapacity();
    try status(&list, t.allocator, .differs, 50, "");
    try t.expectEqualStrings("differs from the docs · 0.05 s", list.items);
    list.clearRetainingCapacity();
    try status(&list, t.allocator, .failed, 0, "busy");
    try t.expectEqualStrings("busy", list.items);
}

test "exports" {
    const index =
        \\[{"n":"read","h":"io.html#read","p":"IO","s":"Read <bytes>"},
        \\ {"n":"prep_read","h":"sqe_prep.html#prep_read","p":"Prep","s":""}]
    ;
    try t.expect(loadIndex(index.ptr, index.len));
    try t.expectEqual(2, search("read", 4));
    try t.expect(std.mem.find(u8, out.items, "Read &lt;bytes&gt;") != null);
    try t.expectEqual(0, move(1)); // first ArrowDown: the first hit
    try t.expectEqual(1, move(5));
    try t.expectEqual(0, move(-9));
    try t.expectEqual(1, move(1));
    try t.expect(chosen());
    try t.expectEqualStrings("sqe_prep.html#prep_read", out.items);
    try t.expectEqual(0, search("zzz", 3));
    try t.expectEqual(-1, move(1));
    try t.expect(!loadIndex("nope", 4));
    try t.expectEqual(0, search("x", 1));
    try t.expectEqual(out.items.ptr, outPtr());
    try t.expectEqual(out.items.len, outLen());

    // `app.js` writes an argument into `alloc`'s memory, calls an export, then `free`s it
    const arg = alloc(4) orelse return error.OutOfMemory;
    @memcpy(arg[0..4], "nope");
    try t.expect(!loadIndex(arg, 4));
    free(arg, 4);

    // The index outlives its input (`app.js` frees it right after `loadIndex`).
    const copy = try t.allocator.dupe(u8,
        \\[{"n":"run_coroutine_threadsafe","h":"a.html#rct","p":"A","s":""},
        \\ {"n":"run","h":"a.html#run","p":"A","s":""}]
    );
    try t.expect(loadIndex(copy.ptr, copy.len));
    @memset(copy, 'x');
    t.allocator.free(copy);
    try t.expectEqual(2, search("run", 3));
    try t.expect(chosen());
    try t.expectEqualStrings("a.html#run", out.items);

    const pong = "{\"module\": \"pkg\", \"version\": \"2026.10.18\", \"python\": \"3.15t\"}";
    try t.expect(ping(pong.ptr, pong.len));
    try t.expectEqualStrings("live · 3.15t", out.items);
    try t.expect(!ping("{}", 2));
    try t.expect(!ping("<html>", 6)); // not the docs server: not JSON

    const busy = "{\"error\": \"busy\"}";
    try t.expectEqual(@backingInt(RunKind.failed), renderRun(busy.ptr, busy.len));
    runStatus(renderRun(busy.ptr, busy.len), 10);
    try t.expectEqualStrings("busy", out.items);
    try t.expectEqual(@backingInt(RunKind.failed), renderRun("<html>", 6));
    runStatus(@backingInt(RunKind.failed), 10);
    try t.expectEqualStrings("unreadable answer from the server", out.items);
    const ran = "{\"target\": \"x\", \"ok\": true, \"steps\": [{\"source\": \"1\", \"expected\": \"1\", " ++
        "\"got\": \"1\", \"status\": \"ok\"}]}";
    try t.expectEqual(@backingInt(RunKind.ok), renderRun(ran.ptr, ran.len));
    try t.expect(std.mem.startsWith(u8, out.items, "<span class=\"st-ok\">&gt;&gt;&gt; 1\n</span>"));
}

test markLines {
    var marks: [6]Mark = @splat(.none);
    markLines(&marks, "2-3, 5", .miss);
    try t.expectEqualSlices(Mark, &.{ .none, .miss, .miss, .none, .miss, .none }, &marks);
    markLines(&marks, "1, 5-99, x, 0, 3-y, ", .hit); // past the end, not numbers, line 0: skipped
    try t.expectEqualSlices(Mark, &.{ .hit, .miss, .miss, .none, .hit, .hit }, &marks);
    markLines(&marks, "", .miss);
    try t.expectEqual(.hit, marks[0]);
}

test highlight {
    try expectHighlight(
        "<span class=\"kw\">pub</span> <span class=\"kw\">fn</span> <span class=\"fn\">add</span>(" ++
            "<span class=\"slf\">self</span>: <span class=\"ty\">Ring</span>, n: <span class=\"ty\">u32</span>) " ++
            "<span class=\"ty\">usize</span> {",
        "pub fn add(self: Ring, n: u32) usize {",
    );
    try expectHighlight(
        "x.<span class=\"attr\">len</span> = <span class=\"con\">null</span>; <span class=\"com\">// &lt;b&gt;</span>",
        "x.len = null; // <b>",
    );
    try expectHighlight(
        "<span class=\"str\">&quot;a\\&quot;b // c&quot;</span> <span class=\"str\">&#39;\\n&#39;</span> " ++
            "<span class=\"str\">\\\\ line &amp;</span>",
        "\"a\\\"b // c\" '\\n' \\\\ line &",
    );
    try expectHighlight("&quot;open", "\"open"); // not closed on the line: plain
    try expectHighlight(
        "<span class=\"bi\">@max</span>(<span class=\"num\">0x1F</span>, <span class=\"num\">0o17</span>, " ++
            "<span class=\"num\">0b10</span>, <span class=\"num\">1_000</span>, <span class=\"num\">2.5e-3</span>)",
        "@max(0x1F, 0o17, 0b10, 1_000, 2.5e-3)",
    );
    try expectHighlight(
        "<span class=\"num\">0</span>..<span class=\"num\">10</span> 1abc 0x @ <span class=\"num\">0</span>",
        "0..10 1abc 0x @ 0",
    );
    try expectHighlight(
        "<span class=\"fn\">f</span>() <span class=\"ty\">i8</span> <span class=\"ty\">c_int</span> " ++
            "<span class=\"fn\">go</span> (x) iz _x",
        "f() i8 c_int go (x) iz _x",
    );
}

test sourceHtml {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(t.allocator);
    try t.expectEqual(2, try sourceHtml(&list, t.allocator, "a\nb\n", "1", "2"));
    try t.expectEqualStrings(
        "<span class=\"hit\" data-n=\"1\">a\n</span><span class=\"miss\" data-n=\"2\">b\n</span>",
        list.items,
    );
    list.clearRetainingCapacity();
    try t.expectEqual(0, try sourceHtml(&list, t.allocator, "x\r\n\n<", "", ""));
    try t.expectEqualStrings(
        "<span data-n=\"1\">x\n</span><span data-n=\"2\">\n</span><span data-n=\"3\">&lt;\n</span>",
        list.items,
    );
    list.clearRetainingCapacity();
    try t.expectEqual(0, try sourceHtml(&list, t.allocator, "", "1", "1"));
    try t.expectEqual(0, list.items.len);
}

test renderSource {
    const source = "const a = 1;\nconst b = 2;\n";
    try t.expectEqual(2, renderSource(source.ptr, source.len, "1".ptr, 1, "2".ptr, 1, false));
    try t.expect(std.mem.startsWith(u8, out.items, "<span class=\"hit\" data-n=\"1\"><span class=\"kw\">const</span>"));
    try t.expectEqual(out.items.ptr, outPtr());
    try t.expectEqual(out.items.len, outLen());

    // the viewer writes each argument into `alloc`'s memory, calls `render`, then `free`s them
    const arg = alloc(1) orelse return error.OutOfMemory;
    arg[0] = 'x';
    try t.expectEqual(0, renderSource(arg, 1, arg, 0, arg, 0, false));
    try t.expectEqualStrings("<span data-n=\"1\">x\n</span>", out.items);
    free(arg, 1);

    // a source changed since the coverage run: the notice first
    try t.expectEqual(1, renderSource(source.ptr, source.len, "".ptr, 0, "1".ptr, 1, true));
    try t.expect(std.mem.startsWith(u8, out.items, stale_notice ++ "<span class=\"miss\" data-n=\"1\">"));
}

test parseCosts {
    var buf: [4]Cost = undefined;
    const found = parseCosts("88:9.0, x, 106:17, 5:y, :1", &buf);
    try t.expectEqual(2, found.len);
    try t.expectEqual(88, found[0].n);
    try t.expectEqualStrings("9.0", found[0].text);
    try t.expectEqual(17, found[1].value);
    try t.expectEqual(0, parseCosts("", &buf).len);
}

test profileHtml {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(t.allocator);
    try t.expectEqual(2, try profileHtml(&list, t.allocator, "a\nb\n", "2:4.0"));
    try t.expectEqualStrings(
        "<span data-n=\"1\"><b class=\"pc\"></b>a\n</span><span data-n=\"2\" class=\"hot\" " ++
            "style=\"background:color-mix(in srgb, var(--bad) 65%, transparent)\"><b class=\"pc\">4.0</b>b\n</span>",
        list.items,
    );
    // line 0 first; the costliest line wins (not the first); 2 of the top 4: 10 + 55 / 2 = 38 %
    list.clearRetainingCapacity();
    try t.expectEqual(3, try profileHtml(&list, t.allocator, "x\r\ny\nconst z = 1;", "0:1.0,1:2.0,3:4.0"));
    try t.expect(std.mem.startsWith(u8, list.items, "<span data-n=\"0\" class=\"hot\""));
    try t.expect(std.mem.find(u8, list.items, no_line) != null);
    try t.expect(std.mem.find(u8, list.items, "var(--bad) 38%") != null);
    try t.expect(std.mem.find(u8, list.items, "<span class=\"kw\">const</span>") != null);
    try t.expect(std.mem.find(u8, list.items, "x\n</span>") != null); // the `\r` dropped
    // no source: the costly lines only, no text; all costs 0: shaded as the top
    list.clearRetainingCapacity();
    try t.expectEqual(90, try profileHtml(&list, t.allocator, "", "90:0,0:0"));
    try t.expectEqualStrings(
        "<span data-n=\"0\" class=\"hot\" style=\"background:color-mix(in srgb, var(--bad) 65%, transparent)\">" ++
            "<b class=\"pc\">0</b>" ++ no_line ++ "\n</span><span data-n=\"90\" class=\"hot\" " ++
            "style=\"background:color-mix(in srgb, var(--bad) 65%, transparent)\"><b class=\"pc\">0</b>\n</span>",
        list.items,
    );
    list.clearRetainingCapacity();
    try t.expectEqual(0, try profileHtml(&list, t.allocator, "", ""));
    try t.expectEqual(0, list.items.len);
}

test renderProfile {
    const source = "const a = 1;\n";
    try t.expectEqual(1, renderProfile(source.ptr, source.len, "1:3.5".ptr, 5));
    try t.expect(std.mem.find(u8, out.items, "<b class=\"pc\">3.5</b><span class=\"kw\">const</span>") != null);
}
