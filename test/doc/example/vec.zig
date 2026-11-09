//! The Coverage page's fixture source (`coverage.json` marks lines 1-10; line 4 never ran).
const std = @import("std");
pub fn norm2(x: i64, y: i64) i64 {
    if (x == 0 and y == 0) return 0;
    return x * x + y * y;
}
pub fn scale(x: i64, k: i64) i64 {
    return x * k;
}
pub const one = norm2(1, 0);
