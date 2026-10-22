//! Comptime assertions for the unit tests. `zig build test` compiles the tests and never runs them
//! (Setu's functions call libpython, which only an interpreter provides; see `build.zig`), so every
//! test is `comptime` and fails with a `@compileError` that shows what it got.

const std = @import("std");

/// `@compileError` unless `ok`; `what` says what was expected.
pub fn expect(comptime ok: bool, comptime what: []const u8) void {
    if (!ok) @compileError("expected " ++ what);
}

/// `@compileError` unless the text `got` is `want`.
pub fn expectText(comptime got: []const u8, comptime want: []const u8) void {
    if (!std.mem.eql(u8, got, want)) @compileError("expected\n" ++ want ++ "\ngot\n" ++ got);
}

/// `@compileError` unless the texts `got` are `want`, one by one.
pub fn expectTexts(comptime got: []const []const u8, comptime want: []const []const u8) void {
    if (got.len != want.len) @compileError(std.fmt.comptimePrint("expected {d} items, got {d}: {s}", .{
        want.len,
        got.len,
        joined(got),
    }));
    for (got, want) |g, w| expectText(g, w);
}

/// `items` as `a | b | c`, for an error message.
fn joined(comptime items: []const []const u8) []const u8 {
    var out: []const u8 = "";
    for (items, 0..) |item, i| out = out ++ (if (i == 0) "" else " | ") ++ item;
    return out;
}
