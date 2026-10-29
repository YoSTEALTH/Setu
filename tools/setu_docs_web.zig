//! The docs site's behaviour, compiled to WebAssembly (`zig build docs-web` -> `docs.wasm` in the site): all of it.
//! `app.js` (written by `tools/setu_docs.py`) is a fixed loop that knows no element or feature: each call into this
//! module (`onStart`, `onEvent`, `onFetched`, `onTimer`) returns a list of commands (`Op`: bind elements, set text /
//! HTML / attributes, listen, fetch, store, ...), which `app.js` runs in order; events, answers and fetch results come
//! back as calls. Here: API search, the Run buttons, the docs server check, the pages' Zig code blocks, the ◐ menu, the
//! Copy buttons, the repository link's facts, and the Coverage and Profile source views (a file's source as HTML
//! lines, Zig highlighted with the code blocks' classes; from Liburing's `source_web.zig`). `setu_docs.py` writes every
//! element a feature needs, hidden, and the page as it is without this module (opened from disk): this module only
//! turns them on and fills them. The one script outside it is the `<head>` one that applies the saved theme before the
//! first paint, before this module can load. Every HTML string this module sends is escaped here. Setu builds it for
//! a project through `addSetuDocsSteps` (Setu's `build.zig`); nothing is copied.

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

/// What a Run's answer means (`kindOf`).
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

/// Append the search results as HTML links (`<a href>name<small>page — summary</small></a>`), the one at
/// `chosen` (-1: none) with `class="sel"`.
pub fn hitsHtml(
    list: *std.ArrayList(u8),
    a: std.mem.Allocator,
    all: []const Entry,
    found: []const u32,
    chosen: i32,
) !void {
    for (found, 0..) |i, k| {
        const e = all[i];
        try list.appendSlice(a, if (k == chosen) "<a class=\"sel\" href=\"" else "<a href=\"");
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

/// Append a Zig code block of a page (lines split at `\n`, a `\r` before it dropped) highlighted, its newlines
/// kept.
///
/// Example
///     >>> try codeHtml(&list, gpa, "const a = 1;\n// b");
///     >>> list.items
///     "<span class=\"kw\">const</span> a = <span class=\"num\">1</span>;\n<span class=\"com\">// b</span>"
pub fn codeHtml(list: *std.ArrayList(u8), a: std.mem.Allocator, code: []const u8) !void {
    var lines = std.mem.splitScalar(u8, code, '\n');
    var first = true;
    while (lines.next()) |line| : (first = false) {
        if (!first) try list.append(a, '\n');
        try highlight(list, a, std.mem.trimEnd(u8, line, "\r"));
    }
}

/// One item of the ◐ menu: its `data-palette` (`""`: Tokyo) and `data-mode` (`light` / `dark`).
pub const Theme = struct { palette: []const u8, mode: []const u8 };

/// The ◐ menu's item showing `palette` in `mode` (`""` when none was picked: the system's, dark when
/// `system_dark`), among `items`; -1 when none.
///
/// Example
///     >>> themeItem(&.{ .{ .palette = "nord", .mode = "light" }, .{ .palette = "", .mode = "dark" } }, "", "", true)
///     1
pub fn themeItem(items: []const Theme, palette: []const u8, mode: []const u8, system_dark: bool) i32 {
    const shown = if (mode.len > 0) mode else if (system_dark) "dark" else "light";
    for (items, 0..) |item, i| {
        // cast: a menu's few items
        if (std.mem.eql(u8, item.palette, palette) and std.mem.eql(u8, item.mode, shown)) return @intCast(i);
    }
    return -1;
}

/// The item `delta` away from item `at` (-1: none) in a menu of `count`, wrapping around; from none, ArrowDown
/// (`delta` > 0) is the first and ArrowUp the last.
///
/// Example
///     >>> stepItem(3, 1, 4)
///     0
///     >>> stepItem(-1, -1, 4)
///     3
pub fn stepItem(at: i32, delta: i32, count: u32) u32 {
    if (count == 0) return 0;
    // cast: a menu's few items
    const n: i32 = @intCast(count);
    const next = if (at < 0) (if (delta > 0) 0 else n - 1) else @mod(at + delta, n);
    // cast: `@mod` by `n` (and 0 / `n - 1`) is in 0 ..< `n`
    return @intCast(next);
}

/// Append what a code block's Copy button copies from its `text`: for a `>>>` session (`session`) the
/// statements without their prompts (lines starting `>>> ` / `... `, or only `>>>` / `...`), else `text`.
///
/// Example
///     >>> try copyText(&list, gpa, ">>> x = 1\n>>> x\n1", true);
///     >>> list.items
///     "x = 1\nx"
pub fn copyText(list: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8, session: bool) !void {
    if (!session) return list.appendSlice(a, text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        const prompt = std.mem.startsWith(u8, line, ">>>") or std.mem.startsWith(u8, line, "...");
        if (!prompt or (line.len > 3 and line[3] != ' ')) continue;
        if (!first) try list.append(a, '\n');
        first = false;
        if (line.len > 4) try list.appendSlice(a, line[4..]);
    }
}

/// Append the count `n` as the repository link shows it: `999`, `1.2k` (a tenth, rounded half up; `10k` from
/// 9950), `12k` (rounded half up) from 10000.
///
/// Example
///     >>> try shortCount(&list, gpa, 1250);
///     >>> list.items
///     "1.3k"
pub fn shortCount(list: *std.ArrayList(u8), a: std.mem.Allocator, n: u64) !void {
    if (n < 1000) return list.print(a, "{d}", .{n});
    if (n >= 10000) return list.print(a, "{d}k", .{(n + 500) / 1000});
    const tenths = (n + 50) / 100;
    if (tenths % 10 == 0) return list.print(a, "{d}k", .{tenths / 10});
    try list.print(a, "{d}.{d}k", .{ tenths / 10, tenths % 10 });
}

/// Append the repository link's facts, one per line: the latest release that is not a pre-release (`""` when
/// none), stars and forks, from GitHub's answers `info` (`/repos/<repo>`) and `releases` (its `/releases`,
/// newest first; anything unreadable counts as none). False when `info` does not parse.
///
/// Example
///     >>> _ = try repoFacts(&list, gpa, "{\"stargazers_count\": 1250, \"forks_count\": 3}",
///     >>>     "[{\"tag_name\": \"v2\", \"prerelease\": true}, {\"tag_name\": \"v1\"}]");
///     true
///     >>> list.items
///     "v1\n1.3k\n3"
pub fn repoFacts(list: *std.ArrayList(u8), a: std.mem.Allocator, info: []const u8, releases: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    // The fields of GitHub's answers the link shows (the rest is ignored).
    const Info = struct { stargazers_count: u64 = 0, forks_count: u64 = 0 };
    const Release = struct { tag_name: []const u8 = "", prerelease: bool = false };
    const repo = std.json.parseFromSliceLeaky(Info, arena.allocator(), info, options) catch return false;
    const all = std.json.parseFromSliceLeaky([]const Release, arena.allocator(), releases, options) catch &.{};
    for (all) |r| if (!r.prerelease) {
        try list.appendSlice(a, r.tag_name);
        break;
    };
    try list.append(a, '\n');
    try shortCount(list, a, repo.stargazers_count);
    try list.append(a, '\n');
    try shortCount(list, a, repo.forks_count);
    return true;
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

/// One line's cost for the Profile page (`profileHtml`): the line, the instructions per call as written, and
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

// --- the command list: what `app.js` does for this module ------------------------------------------

/// A command `app.js` runs: this byte, then its arguments as `signatureOf` says. `app.js` is a fixed loop over
/// these (its `ops` table, in this order): it runs a returned list in order, then passes each answer back.
pub const Op = enum(u8) {
    /// `bind parent h selector`: element `h` is `parent`'s first match of `selector`.
    bind,
    /// `bind_all parent first id selector attrs`: the matches of `selector` in `parent` are elements `first`,
    /// `first + 1`, ...; answered by `onEvent(id, count, values)`: each match's attributes named in `attrs`
    /// (split at spaces), in order, joined by U+001F (a missing one empty).
    bind_all,
    /// `read h id`: answered by `onEvent(id, h, textContent)`.
    read,
    /// `html h text`: the inner HTML.
    html,
    /// `text h text`: the text content.
    text,
    /// `attr h name value`: set an attribute.
    attr,
    /// `unattr h name`: remove an attribute.
    unattr,
    /// `class h name on`: add (`on` 1) or remove (0) a class.
    class,
    /// `focus h`.
    focus,
    /// `listen h type id`: every `type` event on `h` calls `onEvent(id, h, payload)`, inside the listener (so
    /// `prevent` works). `payload` by type: `input` the value, `keydown` the key, `click` the selected text,
    /// `change` `true` / `false` (whether a media query matches), any other empty.
    listen,
    /// `prevent`: the default action of the event being handled.
    prevent,
    /// `get url id`: fetch, answered by `onFetched(id, status, start, end, text)` (status 0: no answer; `start`
    /// / `end` from `performance.now()`).
    get,
    /// `post url id body`: the same, a POST of the text/plain `body`.
    post,
    /// `timer id ms`: `onTimer(id)` after `ms`.
    timer,
    /// `store area key value`: localStorage (area 0) or sessionStorage (1); refused: nothing.
    store,
    /// `recall area key id`: answered by `onEvent(id, 0, value)` (`""` when none or refused).
    recall,
    /// `copy id text`: to the clipboard, answered by `onEvent(id, 0, "")` once there.
    copy,
    /// `scroll h line`: `h` scrolled so that its child `[data-n="line"]` is a third down, when there is one.
    scroll,
    /// `go url`: open `url`.
    go,
};

/// The arguments of `op`, in order: `n` a number, `h` an element (a number), `s` a string. A number is a
/// little-endian `u32`; a string its byte length as one, then its UTF-8.
pub fn signatureOf(op: Op) []const u8 {
    return switch (op) {
        .bind => "hhs",
        .bind_all => "hhnss",
        .read => "hn",
        .listen => "hsn",
        .html, .text => "hs",
        .attr => "hss",
        .unattr => "hs",
        .class => "hsn",
        .focus => "h",
        .prevent => "",
        .get => "sn",
        .post => "sns",
        .timer => "nn",
        .store => "nss",
        .recall => "nsn",
        .copy => "ns",
        .scroll => "hn",
        .go => "s",
    };
}

/// The elements `app.js` keeps for this module (its `nodes`): fixed ones (0 to 3), the ones `bind` names, and
/// `bind_all`'s groups (`handle`).
pub const el = struct {
    pub const document: u32 = 0;
    pub const root: u32 = 1;
    pub const body: u32 = 2;
    /// The `(prefers-color-scheme: dark)` media query.
    pub const dark: u32 = 3;
    pub const q: u32 = 4;
    pub const hits: u32 = 5;
    pub const search: u32 = 6;
    pub const theme: u32 = 7;
    pub const menu: u32 = 8;
    pub const themes: u32 = 9;
    pub const live: u32 = 10;
    pub const facts: u32 = 11;
    /// The release, then stars (+ 1) and forks (+ 2).
    pub const fact_tag: u32 = 12;
};

/// A group of elements one `bind_all` names: element `i` is `handle(group, i)`. `prof_files + k` are the files
/// of the Profile page's case `k`.
pub const Group = enum(u16) {
    hints_on = 1,
    hints_off,
    items,
    code_pres,
    copies,
    zig_blocks,
    repos,
    cov_rows,
    cov_views,
    cov_pres,
    prof_rows,
    prof_views,
    run_boxes,
    run_buttons,
    run_statuses,
    run_results,
    prof_files = 64,
    _,
};

/// Most elements of a group (the rest of a page's matches are left alone).
pub const max_group = 0xffff;

/// Most Profile cases with a view (each takes a group).
pub const max_cases = 0xffff - @backingInt(Group.prof_files);

/// Element `i` of `group`.
pub fn handle(group: Group, i: usize) u32 {
    // cast: `i` is below `max_group`, a group's size
    return @as(u32, @backingInt(group)) << 16 | @as(u32, @intCast(i));
}

/// The index of element `h` in `group`, or null when it is not one of its.
fn indexIn(h: u32, group: Group) ?usize {
    if (h >> 16 != @backingInt(group)) return null;
    return h & 0xffff;
}

/// The group of the Profile case `k`'s files.
fn caseFiles(k: usize) Group {
    // cast: `k` is below `max_cases`
    return @fromBackingInt(@backingInt(Group.prof_files) + @as(u16, @intCast(k)));
}

/// What an event `listen` asked for is (its id, below `first_request`).
pub const On = enum(u32) {
    theme_click = 1,
    item_click,
    item_focus,
    menu_key,
    themes_click,
    doc_click,
    doc_key,
    dark_change,
    q_input,
    q_key,
    q_focus,
    q_blur,
    search_click,
    copy_click,
    cov_click,
    prof_click,
    run_click,
};

/// The first id `request` gives out (the ones below are `On`'s).
pub const first_request = 256;

/// What an answer, a fetch or a timer is for (`request`): the row of `pending` its id names.
pub const Pending = union(enum) {
    /// A `bind_all`, with how many attributes per element it asked for.
    bound: struct { group: Group, attrs: usize },
    palette,
    mode,
    /// The text of code block `i`, to copy.
    copy_text: usize,
    /// Code block `i`'s text is on the clipboard.
    copied: usize,
    /// Code block `i`'s button back to `Copy`.
    copy_reset: usize,
    /// The text of Zig block `i`, to highlight.
    zig_text: usize,
    repo_cache,
    repo_info,
    repo_releases,
    index,
    ping,
    /// The source of Coverage row `i`.
    cov_source: usize,
    /// The source of file `file` of Profile case `row`.
    prof_source: struct { row: usize, file: usize },
    /// The answer of Run box `i`.
    run: usize,
};

/// One Coverage row: what its view needs, and whether it was loaded / is shown.
const CovRow = struct {
    src: []const u8,
    hit: []const u8,
    miss: []const u8,
    stale: bool,
    loaded: bool = false,
    shown: bool = false,
};

/// One file of a Profile case's view: its source in the site (`""`: not found) and its `line:cost` pairs.
const ProfFile = struct { src: []const u8, lines: []const u8 };

/// One Profile case: whether its view was loaded / is shown, and its files once bound.
const ProfRow = struct { loaded: bool = false, shown: bool = false, files: []const ProfFile = &.{} };

/// One Run box: its target, and whether it waits for an answer.
const RunBox = struct { target: []const u8, busy: bool = false };

/// What the repository link waits for: GitHub's two answers (`info` null and `failed`: no answer).
const Repo = struct {
    name: []const u8 = "",
    info: ?[]const u8 = null,
    failed: bool = false,
    releases: ?[]const u8 = null,
};

/// What this module knows of the page, from `onStart` on; its strings and lists are in `page_arena`.
const Page = struct {
    /// Served by `setu_docs.py serve` (127.0.0.1 or localhost): Run may work.
    local: bool = false,
    dark: bool = false,
    palette: []const u8 = "",
    mode: []const u8 = "",
    themes: []const Theme = &.{},
    menu_open: bool = false,
    menu_at: i32 = -1,
    /// The click being handled reached the ◐ menu's box / the search box (it bubbles to the document next).
    in_themes: bool = false,
    in_search: bool = false,
    q_focused: bool = false,
    hits_shown: bool = false,
    /// Per code block: a `>>>` session (Copy leaves out the prompts and the output).
    sessions: []const bool = &.{},
    repo: Repo = .{},
    cov: []CovRow = &.{},
    prof: []ProfRow = &.{},
    runs: []RunBox = &.{},
};

var commands: std.ArrayList(u8) = .empty;
var scratch: std.ArrayList(u8) = .empty;
var page: Page = .{};
var page_arena = std.heap.ArenaAllocator.init(gpa);
var pending: std.array_hash_map.Auto(u32, Pending) = .empty;
var next_request: u32 = first_request;
var index_arena = std.heap.ArenaAllocator.init(gpa);
var entries: []const Entry = &.{};
var hits_buf: [max_hits]u32 = undefined;
var hits: []const u32 = &.{};
var selected: i32 = -1;

/// Append a number to `commands`.
fn num(n: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, n, .little);
    try commands.appendSlice(gpa, &bytes);
}

/// Append the command `op` with its `args` (a tuple: numbers, then strings, as `signatureOf(op)` says).
fn emit(op: Op, args: anytype) !void {
    try commands.append(gpa, @backingInt(op));
    inline for (args) |arg| {
        if (@TypeOf(arg) == u32 or @TypeOf(arg) == comptime_int) {
            try num(arg);
        } else {
            const text: []const u8 = arg;
            // cast: a string in wasm32 memory is shorter than 4 GiB
            try num(@intCast(text.len));
            try commands.appendSlice(gpa, text);
        }
    }
}

/// A new id for `what`, kept in `pending` until its answer.
fn request(what: Pending) !u32 {
    const id = next_request;
    next_request += 1;
    try pending.put(gpa, id, what);
    return id;
}

/// `bind_all` of `selector` in `parent` as `group`, asking for `attrs` (names split at spaces).
fn bindAll(parent: u32, group: Group, selector: []const u8, attrs: []const u8) !void {
    const count = if (attrs.len == 0) 0 else std.mem.countScalar(u8, attrs, ' ') + 1;
    const id = try request(.{ .bound = .{ .group = group, .attrs = count } });
    try emit(.bind_all, .{ parent, handle(group, 0), id, selector, attrs });
}

/// `text` copied into `page_arena` (`app.js` frees its arguments after the call).
fn keep(text: []const u8) ![]const u8 {
    return page_arena.allocator().dupe(u8, text);
}

/// Show (`hide` false) or hide element `h`.
fn setHidden(h: u32, hide: bool) !void {
    if (hide) try emit(.attr, .{ h, "hidden", "" }) else try emit(.unattr, .{ h, "hidden" });
}

/// The page is loaded and `docs.wasm` with it: turn on what the page has off (written for no `docs.wasm`), bind
/// the elements each feature needs and listen.
fn begin(dark: bool, host: []const u8) !void {
    page.dark = dark;
    page.local = std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost");
    inline for (.{
        .{ el.q, "#q" },         .{ el.hits, "#hits" },   .{ el.search, ".search" },
        .{ el.theme, "#theme" }, .{ el.menu, "#themes" }, .{ el.themes, ".themes" },
        .{ el.live, "#live" },
    }) |b| try emit(.bind, .{ el.document, b[0], b[1] });
    try emit(.unattr, .{ el.q, "disabled" });
    try emit(.attr, .{ el.q, "placeholder", "Search the API…" });
    try emit(.unattr, .{ el.theme, "disabled" });
    try emit(.attr, .{ el.theme, "title", "Theme" });
    try bindAll(el.document, .hints_on, ".src-hint[hidden]", "");
    try bindAll(el.document, .hints_off, ".src-hint:not([hidden])", "");
    try bindAll(el.menu, .items, "button", "data-palette data-mode");
    try emit(.recall, .{ 0, "palette", try request(.palette) });
    try emit(.recall, .{ 0, "theme", try request(.mode) });
    inline for (.{
        .{ el.theme, "click", On.theme_click },   .{ el.themes, "click", On.themes_click },
        .{ el.menu, "keydown", On.menu_key },     .{ el.document, "click", On.doc_click },
        .{ el.document, "keydown", On.doc_key },  .{ el.dark, "change", On.dark_change },
        .{ el.q, "input", On.q_input },           .{ el.q, "keydown", On.q_key },
        .{ el.q, "focus", On.q_focus },           .{ el.q, "blur", On.q_blur },
        .{ el.search, "click", On.search_click },
    }) |l| try emit(.listen, .{ l[0], l[1], @as(u32, @backingInt(l[2])) });
    try bindAll(el.document, .code_pres, ".codebox pre", "class");
    try bindAll(el.document, .copies, ".codebox .copy", "");
    try bindAll(el.document, .zig_blocks, "pre.code[data-lang=\"zig\"]", "");
    try bindAll(el.document, .repos, ".repo[data-repo]:not([data-repo=\"\"])", "data-repo");
    try emit(.get, .{ "search.json", try request(.index) });
    try bindAll(el.document, .cov_rows, "table.cov tr[data-src]", "data-src data-hit data-miss data-stale");
    try bindAll(el.document, .cov_views, "table.cov tr.src-view", "");
    try bindAll(el.document, .cov_pres, "table.cov tr.src-view pre", "");
    try bindAll(el.document, .prof_rows, "table.prof tr.prof-row", "");
    try bindAll(el.document, .prof_views, "table.prof tr.src-view", "");
    try bindAll(el.document, .run_boxes, ".run", "data-target");
    try bindAll(el.document, .run_buttons, ".run button", "");
    try bindAll(el.document, .run_statuses, ".run .status", "");
    try bindAll(el.document, .run_results, ".run .result", "");
    if (page.local) try emit(.get, .{ "/api/ping", try request(.ping) });
}

/// Listen to `type` on each of the `n` elements of `group`, as `on`.
fn listenAll(group: Group, n: usize, @"type": []const u8, on: On) !void {
    for (0..n) |i| try emit(.listen, .{ handle(group, i), @"type", @as(u32, @backingInt(on)) });
}

/// A `bind_all` answer: `count` elements of `group`, `attrs` values each in `values`.
fn bound(group: Group, count: u32, values: []const u8, attrs: usize) !void {
    const a = page_arena.allocator();
    const n: usize = @min(count, max_group);
    const v = try a.alloc([]const u8, n * attrs);
    var parts = std.mem.splitScalar(u8, values, 0x1f);
    for (v) |*slot| slot.* = try keep(parts.next() orelse "");
    switch (group) {
        .hints_on, .hints_off => for (0..n) |i| try setHidden(handle(group, i), group == .hints_off),
        .items => {
            const items = try a.alloc(Theme, n);
            for (items, 0..) |*item, i| item.* = .{ .palette = v[2 * i], .mode = v[2 * i + 1] };
            page.themes = items;
            try listenAll(group, n, "click", .item_click);
            try listenAll(group, n, "focus", .item_focus);
        },
        .code_pres => {
            const sessions = try a.alloc(bool, n);
            for (sessions, v) |*session, class| {
                var names = std.mem.tokenizeScalar(u8, class, ' ');
                session.* = while (names.next()) |name| {
                    if (std.mem.eql(u8, name, "session")) break true;
                } else false;
            }
            page.sessions = sessions;
        },
        .copies => {
            for (0..n) |i| try setHidden(handle(group, i), false);
            try listenAll(group, n, "click", .copy_click);
        },
        .zig_blocks => for (0..n) |i| try emit(.read, .{ handle(group, i), try request(.{ .zig_text = i }) }),
        .repos => if (n > 0) {
            page.repo.name = v[0];
            const repo = handle(group, 0);
            try emit(.bind, .{ repo, el.facts, ".facts" });
            inline for (.{ "tag", "stars", "forks" }, 0..) |fact, i| {
                try emit(.bind, .{ repo, el.fact_tag + @as(u32, i), "[data-fact=\"" ++ fact ++ "\"]" });
            }
            const key = try a.print("repo-facts:{s}", .{page.repo.name});
            try emit(.recall, .{ 1, key, try request(.repo_cache) });
        },
        .cov_rows => {
            const rows = try a.alloc(CovRow, n);
            for (rows, 0..) |*row, i| row.* = .{
                .src = v[4 * i],
                .hit = v[4 * i + 1],
                .miss = v[4 * i + 2],
                .stale = std.mem.eql(u8, v[4 * i + 3], "1"),
            };
            page.cov = rows;
            try listenAll(group, n, "click", .cov_click);
        },
        .prof_rows => {
            page.prof = try a.alloc(ProfRow, @min(n, max_cases));
            @memset(page.prof, .{});
            try listenAll(group, page.prof.len, "click", .prof_click);
        },
        .run_boxes => {
            const runs = try a.alloc(RunBox, n);
            for (runs, v) |*run, target| run.* = .{ .target = target };
            page.runs = runs;
        },
        .run_buttons => try listenAll(group, n, "click", .run_click),
        .cov_views, .cov_pres, .prof_views, .run_statuses, .run_results => {},
        else => {
            const k = @backingInt(group) - @backingInt(Group.prof_files);
            const files = try a.alloc(ProfFile, n);
            for (files, 0..) |*file, i| file.* = .{ .src = v[2 * i], .lines = v[2 * i + 1] };
            page.prof[k].files = files;
            try nextProfFile(k, 0);
        },
    }
}

/// Mark the ◐ menu's item for the theme shown (`aria-checked`); returns it, or -1.
fn markTheme() !i32 {
    const at = themeItem(page.themes, page.palette, page.mode, page.dark);
    for (0..page.themes.len) |i| {
        try emit(.attr, .{ handle(.items, i), "aria-checked", if (i == at) "true" else "false" });
    }
    return at;
}

/// Open or close the ◐ menu; opened, the focus goes to the theme shown (or the first).
fn showThemes(open: bool) !void {
    page.menu_open = open;
    try setHidden(el.menu, !open);
    try emit(.attr, .{ el.theme, "aria-expanded", if (open) "true" else "false" });
    if (!open or page.themes.len == 0) return;
    const at = try markTheme();
    // cast: a menu's few items
    try focusItem(@intCast(stepItem(at - 1, 1, @intCast(page.themes.len))));
}

/// Move the focus to the ◐ menu's item `i`.
fn focusItem(i: i32) !void {
    page.menu_at = i;
    // cast: `i` is one of the items
    try emit(.focus, .{handle(.items, @intCast(i))});
}

/// The ◐ menu's item `i` picked: its palette and mode on the page and kept (the `<head>` script reads them).
fn pickTheme(i: usize) !void {
    const theme = page.themes[i];
    if (theme.palette.len > 0) {
        try emit(.attr, .{ el.root, "data-palette", theme.palette });
    } else {
        try emit(.unattr, .{ el.root, "data-palette" });
    }
    try emit(.attr, .{ el.root, "data-theme", theme.mode });
    try emit(.store, .{ 0, "palette", theme.palette });
    try emit(.store, .{ 0, "theme", theme.mode });
    page.palette = theme.palette;
    page.mode = theme.mode;
    _ = try markTheme();
    try showThemes(false);
    try emit(.focus, .{el.theme});
}

/// Show the hits (the selected one marked), hidden when there are none.
fn showHits() !void {
    scratch.clearRetainingCapacity();
    try hitsHtml(&scratch, gpa, entries, hits, selected);
    try emit(.html, .{ el.hits, scratch.items });
    page.hits_shown = hits.len > 0;
    try setHidden(el.hits, !page.hits_shown);
}

/// Hide the hits, when shown.
fn hideHits() !void {
    if (!page.hits_shown) return;
    page.hits_shown = false;
    try setHidden(el.hits, true);
}

/// The repository link's facts (`repoFacts`' lines) on the page.
fn showFacts(facts: []const u8) !void {
    var lines = std.mem.splitScalar(u8, facts, '\n');
    for (0..3) |i| {
        const value = lines.next() orelse "";
        // cast: one of the three facts
        if (value.len > 0) try emit(.text, .{ el.fact_tag + @as(u32, @intCast(i)), value });
    }
    try setHidden(el.facts, false);
}

/// Both of GitHub's answers in: the facts shown and kept for the session (none when the repository's failed).
fn repoDone() !void {
    const repo = page.repo;
    const releases = repo.releases orelse return;
    const info = repo.info orelse return;
    scratch.clearRetainingCapacity();
    if (!try repoFacts(&scratch, gpa, info, releases)) return;
    const key = try page_arena.allocator().print("repo-facts:{s}", .{repo.name});
    try emit(.store, .{ 1, key, scratch.items });
    try showFacts(scratch.items);
}

/// `Could not load <src>: ...` in element `h`, for a fetch answered with `status` (0: no answer).
fn couldNotLoad(h: u32, src: []const u8, status_code: u32) !void {
    scratch.clearRetainingCapacity();
    try scratch.print(gpa, "Could not load {s}: ", .{src});
    if (status_code == 0) {
        try scratch.appendSlice(gpa, "no answer");
    } else {
        try scratch.print(gpa, "HTTP {d}", .{status_code});
    }
    try emit(.text, .{ h, scratch.items });
}

/// HTML in element `h`, scrolled to `line` (0: not).
fn showSource(h: u32, line: usize) !void {
    try emit(.html, .{ h, scratch.items });
    // cast: a line number of a source file
    if (line > 0) try emit(.scroll, .{ h, @as(u32, @intCast(line)) });
}

/// Show or hide a source view that was loaded; true when it was not (now loaded and shown: fill it).
fn toggleView(view: u32, loaded: *bool, shown: *bool) !bool {
    if (loaded.*) {
        shown.* = !shown.*;
        try setHidden(view, !shown.*);
        return false;
    }
    loaded.* = true;
    shown.* = true;
    try setHidden(view, false);
    return true;
}

/// Profile case `row`'s files from `from` on: those without a source shown at once (their costly lines), up to
/// the next one to fetch.
fn nextProfFile(row: usize, from: usize) !void {
    const files = page.prof[row].files;
    for (files[from..], from..) |file, k| {
        if (file.src.len > 0) {
            return emit(.get, .{ file.src, try request(.{ .prof_source = .{ .row = row, .file = k } }) });
        }
        try showProfile(row, k, "");
    }
}

/// File `k` of Profile case `row` with its `source` (`""`: not found).
fn showProfile(row: usize, k: usize, source: []const u8) !void {
    scratch.clearRetainingCapacity();
    const top = try profileHtml(&scratch, gpa, source, page.prof[row].files[k].lines);
    try showSource(handle(caseFiles(row), k), top);
}

/// A Run's answer (`status_code` 0: none) after `millis`: the transcript and the status line in box `i`.
fn runDone(i: usize, status_code: u32, millis: u32, text: []const u8) !void {
    page.runs[i].busy = false;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const r: RunResult = if (status_code == 0)
        .{ .@"error" = "no answer from the server" }
    else
        std.json.parseFromSliceLeaky(RunResult, arena.allocator(), text, options) catch
            .{ .@"error" = "unreadable answer from the server" };
    const kind = kindOf(r);
    if (kind != .failed) {
        scratch.clearRetainingCapacity();
        try transcript(&scratch, gpa, r);
        try emit(.html, .{ handle(.run_results, i), scratch.items });
        try setHidden(handle(.run_results, i), false);
    }
    scratch.clearRetainingCapacity();
    try status(&scratch, gpa, kind, millis, r.@"error" orelse "");
    const line = handle(.run_statuses, i);
    try emit(.text, .{ line, scratch.items });
    try emit(.attr, .{ line, "class", if (kind == .ok) "status ok" else "status fail" });
    try emit(.unattr, .{ handle(.run_buttons, i), "disabled" });
}

/// The `/api/ping` answer: the badge text (`live · <python>`) in `list` when it is the docs server.
pub fn badge(list: *std.ArrayList(u8), a: std.mem.Allocator, answer: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // The `/api/ping` answer's fields that matter (the rest is ignored).
    const Ping = struct { module: ?[]const u8 = null, python: []const u8 = "" };
    const p = std.json.parseFromSliceLeaky(Ping, arena.allocator(), answer, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    if (p.module == null) return false;
    try list.print(a, "live · {s}", .{p.python});
    return true;
}

/// Load `search.json` (an array of `Entry`) as the search index; none when it does not parse.
fn loadIndex(text: []const u8) void {
    _ = index_arena.reset(.free_all);
    entries = std.json.parseFromSliceLeaky([]const Entry, index_arena.allocator(), text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch &.{};
}

/// An event `listen` asked for: `on`, on element `h`, with its `payload`.
fn listener(on: On, h: u32, payload: []const u8) !void {
    switch (on) {
        .theme_click => try showThemes(!page.menu_open),
        .item_click => try pickTheme(indexIn(h, .items) orelse return),
        // cast: a menu's few items
        .item_focus => page.menu_at = @intCast(indexIn(h, .items) orelse return),
        .menu_key => {
            const down = std.mem.eql(u8, payload, "ArrowDown");
            if (!down and !std.mem.eql(u8, payload, "ArrowUp")) return;
            try emit(.prevent, .{});
            const delta: i32 = if (down) 1 else -1;
            // cast: a menu's few items
            try focusItem(@intCast(stepItem(page.menu_at, delta, @intCast(page.themes.len))));
        },
        .themes_click => page.in_themes = true,
        .search_click => page.in_search = true,
        .doc_click => {
            if (page.menu_open and !page.in_themes) try showThemes(false);
            if (!page.in_search) try hideHits();
            page.in_themes = false;
            page.in_search = false;
        },
        .doc_key => if (std.mem.eql(u8, payload, "Escape") and page.menu_open) {
            try showThemes(false);
            try emit(.focus, .{el.theme});
        } else if (std.mem.eql(u8, payload, "/") and !page.q_focused) {
            try emit(.prevent, .{});
            try emit(.focus, .{el.q});
        },
        .dark_change => {
            page.dark = std.mem.eql(u8, payload, "true");
            _ = try markTheme();
        },
        .q_input => {
            selected = -1;
            hits = best(gpa, entries, payload, &hits_buf) catch &.{};
            try showHits();
        },
        .q_key => if (std.mem.eql(u8, payload, "ArrowDown") or std.mem.eql(u8, payload, "ArrowUp")) {
            try emit(.prevent, .{});
            if (hits.len == 0) return;
            // cast: at most `max_hits`
            const last: i32 = @intCast(hits.len - 1);
            const delta: i32 = if (std.mem.eql(u8, payload, "ArrowDown")) 1 else -1;
            selected = std.math.clamp(selected + delta, 0, last);
            try showHits();
        } else if (std.mem.eql(u8, payload, "Enter") and hits.len > 0) {
            // cast: `selected` is -1 or a hit's index
            try emit(.go, .{entries[hits[if (selected < 0) 0 else @intCast(selected)]].h});
            try hideHits();
        } else if (std.mem.eql(u8, payload, "Escape")) {
            try hideHits();
        },
        .q_focus => page.q_focused = true,
        .q_blur => page.q_focused = false,
        .copy_click => {
            const i = indexIn(h, .copies) orelse return;
            try emit(.read, .{ handle(.code_pres, i), try request(.{ .copy_text = i }) });
        },
        .cov_click => {
            const i = indexIn(h, .cov_rows) orelse return;
            if (payload.len > 0) return; // text selected, not a click on the row
            const row = &page.cov[i];
            if (try toggleView(handle(.cov_views, i), &row.loaded, &row.shown)) {
                try emit(.get, .{ row.src, try request(.{ .cov_source = i }) });
            }
        },
        .prof_click => {
            const i = indexIn(h, .prof_rows) orelse return;
            if (payload.len > 0) return;
            const row = &page.prof[i];
            const view = handle(.prof_views, i);
            if (try toggleView(view, &row.loaded, &row.shown)) {
                try bindAll(view, caseFiles(i), "pre", "data-src data-lines");
            }
        },
        .run_click => {
            const i = indexIn(h, .run_buttons) orelse return;
            if (i >= page.runs.len or page.runs[i].busy) return;
            page.runs[i].busy = true;
            try emit(.attr, .{ h, "disabled", "" });
            try emit(.attr, .{ handle(.run_statuses, i), "class", "status" });
            try emit(.text, .{ handle(.run_statuses, i), "running…" });
            try emit(.post, .{ "/api/run", try request(.{ .run = i }), page.runs[i].target });
        },
    }
}

/// `onEvent`: a listened event (`id` an `On`), or the answer to a `bind_all` / `read` / `recall` / `copy`.
fn event(id: u32, h: u32, payload: []const u8) !void {
    if (id < first_request) return listener(std.enums.fromInt(On, id) orelse return, h, payload);
    switch ((pending.fetchSwapRemove(id) orelse return).value) {
        .bound => |b| try bound(b.group, h, payload, b.attrs),
        .palette => page.palette = try keep(payload),
        .mode => {
            page.mode = try keep(payload);
            _ = try markTheme();
        },
        .copy_text => |i| {
            scratch.clearRetainingCapacity();
            try copyText(&scratch, gpa, payload, i < page.sessions.len and page.sessions[i]);
            try emit(.copy, .{ try request(.{ .copied = i }), scratch.items });
        },
        .copied => |i| {
            try emit(.text, .{ handle(.copies, i), "Copied" });
            try emit(.timer, .{ try request(.{ .copy_reset = i }), 1200 });
        },
        .zig_text => |i| {
            scratch.clearRetainingCapacity();
            try codeHtml(&scratch, gpa, payload);
            try emit(.html, .{ handle(.zig_blocks, i), scratch.items });
        },
        .repo_cache => if (payload.len > 0) try showFacts(payload) else {
            const api = try page_arena.allocator().print("https://api.github.com/repos/{s}", .{page.repo.name});
            try emit(.get, .{ api, try request(.repo_info) });
            const releases = try page_arena.allocator().print("{s}/releases?per_page=10", .{api});
            try emit(.get, .{ releases, try request(.repo_releases) });
        },
        else => {}, // a fetch's or a timer's id: not an event
    }
}

/// `onFetched`: the answer to a `get` / `post`.
fn fetched(id: u32, status_code: u32, millis: u32, text: []const u8) !void {
    switch ((pending.fetchSwapRemove(id) orelse return).value) {
        .index => if (status_code == 200) loadIndex(text),
        .ping => if (status_code == 200) {
            scratch.clearRetainingCapacity();
            if (!try badge(&scratch, gpa, text)) return;
            try emit(.class, .{ el.body, "can-run", 1 });
            try emit(.text, .{ el.live, scratch.items });
            try emit(.class, .{ el.live, "on", 1 });
        },
        .repo_info => {
            page.repo.failed = status_code != 200;
            if (!page.repo.failed) page.repo.info = try keep(text);
            try repoDone();
        },
        .repo_releases => {
            page.repo.releases = try keep(if (status_code == 200) text else "[]");
            try repoDone();
        },
        .cov_source => |i| {
            const row = page.cov[i];
            const pre = handle(.cov_pres, i);
            if (status_code != 200) return couldNotLoad(pre, row.src, status_code);
            scratch.clearRetainingCapacity();
            if (row.stale) try scratch.appendSlice(gpa, stale_notice);
            try showSource(pre, try sourceHtml(&scratch, gpa, text, row.hit, row.miss));
        },
        .prof_source => |f| {
            if (status_code == 200) {
                try showProfile(f.row, f.file, text);
            } else {
                try couldNotLoad(handle(caseFiles(f.row), f.file), page.prof[f.row].files[f.file].src, status_code);
            }
            try nextProfFile(f.row, f.file + 1);
        },
        .run => |i| try runDone(i, status_code, millis, text),
        else => {}, // an event's or a timer's id: not a fetch
    }
}

/// `onTimer`: a `timer` ran out.
fn timedOut(id: u32) !void {
    switch ((pending.fetchSwapRemove(id) orelse return).value) {
        .copy_reset => |i| try emit(.text, .{ handle(.copies, i), "Copy" }),
        else => {}, // not a timer's id
    }
}

// coverage-off: out of memory only
/// Out of memory: no commands (the page stays as it is).
fn failed() void {
    commands.clearRetainingCapacity();
}
// coverage-on

// --- exports: what `app.js` calls -----------------------------------------------------------------

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

/// Start of the command list the last call returned.
export fn outPtr() [*]const u8 {
    return commands.items.ptr;
}

/// Length of the command list the last call returned.
export fn outLen() usize {
    return commands.items.len;
}

/// The page loaded: whether the system is `dark`, and the page's host name (`location.hostname`).
export fn onStart(dark: bool, host_ptr: [*]const u8, host_len: usize) void {
    commands.clearRetainingCapacity();
    begin(dark, input(host_ptr, host_len)) catch failed();
}

/// A listened event (`id`, on element `h`, its `payload`) or an answer (`id`, the count or element, the text).
export fn onEvent(id: u32, h: u32, ptr: [*]const u8, len: usize) void {
    commands.clearRetainingCapacity();
    event(id, h, input(ptr, len)) catch failed();
}

/// A fetch's answer: its HTTP `status_code` (0: none), when it was sent and answered (`performance.now()`, ms)
/// and its text.
export fn onFetched(id: u32, status_code: u32, sent: f64, answered: f64, ptr: [*]const u8, len: usize) void {
    commands.clearRetainingCapacity();
    const millis = std.math.lossyCast(u32, @round(answered - sent));
    fetched(id, status_code, millis, input(ptr, len)) catch failed();
}

/// A timer ran out.
export fn onTimer(id: u32) void {
    commands.clearRetainingCapacity();
    timedOut(id) catch failed();
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
    try hitsHtml(&list, t.allocator, &.{ entry("<b>", "a & b"), entry("y", "") }, &.{ 0, 1 }, 1);
    try t.expectEqualStrings(
        "<a href=\"p.html#x\">&lt;b&gt;<small>Page — a &amp; b</small></a>" ++
            "<a class=\"sel\" href=\"p.html#x\">y<small>Page</small></a>",
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

test codeHtml {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(t.allocator);
    try codeHtml(&list, t.allocator, "const a = 1;\r\n\n// <b>\n");
    try t.expectEqualStrings(
        "<span class=\"kw\">const</span> a = <span class=\"num\">1</span>;\n\n" ++
            "<span class=\"com\">// &lt;b&gt;</span>\n",
        list.items,
    );
    list.clearRetainingCapacity();
    try codeHtml(&list, t.allocator, "");
    try t.expectEqual(0, list.items.len);
}

test themeItem {
    const items = [_]Theme{
        .{ .palette = "nord", .mode = "light" }, .{ .palette = "nord", .mode = "dark" },
        .{ .palette = "", .mode = "light" },     .{ .palette = "", .mode = "dark" },
    };
    try t.expectEqual(0, themeItem(&items, "nord", "light", true));
    try t.expectEqual(1, themeItem(&items, "nord", "", true)); // no choice: the system's
    try t.expectEqual(2, themeItem(&items, "", "", false));
    try t.expectEqual(3, themeItem(&items, "", "dark", false));
    try t.expectEqual(-1, themeItem(&items, "gone", "dark", false));
}

test stepItem {
    try t.expectEqual(1, stepItem(0, 1, 4));
    try t.expectEqual(0, stepItem(3, 1, 4));
    try t.expectEqual(3, stepItem(0, -1, 4));
    try t.expectEqual(0, stepItem(-1, 1, 4));
    try t.expectEqual(3, stepItem(-1, -1, 4));
    try t.expectEqual(0, stepItem(2, 1, 0));
}

test copyText {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(t.allocator);
    try copyText(&list, t.allocator, ">>> for i in x:\n...     f(i)\n...\n>>>x\n>>>\n2", true);
    try t.expectEqualStrings("for i in x:\n    f(i)\n\n", list.items);
    list.clearRetainingCapacity();
    try copyText(&list, t.allocator, ">>> code\nas is", false);
    try t.expectEqualStrings(">>> code\nas is", list.items);
}

test shortCount {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(t.allocator);
    for ([_]u64{ 0, 999, 1000, 1049, 1050, 1250, 9949, 9950, 10000, 12499, 12500, 999500 }) |n| {
        try shortCount(&list, t.allocator, n);
        try list.append(t.allocator, ' ');
    }
    try t.expectEqualStrings("0 999 1k 1k 1.1k 1.3k 9.9k 10k 10k 12k 13k 1000k ", list.items);
}

test repoFacts {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(t.allocator);
    const info = "{\"stargazers_count\": 1250, \"forks_count\": 3, \"name\": \"x\"}";
    const releases = "[{\"tag_name\": \"v2\", \"prerelease\": true}, {\"tag_name\": \"v1\"}]";
    try t.expect(try repoFacts(&list, t.allocator, info, releases));
    try t.expectEqualStrings("v1\n1.3k\n3", list.items);
    list.clearRetainingCapacity();
    try t.expect(try repoFacts(&list, t.allocator, info, "{\"message\": \"rate limited\"}")); // no releases
    try t.expectEqualStrings("\n1.3k\n3", list.items);
    list.clearRetainingCapacity();
    try t.expect(!try repoFacts(&list, t.allocator, "not json", "[]"));
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

/// Forget the page (each command test starts with it).
fn resetPage() void {
    page = .{};
    _ = page_arena.reset(.free_all);
    pending.clearRetainingCapacity();
    next_request = first_request;
    loadIndex("[]");
    hits = &.{};
    selected = -1;
    commands.clearRetainingCapacity();
}

/// The names `decode` gives the elements of `el`, by number.
const el_names = [_][]const u8{
    "document", "root",   "body",  "dark",  "q",
    "hits",     "search", "theme", "menu",  "themes",
    "live",     "facts",  "tag",   "stars", "forks",
};

/// The command list `bytes` as text: a line per command, its op and arguments (a string quoted, an element of `el`
/// by its name, of a group `<group>.<index>`, of a Profile case's files `prof_files+<case>.<index>`).
fn decode(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < bytes.len) {
        const op: Op = @fromBackingInt(bytes[at]);
        at += 1;
        try list.print(a, "{t}", .{op});
        for (signatureOf(op)) |kind| {
            const n = std.mem.readInt(u32, bytes[at..][0..4], .little);
            at += 4;
            const group = n >> 16;
            if (kind == 's') {
                try list.print(a, " \"{s}\"", .{bytes[at..][0..n]});
                at += n;
            } else if (kind == 'n') {
                try list.print(a, " {d}", .{n});
            } else if (group == 0) {
                try list.print(a, " {s}", .{el_names[n]});
            } else if (group >= @backingInt(Group.prof_files)) {
                try list.print(a, " prof_files+{d}.{d}", .{ group - @backingInt(Group.prof_files), n & 0xffff });
            } else {
                // cast: a named group's number
                try list.print(a, " {t}.{d}", .{ @as(Group, @fromBackingInt(@as(u16, @intCast(group)))), n & 0xffff });
            }
        }
        try list.append(a, '\n');
    }
    return list.toOwnedSlice(a);
}

/// Whether the last call's commands are `expected` (`decode`).
fn expectCommands(expected: []const u8) !void {
    const got = try decode(t.allocator, commands.items);
    defer t.allocator.free(got);
    try t.expectEqualStrings(expected, got);
}

/// Whether the last call's commands start with `expected` (`decode`).
fn expectCommandsStart(expected: []const u8) !void {
    const got = try decode(t.allocator, commands.items);
    defer t.allocator.free(got);
    try t.expectStringStartsWith(got, expected);
}

/// `onEvent(id, h, payload)`, as `app.js` calls it.
fn send(id: u32, h: u32, payload: []const u8) void {
    onEvent(id, h, payload.ptr, payload.len);
}

/// `onFetched(id, status_code, ...)` with `text`, answered 1234 ms after it was sent.
fn reply(id: u32, status_code: u32, text: []const u8) void {
    onFetched(id, status_code, 100, 1334, text.ptr, text.len);
}

test signatureOf {
    // every op's arguments: numbers and elements before strings, except `listen`'s id and `class`' flag
    for (std.enums.values(Op)) |op| try t.expect(signatureOf(op).len <= 5);
    try t.expectEqualStrings("hsn", signatureOf(.listen));
}

test "onStart" {
    resetPage();
    onStart(false, "127.0.0.1", 9);
    try expectCommands(
        \\bind document q "#q"
        \\bind document hits "#hits"
        \\bind document search ".search"
        \\bind document theme "#theme"
        \\bind document menu "#themes"
        \\bind document themes ".themes"
        \\bind document live "#live"
        \\unattr q "disabled"
        \\attr q "placeholder" "Search the API…"
        \\unattr theme "disabled"
        \\attr theme "title" "Theme"
        \\bind_all document hints_on.0 256 ".src-hint[hidden]" ""
        \\bind_all document hints_off.0 257 ".src-hint:not([hidden])" ""
        \\bind_all menu items.0 258 "button" "data-palette data-mode"
        \\recall 0 "palette" 259
        \\recall 0 "theme" 260
        \\listen theme "click" 1
        \\listen themes "click" 5
        \\listen menu "keydown" 4
        \\listen document "click" 6
        \\listen document "keydown" 7
        \\listen dark "change" 8
        \\listen q "input" 9
        \\listen q "keydown" 10
        \\listen q "focus" 11
        \\listen q "blur" 12
        \\listen search "click" 13
        \\bind_all document code_pres.0 261 ".codebox pre" "class"
        \\bind_all document copies.0 262 ".codebox .copy" ""
        \\bind_all document zig_blocks.0 263 "pre.code[data-lang="zig"]" ""
        \\bind_all document repos.0 264 ".repo[data-repo]:not([data-repo=""])" "data-repo"
        \\get "search.json" 265
        \\bind_all document cov_rows.0 266 "table.cov tr[data-src]" "data-src data-hit data-miss data-stale"
        \\bind_all document cov_views.0 267 "table.cov tr.src-view" ""
        \\bind_all document cov_pres.0 268 "table.cov tr.src-view pre" ""
        \\bind_all document prof_rows.0 269 "table.prof tr.prof-row" ""
        \\bind_all document prof_views.0 270 "table.prof tr.src-view" ""
        \\bind_all document run_boxes.0 271 ".run" "data-target"
        \\bind_all document run_buttons.0 272 ".run button" ""
        \\bind_all document run_statuses.0 273 ".run .status" ""
        \\bind_all document run_results.0 274 ".run .result" ""
        \\get "/api/ping" 275
        \\
    );
    // the hints: the viewer's shown, the one for a page without a server hidden
    send(256, 1, "");
    try expectCommands("unattr hints_on.0 \"hidden\"\n");
    send(257, 2, "");
    try expectCommands("attr hints_off.0 \"hidden\" \"\"\nattr hints_off.1 \"hidden\" \"\"\n");
    // a published site: no ping (`setu_docs.py serve` listens on 127.0.0.1 only)
    resetPage();
    onStart(true, "x.github.io", 11);
    try t.expect(std.mem.find(u8, commands.items, "/api/ping") == null);
    try t.expect(page.dark);
    resetPage();
    onStart(false, "localhost", 9);
    try t.expect(page.local);
}

test "theme menu" {
    resetPage();
    onStart(false, "x", 1);
    const items = "nord\x1flight\x1fnord\x1fdark\x1f\x1flight\x1f\x1fdark";
    send(258, 4, items);
    try expectCommandsStart(
        \\listen items.0 "click" 2
        \\listen items.1 "click" 2
    );
    send(259, 0, "nord");
    try expectCommands("");
    send(260, 0, ""); // no mode kept: the system's (light)
    try expectCommands(
        \\attr items.0 "aria-checked" "true"
        \\attr items.1 "aria-checked" "false"
        \\attr items.2 "aria-checked" "false"
        \\attr items.3 "aria-checked" "false"
        \\
    );
    send(@backingInt(On.dark_change), el.dark, "true");
    try t.expect(std.mem.find(u8, commands.items, "items.1 \"aria-checked\" \"true\"") == null); // decoded below
    try expectCommands(
        \\attr items.0 "aria-checked" "false"
        \\attr items.1 "aria-checked" "true"
        \\attr items.2 "aria-checked" "false"
        \\attr items.3 "aria-checked" "false"
        \\
    );
    // open: the focus on the theme shown
    send(@backingInt(On.theme_click), el.theme, "");
    try expectCommands(
        \\unattr menu "hidden"
        \\attr theme "aria-expanded" "true"
        \\attr items.0 "aria-checked" "false"
        \\attr items.1 "aria-checked" "true"
        \\attr items.2 "aria-checked" "false"
        \\attr items.3 "aria-checked" "false"
        \\focus items.1
        \\
    );
    send(@backingInt(On.themes_click), el.themes, ""); // the click bubbles: the menu's box, then the document
    send(@backingInt(On.doc_click), el.document, "");
    try t.expect(page.menu_open);
    send(@backingInt(On.menu_key), el.menu, "ArrowUp");
    try expectCommands("prevent\nfocus items.0\n");
    send(@backingInt(On.menu_key), el.menu, "ArrowUp");
    try expectCommands("prevent\nfocus items.3\n");
    send(@backingInt(On.item_focus), handle(.items, 2), ""); // the mouse or Tab
    send(@backingInt(On.menu_key), el.menu, "ArrowDown");
    try expectCommands("prevent\nfocus items.3\n");
    send(@backingInt(On.menu_key), el.menu, "a");
    try expectCommands("");
    send(@backingInt(On.item_focus), el.q, ""); // not an item
    send(@backingInt(On.item_click), el.q, "");
    try t.expectEqual(3, page.menu_at);
    // Tokyo Day picked: no `data-palette`
    send(@backingInt(On.item_click), handle(.items, 2), "");
    try expectCommands(
        \\unattr root "data-palette"
        \\attr root "data-theme" "light"
        \\store 0 "palette" ""
        \\store 0 "theme" "light"
        \\attr items.0 "aria-checked" "false"
        \\attr items.1 "aria-checked" "false"
        \\attr items.2 "aria-checked" "true"
        \\attr items.3 "aria-checked" "false"
        \\attr menu "hidden" ""
        \\attr theme "aria-expanded" "false"
        \\focus theme
        \\
    );
    send(@backingInt(On.item_click), handle(.items, 1), "");
    try expectCommandsStart(
        \\attr root "data-palette" "nord"
        \\attr root "data-theme" "dark"
    );
    // Escape and a click outside close it
    send(@backingInt(On.theme_click), el.theme, "");
    send(@backingInt(On.doc_key), el.document, "Escape");
    try expectCommands("attr menu \"hidden\" \"\"\nattr theme \"aria-expanded\" \"false\"\nfocus theme\n");
    send(@backingInt(On.doc_key), el.document, "Escape"); // closed: nothing
    try expectCommands("");
    send(@backingInt(On.theme_click), el.theme, "");
    send(@backingInt(On.doc_click), el.document, "");
    try expectCommands("attr menu \"hidden\" \"\"\nattr theme \"aria-expanded\" \"false\"\n");
    // no items (a page without the menu's buttons): opens, focuses nothing
    page.themes = &.{};
    send(@backingInt(On.theme_click), el.theme, "");
    try expectCommands("unattr menu \"hidden\"\nattr theme \"aria-expanded\" \"true\"\n");
}

test "search" {
    resetPage();
    onStart(false, "x", 1);
    const index =
        \\[{"n":"read","h":"io.html#read","p":"IO","s":"Read <bytes>"},
        \\ {"n":"prep_read","h":"sqe_prep.html#prep_read","p":"Prep","s":""}]
    ;
    reply(265, 200, index);
    try t.expectEqual(2, entries.len);
    send(@backingInt(On.q_input), el.q, "read");
    try expectCommands("html hits \"<a href=\"io.html#read\">read<small>IO — Read &lt;bytes&gt;</small></a>" ++
        "<a href=\"sqe_prep.html#prep_read\">prep_read<small>Prep</small></a>\"\nunattr hits \"hidden\"\n");
    send(@backingInt(On.q_key), el.q, "ArrowDown");
    try expectCommandsStart(
        \\prevent
        \\html hits "<a class="sel" href="io.html#read">
    );
    send(@backingInt(On.q_key), el.q, "ArrowDown");
    send(@backingInt(On.q_key), el.q, "ArrowDown"); // the last stays
    try t.expectEqual(1, selected);
    send(@backingInt(On.q_key), el.q, "ArrowUp");
    try t.expectEqual(0, selected);
    send(@backingInt(On.q_key), el.q, "Enter");
    try expectCommands("go \"io.html#read\"\nattr hits \"hidden\" \"\"\n");
    send(@backingInt(On.q_input), el.q, "read");
    send(@backingInt(On.q_key), el.q, "Enter"); // none selected: the first
    try expectCommands("go \"io.html#read\"\nattr hits \"hidden\" \"\"\n");
    send(@backingInt(On.q_input), el.q, "read");
    send(@backingInt(On.q_key), el.q, "Escape");
    try expectCommands("attr hits \"hidden\" \"\"\n");
    send(@backingInt(On.q_key), el.q, "Escape"); // hidden already
    send(@backingInt(On.q_key), el.q, "x");
    try expectCommands("");
    // no hits: hidden; arrows only kept from moving the cursor, Enter does nothing
    send(@backingInt(On.q_input), el.q, "zzz");
    try expectCommands("html hits \"\"\nattr hits \"hidden\" \"\"\n");
    send(@backingInt(On.q_key), el.q, "ArrowUp");
    try expectCommands("prevent\n");
    send(@backingInt(On.q_key), el.q, "Enter");
    try expectCommands("");
    // a click in the search box keeps the hits, one outside hides them
    send(@backingInt(On.q_input), el.q, "prep");
    send(@backingInt(On.search_click), el.search, "");
    send(@backingInt(On.doc_click), el.document, "");
    try expectCommands("");
    send(@backingInt(On.doc_click), el.document, "");
    try expectCommands("attr hits \"hidden\" \"\"\n");
    // `/` focuses the search box, unless it has the focus
    send(@backingInt(On.doc_key), el.document, "/");
    try expectCommands("prevent\nfocus q\n");
    send(@backingInt(On.q_focus), el.q, "");
    send(@backingInt(On.doc_key), el.document, "/");
    try expectCommands("");
    send(@backingInt(On.q_blur), el.q, "");
    try t.expect(!page.q_focused);
    // an index that does not parse, or is not there: no hits
    resetPage();
    onStart(false, "x", 1);
    reply(265, 200, "<html>");
    try t.expectEqual(0, entries.len);
    reply(265, 200, index); // answered already: ignored
    try t.expectEqual(0, entries.len);
    resetPage();
    onStart(false, "x", 1);
    reply(265, 404, index);
    try t.expectEqual(0, entries.len);
}

test "Copy buttons and Zig blocks" {
    resetPage();
    onStart(false, "x", 1);
    send(261, 2, "code session\x1fcode");
    try t.expectEqualSlices(bool, &.{ true, false }, page.sessions);
    send(262, 2, "");
    try expectCommands(
        \\unattr copies.0 "hidden"
        \\unattr copies.1 "hidden"
        \\listen copies.0 "click" 14
        \\listen copies.1 "click" 14
        \\
    );
    send(@backingInt(On.copy_click), handle(.copies, 0), "");
    try expectCommands("read code_pres.0 275\n");
    send(275, handle(.code_pres, 0), ">>> 1 + 1\n2");
    try expectCommands("copy 276 \"1 + 1\"\n");
    send(276, 0, "");
    try expectCommands("text copies.0 \"Copied\"\ntimer 277 1200\n");
    onTimer(277);
    try expectCommands("text copies.0 \"Copy\"\n");
    onTimer(277); // once
    try expectCommands("");
    send(@backingInt(On.copy_click), handle(.copies, 1), "");
    send(278, handle(.code_pres, 1), ">>> as is");
    try expectCommands("copy 279 \">>> as is\"\n");
    send(@backingInt(On.copy_click), el.q, ""); // not a Copy button
    try expectCommands("");
    // Zig blocks: each one's text read, then highlighted
    send(263, 2, "");
    try expectCommands("read zig_blocks.0 280\nread zig_blocks.1 281\n");
    send(281, handle(.zig_blocks, 1), "const a = 1;");
    try expectCommands(
        \\html zig_blocks.1 "<span class="kw">const</span> a = <span class="num">1</span>;"
        \\
    );
}

test "repository facts" {
    resetPage();
    onStart(false, "x", 1);
    send(264, 0, ""); // a page without the link
    try expectCommands("");
    send(264, 1, "YoSTEALTH/Setu"); // answered already: ignored
    try expectCommands("");
    resetPage();
    onStart(false, "x", 1);
    send(264, 1, "YoSTEALTH/Setu");
    try expectCommands(
        \\bind repos.0 facts ".facts"
        \\bind repos.0 tag "[data-fact="tag"]"
        \\bind repos.0 stars "[data-fact="stars"]"
        \\bind repos.0 forks "[data-fact="forks"]"
        \\recall 1 "repo-facts:YoSTEALTH/Setu" 275
        \\
    );
    send(275, 0, "v1\n\n3"); // kept for the session: no stars yet
    try expectCommands("text tag \"v1\"\ntext forks \"3\"\nunattr facts \"hidden\"\n");
    // not kept: GitHub asked, answers in either order
    for ([_]bool{ false, true }) |releases_first| {
        resetPage();
        onStart(false, "x", 1);
        send(264, 1, "o/r");
        send(275, 0, "");
        try expectCommands(
            \\get "https://api.github.com/repos/o/r" 276
            \\get "https://api.github.com/repos/o/r/releases?per_page=10" 277
            \\
        );
        const info = "{\"stargazers_count\": 1250, \"forks_count\": 3}";
        if (releases_first) {
            reply(277, 500, "");
            try expectCommands("");
            reply(276, 200, info);
            try expectCommands(
                \\store 1 "repo-facts:o/r" "
                \\1.3k
                \\3"
                \\text stars "1.3k"
                \\text forks "3"
                \\unattr facts "hidden"
                \\
            );
        } else {
            reply(276, 200, info);
            try expectCommands("");
            reply(277, 200, "[{\"tag_name\": \"v2\"}]");
            try expectCommandsStart(
                \\store 1 "repo-facts:o/r" "v2
            );
        }
    }
    // GitHub does not answer, or not with the repository: no facts
    resetPage();
    onStart(false, "x", 1);
    send(264, 1, "o/r");
    send(275, 0, "");
    reply(276, 0, "");
    reply(277, 200, "[]");
    try expectCommands("");
    resetPage();
    onStart(false, "x", 1);
    send(264, 1, "o/r");
    send(275, 0, "");
    reply(276, 200, "<html>");
    reply(277, 200, "[]");
    try expectCommands("");
}

test "Coverage source view" {
    resetPage();
    onStart(false, "x", 1);
    send(266, 2, "source/a.zig\x1f1\x1f2\x1f\x1fsource/b.zig\x1f\x1f1\x1f1");
    try expectCommands("listen cov_rows.0 \"click\" 15\nlisten cov_rows.1 \"click\" 15\n");
    send(@backingInt(On.cov_click), handle(.cov_rows, 0), "sel"); // text selected: not a click on the row
    try expectCommands("");
    send(@backingInt(On.cov_click), handle(.cov_rows, 0), "");
    try expectCommands("unattr cov_views.0 \"hidden\"\nget \"source/a.zig\" 275\n");
    reply(275, 200, "const a = 1;\nb\n");
    try expectCommands(
        \\html cov_pres.0 "<span class="hit" data-n="1"><span class="kw">const</span> a = <span class="num">1</span>;
        \\</span><span class="miss" data-n="2">b
        \\</span>"
        \\scroll cov_pres.0 2
        \\
    );
    send(@backingInt(On.cov_click), handle(.cov_rows, 0), "");
    try expectCommands("attr cov_views.0 \"hidden\" \"\"\n");
    send(@backingInt(On.cov_click), handle(.cov_rows, 0), "");
    try expectCommands("unattr cov_views.0 \"hidden\"\n");
    // changed since the run: the notice first; nothing missed: not scrolled
    send(@backingInt(On.cov_click), handle(.cov_rows, 1), "");
    reply(276, 200, "x\n");
    try expectCommandsStart("html cov_pres.1 \"" ++ stale_notice);
    try t.expect(std.mem.find(u8, commands.items, "scroll") == null);
    resetPage();
    onStart(false, "x", 1);
    send(266, 2, "source/a.zig\x1f\x1f\x1f\x1fsource/b.zig");
    send(@backingInt(On.cov_click), handle(.cov_rows, 0), "");
    reply(275, 404, "");
    try expectCommands("text cov_pres.0 \"Could not load source/a.zig: HTTP 404\"\n");
    send(@backingInt(On.cov_click), handle(.cov_rows, 1), ""); // a short answer: the missing values empty
    reply(276, 0, "");
    try expectCommands("text cov_pres.1 \"Could not load source/b.zig: no answer\"\n");
    send(@backingInt(On.cov_click), el.q, "");
    try expectCommands("");
}

test "Profile source view" {
    resetPage();
    onStart(false, "x", 1);
    send(269, 2, "");
    try expectCommands("listen prof_rows.0 \"click\" 16\nlisten prof_rows.1 \"click\" 16\n");
    send(@backingInt(On.prof_click), handle(.prof_rows, 1), "sel");
    try expectCommands("");
    send(@backingInt(On.prof_click), handle(.prof_rows, 1), "");
    try expectCommands(
        \\unattr prof_views.1 "hidden"
        \\bind_all prof_views.1 prof_files+1.0 275 "pre" "data-src data-lines"
        \\
    );
    // the files in order: one fetched, one not found (its costly lines alone), one that fails
    send(275, 3, "source/f.zig\x1f1:2.0\x1f\x1f9:1.0\x1fsource/g.zig\x1f1:1");
    try expectCommands("get \"source/f.zig\" 276\n");
    reply(276, 200, "x\n");
    const top = " class=\"hot\" style=\"background:color-mix(in srgb, var(--bad) 65%, transparent)\">";
    try expectCommands("html prof_files+1.0 \"<span data-n=\"1\"" ++ top ++ "<b class=\"pc\">2.0</b>x\n</span>\"\n" ++
        "scroll prof_files+1.0 1\n" ++
        "html prof_files+1.1 \"<span data-n=\"9\"" ++ top ++ "<b class=\"pc\">1.0</b>\n</span>\"\n" ++
        "scroll prof_files+1.1 9\nget \"source/g.zig\" 277\n");
    reply(277, 404, "");
    try expectCommands("text prof_files+1.2 \"Could not load source/g.zig: HTTP 404\"\n");
    send(@backingInt(On.prof_click), handle(.prof_rows, 1), "");
    try expectCommands("attr prof_views.1 \"hidden\" \"\"\n");
    send(@backingInt(On.prof_click), el.q, "");
    try expectCommands("");
}

test "Run buttons and the server" {
    resetPage();
    onStart(false, "127.0.0.1", 9);
    reply(275, 200, "{\"module\": \"pkg\", \"python\": \"3.15t\"}");
    try expectCommands(
        \\class body "can-run" 1
        \\text live "live · 3.15t"
        \\class live "on" 1
        \\
    );
    for ([_][]const u8{ "{}", "<html>" }) |not_ours| {
        resetPage();
        onStart(false, "127.0.0.1", 9);
        reply(275, 200, not_ours);
        try expectCommands("");
    }
    resetPage();
    onStart(false, "127.0.0.1", 9);
    reply(275, 404, "");
    try expectCommands("");

    send(271, 2, "vec_norm2\x1fexample/hi.py");
    send(272, 3, ""); // a button more than boxes (markup the page should not have): left alone
    try expectCommands(
        \\listen run_buttons.0 "click" 17
        \\listen run_buttons.1 "click" 17
        \\listen run_buttons.2 "click" 17
        \\
    );
    send(@backingInt(On.run_click), handle(.run_buttons, 0), "");
    try expectCommands(
        \\attr run_buttons.0 "disabled" ""
        \\attr run_statuses.0 "class" "status"
        \\text run_statuses.0 "running…"
        \\post "/api/run" 276 "vec_norm2"
        \\
    );
    send(@backingInt(On.run_click), handle(.run_buttons, 0), ""); // running: once
    send(@backingInt(On.run_click), handle(.run_buttons, 2), "");
    send(@backingInt(On.run_click), el.q, "");
    try expectCommands("");
    reply(276, 200, "{\"ok\": true, \"steps\": [{\"source\": \"1\", \"got\": \"1\", \"status\": \"ok\"}]}");
    try expectCommands(
        \\html run_results.0 "<span class="st-ok">&gt;&gt;&gt; 1
        \\</span><span class="out">1
        \\</span>"
        \\unattr run_results.0 "hidden"
        \\text run_statuses.0 "ok · 1.23 s"
        \\attr run_statuses.0 "class" "status ok"
        \\unattr run_buttons.0 "disabled"
        \\
    );
    send(@backingInt(On.run_click), handle(.run_buttons, 1), "");
    reply(277, 200, "{\"ok\": false, \"output\": \"hi\\n\", \"returncode\": 1}");
    try t.expect(std.mem.find(u8, commands.items, "differs from the docs · 1.23 s") != null);
    try t.expect(std.mem.find(u8, commands.items, "status fail") != null);
    // refused, unreadable, no answer: the status line only
    for ([_]struct { u32, []const u8, []const u8 }{
        .{ 409, "{\"error\": \"busy\"}", "busy" },
        .{ 500, "<html>", "unreadable answer from the server" },
        .{ 0, "", "no answer from the server" },
    }) |case| {
        send(@backingInt(On.run_click), handle(.run_buttons, 0), "");
        reply(next_request - 1, case[0], case[1]);
        const want = try std.mem.concat(t.allocator, u8, &.{
            "text run_statuses.0 \"",              case[2], "\"\nattr run_statuses.0 \"class\" \"status fail\"\n",
            "unattr run_buttons.0 \"disabled\"\n",
        });
        defer t.allocator.free(want);
        try expectCommands(want);
    }
}

test "ids not waited for" {
    resetPage();
    onStart(false, "x", 1);
    send(0, 0, ""); // not an `On`
    send(999, 0, ""); // never asked
    reply(999, 200, "");
    onTimer(999);
    reply(259, 200, ""); // a `recall`'s id as a fetch, and the other way round: ignored
    send(265, 0, "");
    onTimer(260);
    try expectCommands("");
    try t.expect(!pending.contains(259) and !pending.contains(260) and !pending.contains(265));
    // the rest: `bind_all` answers that need nothing
    for ([_]u32{ 267, 268, 270, 273, 274 }) |id| send(id, 1, "");
    try expectCommands("");
}

test "memory and the command list" {
    resetPage();
    onStart(false, "x", 1);
    try t.expectEqual(commands.items.ptr, outPtr());
    try t.expectEqual(commands.items.len, outLen());
    // `app.js` writes an argument into `alloc`'s memory, calls an export, then `free`s it
    const arg = alloc(4) orelse return error.OutOfMemory;
    @memcpy(arg[0..4], "dark");
    onEvent(260, 0, arg, 4);
    free(arg, 4);
    try t.expectEqualStrings("dark", page.mode); // kept: a copy
}

test badge {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(t.allocator);
    try t.expect(try badge(&list, t.allocator, "{\"module\": \"m\", \"version\": \"1\", \"python\": \"3.14\"}"));
    try t.expectEqualStrings("live · 3.14", list.items);
    try t.expect(!try badge(&list, t.allocator, "{\"python\": \"3.14\"}"));
}
