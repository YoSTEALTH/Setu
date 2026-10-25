//! The docs site's logic, compiled to WebAssembly (`zig build docs-web` -> `docs.wasm` in the site): API
//! search, the Run transcript, and the docs server check. `app.js` (written by `tools/setu_docs.py`) is only
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

/// Load `search.json` (an array of `Entry`); false when it does not parse.
export fn loadIndex(ptr: [*]const u8, len: usize) bool {
    _ = index_arena.reset(.free_all);
    entries = std.json.parseFromSliceLeaky([]const Entry, index_arena.allocator(), input(ptr, len), .{
        .ignore_unknown_fields = true,
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
        out.clearRetainingCapacity();
        hits = &.{};
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
        out.clearRetainingCapacity();
        last_error.appendSlice(gpa, "out of memory") catch {};
        return @backingInt(RunKind.failed);
    };
    return @backingInt(kind);
}

/// The status line for `kind` (from `renderRun`) after `millis` to the output.
export fn runStatus(kind: u32, millis: u32) void {
    out.clearRetainingCapacity();
    const k = std.enums.fromInt(RunKind, kind) orelse .failed;
    status(&out, gpa, k, millis, last_error.items) catch out.clearRetainingCapacity();
}

// --- tests ----------------------------------------------------------------------------------------

const t = std.testing;

/// A test search entry named `n` with summary `s`.
fn entry(n: []const u8, s: []const u8) Entry {
    return .{ .n = n, .h = "p.html#x", .p = "Page", .s = s };
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

    const pong = "{\"module\": \"pkg\", \"version\": \"2026.10.18\", \"python\": \"3.15t\"}";
    try t.expect(ping(pong.ptr, pong.len));
    try t.expectEqualStrings("live · 3.15t", out.items);
    try t.expect(!ping("{}", 2));

    const busy = "{\"error\": \"busy\"}";
    try t.expectEqual(@backingInt(RunKind.failed), renderRun(busy.ptr, busy.len));
    runStatus(renderRun(busy.ptr, busy.len), 10);
    try t.expectEqualStrings("busy", out.items);
    const ran = "{\"target\": \"x\", \"ok\": true, \"steps\": [{\"source\": \"1\", \"expected\": \"1\", " ++
        "\"got\": \"1\", \"status\": \"ok\"}]}";
    try t.expectEqual(@backingInt(RunKind.ok), renderRun(ran.ptr, ran.len));
    try t.expect(std.mem.startsWith(u8, out.items, "<span class=\"st-ok\">&gt;&gt;&gt; 1\n</span>"));
}
